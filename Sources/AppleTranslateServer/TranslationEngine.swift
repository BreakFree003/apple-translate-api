import Foundation
// Apple 的 Translation 框架没标 Sendable，Swift 6 严格并发下会误报；
// 并发安全由下面的 actor 串行化保证。
@preconcurrency import Translation

/// 翻译失败的原因，路由层据此决定 HTTP 状态码和 code。
enum TranslationFailure: Error, Sendable {
    case emptyInput
    case unsupportedTarget(String)
    case unsupportedSource(String)
    case notInstalled(source: String?, target: String)
    case unsupportedPair(source: String, target: String)
    case engine(String)

    var code: String {
        switch self {
        case .emptyInput: "empty_input"
        case .unsupportedTarget: "unsupported_target_language"
        case .unsupportedSource: "unsupported_source_language"
        case .notInstalled: "language_not_installed"
        case .unsupportedPair: "unsupported_language_pair"
        case .engine: "translation_failed"
        }
    }

    var status: Int {
        switch self {
        case .engine: 502
        default: 400
        }
    }

    var message: String {
        switch self {
        case .emptyInput:
            "No text to translate. Send a non-empty user message or a `text` field."
        case .unsupportedTarget(let value):
            "Target language '\(value)' is not supported by Apple Translation. Supported: \(LanguageCatalog.all.map(\.id).joined(separator: ", "))."
        case .unsupportedSource(let value):
            "Source language '\(value)' is not supported by Apple Translation. Supported: \(LanguageCatalog.all.map(\.id).joined(separator: ", "))."
        case .notInstalled(let source, let target):
            "The \(source.map { "\($0) → \(target)" } ?? target) language pack is not installed on this Mac. "
                + "Install it in 系统设置 → 通用 → 语言与地区 → 翻译语言, then retry."
        case .unsupportedPair(let source, let target):
            "Apple Translation does not support the pair \(source) → \(target)."
        case .engine(let detail):
            "Apple Translation failed: \(detail)."
        }
    }
}

struct TranslationOutcome: Sendable {
    let sourceLanguage: String
    let targetLanguage: String
    let text: String
    /// 文本本来就是目标语言，直接原样返回，没真的翻。
    let skipped: Bool
}

/// 一个 session 的串行化盒子。
///
/// 框架要求同一个 `TranslationSession` 不能被并发调用，所以用 actor 把「同一个语言对」
/// 的调用排成队。
///
/// 别指望这能换来吞吐：实测系统框架内部自己就是串行的 —— 一条 12000 字的 en→zh-Hans
/// 在飞的时候，另一个语言对（zh-Hans→en）的小请求照样要等满 5.4s；把原来的单一 actor
/// 换成「每对一盒」并没有改变这个数字（对 HEAD 做同样的实验是 5.1s）。
///
/// 换来的不是速度，而是一个**真的**保证：原实现整个引擎只有一个 actor，而 actor 在
/// `await` 处是可重入的 —— 「actor 串行化保证同一个 session 不会被并发调用」那句话
/// 当时并不成立，四个并发请求确实会同时进同一个 session。现在它才成立。
actor SessionBox {
    private let session: TranslationSession

    init(session: TranslationSession) {
        self.session = session
    }

    var isReady: Bool {
        get async { await session.isReady }
    }

    func translate(_ text: String) async throws -> RawTranslation {
        let response = try await session.translate(text)
        return RawTranslation(
            sourceLanguage: response.sourceLanguage.minimalIdentifier,
            targetText: response.targetText
        )
    }
}

/// session 翻出来的原始结果。抽出来是为了不依赖框架 Response 的具体类型名。
struct RawTranslation: Sendable {
    let sourceLanguage: String
    let targetText: String
}

