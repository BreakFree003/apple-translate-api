import Foundation
import NaturalLanguage

/// 用系统自带的 NaturalLanguage 猜源语言。
///
/// Apple 的 `TranslationSession(installedSource:target:)` 不接受 `auto`（实测直接抛
/// `unsupportedSourceLanguage`），所以源语言必须自己判。
///
/// 实测坑：短句会被判得很离谱 —— `NLLanguageRecognizer` 认为 "The cat sat on the mat."
/// 是土耳其语（tr 0.58 / en 0.32）。所以这里加了「不够自信时偏向配置的默认源语言」这一步。
/// 注意别用 `languageHints`：实测只要给英语加任何权重的 hint，德语/法语/土耳其语一律被判成英语。
enum LanguageDetector {
    /// 低于这个置信度就认为「完全判不出来」。
    private static let minimumConfidence = 0.25
    /// 达到这个置信度就直接采信，不做任何偏袒。
    private static let confidentThreshold = 0.75
    /// 置信度不到 confidentThreshold 时，默认源语言离第一名在这个差距内就改用它。
    private static let ambiguityMargin = 0.35
    /// 太短的文本判不准。
    private static let minimumLength = 2

    private static let constraints: [NLLanguage] = LanguageCatalog.all.map { NLLanguage(rawValue: $0.id) }

    /// 返回 nil 表示「判不出来」，调用方自己用兜底源语言。
    /// - Parameter fallbackSource: 用户配置的默认源语言，用作短句歧义时的偏向。
    static func detect(_ text: String, fallbackSource: String?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumLength else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = constraints
        recognizer.processString(trimmed)

        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        guard let top = hypotheses.max(by: { $0.value < $1.value }) else { return nil }
        guard top.value >= minimumConfidence else { return nil }
        guard let topLanguage = LanguageCatalog.canonical(top.key.rawValue) else { return nil }

        guard top.value < confidentThreshold,
              let fallbackSource,
              let fallback = LanguageCatalog.canonical(fallbackSource),
              fallback != topLanguage,
              let fallbackScore = hypotheses.first(where: {
                  LanguageCatalog.canonical($0.key.rawValue) == fallback
              })?.value,
              top.value - fallbackScore <= ambiguityMargin else {
            return topLanguage
        }
        return fallback
    }

    /// 诊断用：不做任何裁决，直接给原始候选（按置信度降序）。
    /// 命令行开关 `--detect` 用它解释「为什么判成了这个语言」。
    static func diagnose(_ text: String) -> [(language: String, score: Double)] {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = constraints
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 6)
            .compactMap { key, value in
                LanguageCatalog.canonical(key.rawValue).map { (language: $0, score: value) }
            }
            .sorted { $0.score > $1.score }
    }
}
