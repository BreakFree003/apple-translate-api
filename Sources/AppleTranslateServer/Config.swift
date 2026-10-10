import Foundation

/// 源语言怎么定。框架不认 auto，只能自己判，而短句判得很不准 —— 这决定了判错之后怎么办。
enum SourceMode: String, Sendable {
    /// 检测器说了算。短句被判成没装包的语言时，整条请求 400。
    case auto
    /// 除了请求里显式指定的，一律当默认源语言 —— 适合「99% 都是英文」的用法。
    case english
    /// 先按检测结果试；没装包就用默认源语言重试一次。
    case retry

    static func parse(_ raw: String) -> SourceMode? {
        switch raw.lowercased() {
        case "auto", "detect": .auto
        case "english", "en", "fixed", "force": .english
        case "retry", "fallback": .retry
        default: nil
        }
    }
}

/// 翻译策略。`Strategy` 是 macOS 26.4 才有的 API，没指定时用框架默认行为。
enum TranslationStrategy: String, Sendable {
    case highFidelity
    case lowLatency

    static func parse(_ raw: String) -> TranslationStrategy? {
        switch raw.lowercased() {
        case "highfidelity", "high-fidelity", "high", "quality": .highFidelity
        case "lowlatency", "low-latency", "low", "fast": .lowLatency
        default: nil
        }
    }
}

/// 运行期配置，全部来自环境变量 —— 部署方式无关，怎么起服务就怎么传。
struct Config: Sendable {
    var host: String = "127.0.0.1"
    var port: UInt16 = 8787
    /// 语言识别不可靠时的兜底源语言。
    var defaultSource: String = "en"
    /// 请求里没说目标语言时用哪个。
    var defaultTarget: String = "zh-Hans"
    var modelName: String = "apple-translate"
    var logRequests: Bool = true
    /// 文本已经是目标语言时直接返回原文，不再翻一遍。
    var smartSkip: Bool = true
    /// 单次请求的正文上限（字符）。超了直接报错，免得一个请求把进程拖住。
    var maxCharacters: Int = 20_000
    /// 单次请求正文字节上限。字符上限之外再拦一道 —— 光看 Content-Length 就得挡住，
    /// 不能等收完才知道太大。
    var maxBodyBytes: Int = 1 << 20
    /// 请求头字节上限，防「一直发头不发 terminator」。
    var maxHeaderBytes: Int = 64 << 10
    /// 连接建好后等一个完整请求的秒数；0 = 不超时。只约束收请求，不约束翻译本身。
    var readTimeout: TimeInterval = 30
    /// 源语言策略，见 SourceMode。
    ///
    /// 默认 `english`：绝大多数人的内容就是英文，而 `NLLanguageRecognizer` 会把英文短句
    /// **自信地**判成别的语言（实测 `-m num, --max-count=num ...` → `pt 0.994`，英语 0.005），
    /// 那些语言包没装就整条 400 —— 整页翻译时表现为「一片没翻出来」。不检测就没有这种意外。
    /// 要看别的语种用 `auto`；多语种混杂用 `retry`（没装包才回退到 AT_DEFAULT_SOURCE）。
    var sourceMode: SourceMode = .english
    /// 翻译策略；nil = 用框架默认（不显式指定）。
    var translationStrategy: TranslationStrategy?

    /// session 缓存键的一部分 —— 换策略等于换一套 session。
    var strategyKey: String { translationStrategy?.rawValue ?? "default" }

    static func fromEnvironment() -> Config {
        fromEnvironment(ProcessInfo.processInfo.environment)
    }

    /// 真正干活的那个。拆出带参数的重载是为了能测 —— 进程环境在测试里改不了。
    static func fromEnvironment(_ env: [String: String]) -> Config {
        var c = Config()
        if let v = env["AT_HOST"], !v.isEmpty { c.host = v }
        if let v = env["AT_PORT"], let p = UInt16(v) { c.port = p }
        if let v = env["AT_DEFAULT_SOURCE"], !v.isEmpty { c.defaultSource = v }
        if let v = env["AT_DEFAULT_TARGET"], !v.isEmpty { c.defaultTarget = v }
        if let v = env["AT_MODEL"], !v.isEmpty { c.modelName = v }
        if let v = env["AT_LOG"] { c.logRequests = isTruthy(v) }
        if let v = env["AT_SMART_SKIP"] { c.smartSkip = isTruthy(v) }
        if let v = env["AT_MAX_CHARS"], let n = Int(v), n > 0 { c.maxCharacters = n }
        if let v = env["AT_MAX_BODY"], let n = Int(v), n > 0 { c.maxBodyBytes = n }
        if let v = env["AT_MAX_HEADERS"], let n = Int(v), n > 0 { c.maxHeaderBytes = n }
        if let v = env["AT_READ_TIMEOUT"], let n = Double(v), n >= 0 { c.readTimeout = n }
        if let v = env["AT_SOURCE_MODE"], let mode = SourceMode.parse(v) { c.sourceMode = mode }
        if let v = env["AT_STRATEGY"], let strategy = TranslationStrategy.parse(v) { c.translationStrategy = strategy }
        return c
    }

    private static func isTruthy(_ raw: String) -> Bool {
        !["0", "false", "no", "off"].contains(raw.lowercased())
    }
}