/// 持有 `TranslationSession` 池的 actor。
///
/// 一个 session 绑定一对语言（`installedSource:target:` 的语义就是「源语言的语言包已装好」），
/// 所以按语言对缓存复用，每个语言对包一个 `SessionBox`。
///
/// 本 actor 只做「查表 / 建盒 / 判语言」这类轻活；真正耗时的 `await box.translate()`
/// 会挂起本 actor 让出执行权，所以它不会在框架自身的串行之外再加一层排队。
actor TranslationEngine {
    private let config: Config
    private var boxes: [String: SessionBox] = [:]

    init(config: Config) {
        self.config = config
    }

    func translate(
        text rawText: String,
        source explicitSource: String?,
        target rawTarget: String
    ) async throws -> TranslationOutcome {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranslationFailure.emptyInput }

        guard let target = LanguageCatalog.canonical(rawTarget),
              let targetLanguage = LanguageCatalog.language(for: target) else {
            throw TranslationFailure.unsupportedTarget(rawTarget)
        }

        let fallbackSource = LanguageCatalog.canonical(config.defaultSource) ?? "en"
        let explicit: String?
        if let explicitSource, !explicitSource.isEmpty {
            guard let canonical = LanguageCatalog.canonical(explicitSource) else {
                throw TranslationFailure.unsupportedSource(explicitSource)
            }
            explicit = canonical
        } else {
            explicit = nil
        }

        // 源语言策略（框架不认 auto，只能自己判，而短句判得很不准）：
        //   auto     —— 检测器说了算，判错就报 language_not_installed
        //   english  —— 除了请求里显式指定的，一律当默认源语言
        //   retry    —— 先按检测结果试，没装包就用默认源语言重试一次
        let source: String
        if let explicit {
            source = explicit
        } else if config.sourceMode == .english {
            source = fallbackSource
        } else {
            source = LanguageDetector.detect(text, fallbackSource: config.defaultSource) ?? fallbackSource
        }

        do {
            return try await perform(text: text, source: source, targetLanguage: targetLanguage)
        } catch let failure as TranslationFailure {
            guard config.sourceMode == .retry,
                  explicit == nil,
                  case .notInstalled = failure,
                  source != fallbackSource else { throw failure }
            Log.info("source \(source) has no pack, retrying as \(fallbackSource)")
            return try await perform(text: text, source: fallbackSource, targetLanguage: targetLanguage)
        }
    }

    /// 真正翻一次。抽出来是为了让 retry 模式能原样重跑一遍。
    private func perform(
        text: String,
        source: String,
        targetLanguage: Language
    ) async throws -> TranslationOutcome {
        // 已经是目标语言就直接还回去，别让「中文翻成中文」把原文搞坏。
        if config.smartSkip, source == targetLanguage.id {
            return TranslationOutcome(
                sourceLanguage: source,
                targetLanguage: targetLanguage.id,
                text: text,
                skipped: true
            )
        }

        let box = box(for: source, target: targetLanguage.id)
        do {
            let response = try await box.translate(text)
            return TranslationOutcome(
                sourceLanguage: response.sourceLanguage,
                targetLanguage: targetLanguage.id,
                text: response.targetText,
                skipped: false
            )
        } catch {
            if error is CancellationError { throw error }
            if !(await box.isReady) {
                throw TranslationFailure.notInstalled(source: source, target: targetLanguage.id)
            }
            throw map(error, source: source, target: targetLanguage.id)
        }
    }

    /// 建一套 session 把首次调用的冷启动开销付掉，免得第一个请求等太久。
    func warmUp() async {
        let target = LanguageCatalog.canonical(config.defaultTarget) ?? "zh-Hans"
        let source = LanguageCatalog.canonical(config.defaultSource) ?? "en"
        guard source != target else { return }
        let box = box(for: source, target: target)
        _ = try? await box.translate("warm up")
    }

    /// 这台 Mac 上 Apple Translation 认得的语言（统一成和 catalog 一致的规范 id）。
    func systemSupportedLanguages() async -> [String] {
        let availability = LanguageAvailability()
        let languages = await availability.supportedLanguages
        // 框架给的是 minimalIdentifier，会出现 "zh" / "en-GB" / "ar-AE" 这种混用写法。
        let normalized = languages.map { language in
            LanguageCatalog.canonical(language.minimalIdentifier) ?? language.maximalIdentifier
        }
        return Array(Set(normalized)).sorted()
    }

    /// 某对语言的语言包状态：installed / supported（没下载）/ unsupported。
    func pairStatus(source rawSource: String, target rawTarget: String) async -> String? {
        guard let source = LanguageCatalog.canonical(rawSource),
              let target = LanguageCatalog.canonical(rawTarget),
              let sourceLanguage = LanguageCatalog.language(for: source),
              let targetLanguage = LanguageCatalog.language(for: target) else { return nil }
        let availability = LanguageAvailability()
        let status = await availability.status(
            from: Locale.Language(identifier: sourceLanguage.id),
            to: Locale.Language(identifier: targetLanguage.id)
        )
        switch status {
        case .installed: return "installed"
        case .supported: return "supported"
        case .unsupported: return "unsupported"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Private

    private func box(for source: String, target: String) -> SessionBox {
        let key = "\(source)|\(target)|\(config.strategyKey)"
        if let existing = boxes[key] { return existing }
        let created = SessionBox(session: makeSession(source: source, target: target))
        boxes[key] = created
        return created
    }

    private func makeSession(source: String, target: String) -> TranslationSession {
        if let preferred = config.translationStrategy, #available(macOS 26.4, *) {
            return TranslationSession(
                installedSource: Locale.Language(identifier: source),
                target: Locale.Language(identifier: target),
                preferredStrategy: preferred == .lowLatency ? .lowLatency : .highFidelity
            )
        }
        return TranslationSession(
            installedSource: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target)
        )
    }

    private func map(_ error: Error, source: String, target: String) -> TranslationFailure {
        if TranslationError.notInstalled ~= error {
            return .notInstalled(source: source, target: target)
        }
        if TranslationError.unsupportedLanguagePairing ~= error {
            return .unsupportedPair(source: source, target: target)
        }
        if TranslationError.unsupportedSourceLanguage ~= error {
            return .unsupportedSource(source)
        }
        if TranslationError.unsupportedTargetLanguage ~= error {
            return .unsupportedTarget(target)
        }
        return .engine(error.localizedDescription)
    }
}
