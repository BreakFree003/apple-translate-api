import Foundation

/// 一门 Apple 翻译支持的语言。
struct Language: Sendable, Hashable {
    /// 规范 BCP-47，例如 zh-Hans —— 对外接口一律用这个。
    let id: String
    let english: String
    let chinese: String
    /// 全小写的可识别写法，含英文名、中文名、常见 BCP-47 变体。
    let aliases: [String]
}

/// Apple Translation 在 macOS 27 上支持的 21 种语言（`LanguageAvailability.supportedLanguages` 实测结果）。
enum LanguageCatalog {
    static let all: [Language] = [
        Language(id: "ar", english: "Arabic", chinese: "阿拉伯语",
                 aliases: ["ar", "arabic", "العربية", "阿拉伯语", "阿拉伯文"]),
        Language(id: "de", english: "German", chinese: "德语",
                 aliases: ["de", "de-de", "german", "deutsch", "德语", "德文"]),
        Language(id: "en", english: "English", chinese: "英语",
                 aliases: ["en", "en-us", "en-gb", "english", "英文", "英语"]),
        Language(id: "es", english: "Spanish", chinese: "西班牙语",
                 aliases: ["es", "es-es", "spanish", "español", "espanol", "西班牙语", "西班牙文", "西语"]),
        Language(id: "fr", english: "French", chinese: "法语",
                 aliases: ["fr", "fr-fr", "french", "français", "francais", "法语", "法文"]),
        Language(id: "hi", english: "Hindi", chinese: "印地语",
                 aliases: ["hi", "hindi", "हिन्दी", "印地语", "印地文"]),
        Language(id: "id", english: "Indonesian", chinese: "印尼语",
                 aliases: ["id", "id-id", "indonesian", "bahasa indonesia", "印尼语", "印尼文"]),
        Language(id: "it", english: "Italian", chinese: "意大利语",
                 aliases: ["it", "it-it", "italian", "italiano", "意大利语", "意大利文", "意语"]),
        Language(id: "ja", english: "Japanese", chinese: "日语",
                 aliases: ["ja", "ja-jp", "jp", "japanese", "日本語", "日语", "日文"]),
        Language(id: "ko", english: "Korean", chinese: "韩语",
                 aliases: ["ko", "ko-kr", "korean", "한국어", "韩语", "韩文", "朝鲜语"]),
        Language(id: "nl", english: "Dutch", chinese: "荷兰语",
                 aliases: ["nl", "nl-nl", "dutch", "nederlands", "荷兰语", "荷兰文"]),
        Language(id: "pl", english: "Polish", chinese: "波兰语",
                 aliases: ["pl", "pl-pl", "polish", "polski", "波兰语", "波兰文"]),
        Language(id: "pt", english: "Portuguese", chinese: "葡萄牙语",
                 aliases: ["pt", "pt-br", "pt-pt", "portuguese", "português", "portugues", "葡萄牙语", "葡语"]),
        Language(id: "ru", english: "Russian", chinese: "俄语",
                 aliases: ["ru", "ru-ru", "russian", "русский", "俄语", "俄文"]),
        Language(id: "th", english: "Thai", chinese: "泰语",
                 aliases: ["th", "th-th", "thai", "ไทย", "泰语", "泰文"]),
        Language(id: "tr", english: "Turkish", chinese: "土耳其语",
                 aliases: ["tr", "tr-tr", "turkish", "türkçe", "turkce", "土耳其语", "土耳其文"]),
        Language(id: "uk", english: "Ukrainian", chinese: "乌克兰语",
                 aliases: ["uk", "uk-ua", "ukrainian", "українська", "乌克兰语", "乌克兰文"]),
        Language(id: "vi", english: "Vietnamese", chinese: "越南语",
                 aliases: ["vi", "vi-vn", "vietnamese", "tiếng việt", "tieng viet", "越南语", "越南文"]),
        Language(id: "zh-Hans", english: "Chinese (Simplified)", chinese: "简体中文",
                 aliases: ["zh", "zh-hans", "zh-cn", "zh-sg", "chinese", "chinese (simplified)",
                           "simplified chinese", "mandarin", "中文", "简体中文", "简体", "汉语", "普通话", "中文简体"]),
        Language(id: "zh-Hant", english: "Chinese (Traditional)", chinese: "繁体中文",
                 aliases: ["zh-hant", "zh-tw", "zh-hk", "zh-mo", "traditional chinese",
                           "chinese (traditional)", "繁體中文", "繁体中文", "繁體", "繁体", "中文繁体",
                           "粤语", "cantonese"]),
    ]

    /// 长的别名优先，避免 "en" 抢在 "english" 前面匹配。
    private static let aliasesByLength: [(alias: String, language: Language)] = all
        .flatMap { lang in lang.aliases.map { (alias: $0, language: lang) } }
        .sorted { $0.alias.count > $1.alias.count }

    private static let byID: [String: Language] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id.lowercased(), $0) }
    )

    static func language(for id: String) -> Language? { byID[id.lowercased()] }

    /// 把一个用户/客户端写法（"zh-CN"、"Chinese"、"中文"）转成规范 id。认不出来返回 nil。
    static func canonical(_ raw: String) -> String? {
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        if let exact = byID[needle] { return exact.id }
        if let hit = aliasesByLength.first(where: { $0.alias == needle }) { return hit.language.id }
        // "zh-CN" 这类带地区的写法：先取主语言子标签再试一次。
        if let primary = needle.split(separator: "-").first, let hit = byID[String(primary)] {
            return hit.id
        }
        // 最后再放宽到「包含」匹配，但要求别名足够长，避免误伤。
        if let hit = aliasesByLength.first(where: { $0.alias.count >= 4 && needle.contains($0.alias) }) {
            return hit.language.id
        }
        return nil
    }

    /// 按出现顺序返回文本里提到的语言（长别名优先、不重叠、去重连续重复）。
    static func mentions(in text: String) -> [String] {
        mentionOffsets(in: text).map(\.id)
    }

    /// 同 `mentions`，但带字符偏移（偏移基于 `Array(text.lowercased())`），用于判断
    /// 「这个语言名出现在哪个介词后面」。
    static func mentionOffsets(in text: String) -> [(offset: Int, id: String)] {
        let haystack = Array(text.lowercased())
        var taken = [Bool](repeating: false, count: haystack.count)
        var hits: [(location: Int, language: Language)] = []

        for entry in aliasesByLength {
            let needle = Array(entry.alias)
            guard !needle.isEmpty, needle.count <= haystack.count else { continue }
            var start = 0
            while start <= haystack.count - needle.count {
                var matched = true
                for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                    matched = false
                    break
                }
                if matched, !taken[start..<(start + needle.count)].contains(true) {
                    // 拉丁别名必须整词匹配，否则 "en" 会命中 "enable"。
                    if isBoundarySafe(needle: needle, haystack: haystack, start: start) {
                        for i in start..<(start + needle.count) { taken[i] = true }
                        hits.append((start, entry.language))
                        start += needle.count
                        continue
                    }
                }
                start += 1
            }
        }

        hits.sort { $0.location < $1.location }
        var ordered: [(offset: Int, id: String)] = []
        for hit in hits where ordered.last?.id != hit.language.id {
            ordered.append((hit.location, hit.language.id))
        }
        return ordered
    }

    private static func isBoundarySafe(needle: [Character], haystack: [Character], start: Int) -> Bool {
        let needsBoundary = needle.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard needsBoundary else { return true }
        if start > 0 {
            let before = haystack[start - 1]
            if before.isASCII, before.isLetter || before.isNumber { return false }
        }
        let end = start + needle.count
        if end < haystack.count {
            let after = haystack[end]
            if after.isASCII, after.isLetter || after.isNumber { return false }
        }
        return true
    }
}
