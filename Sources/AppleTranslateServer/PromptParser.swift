import Foundation

/// 一次 chat 请求拆出来的东西：哪部分是指令、哪部分是要翻的正文、目标语言是什么。
struct PromptAnalysis: Sendable {
    var instruction: String
    var payload: String
    var targetLanguage: String?
}

/// 把「OpenAI 风格的 prompt」还原成「一段待翻译正文 + 语言对」。
///
/// 客户端（Bob、沉浸式翻译、各种 LLM 客户端）发过来的通常不是裸文本，而是
/// 「Translate the following into Chinese:」这种指令加正文。Apple Translation 只会翻译、
/// 不会听话，所以这里做一次尽量保守的切分：**只有看起来确实是指令时才切**，切不准就整段翻。
enum PromptParser {
    private static let translationCues = [
        "translate", "translation", "translating", "translates",
        "翻译", "译成", "译为", "请将", "请把", "帮我把", "把下面", "把以下", "将下面", "将以下",
        "只输出", "只返回", "只给出", "仅输出", "仅返回", "直接输出",
        "output only", "only output", "only return", "return only", "just the translation",
        "不要解释", "无需解释", "不用解释", "do not explain", "don't explain", "no explanation",
    ]

    /// 目标语言的指示词。命中后取其后第一个语言名，且取最靠后的那个。
    private static let targetCues = [
        "翻译成", "翻译为", "译成", "译为", "目标语言", "target language",
        "into ", "to ", "成", "为", "→", "->", "=>",
    ]

    /// 指令段最长这么多字符，超过就不认为是指令（防止把正文里的冒号当成分隔符）。
    private static let maxInstructionLength = 600

    static func analyze(_ content: String) -> PromptAnalysis {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let (instruction, payload) = split(normalized)
        let target = targetLanguage(in: instruction)
        let finalPayload = payload.isEmpty ? clean(normalized) : payload
        return PromptAnalysis(instruction: instruction, payload: finalPayload, targetLanguage: target)
    }

    // MARK: - 切分

    private static func split(_ text: String) -> (instruction: String, payload: String) {
        let lines = text.components(separatedBy: "\n")

        // A. 有一行以冒号结尾，且到这一行为止都是指令 → 冒号之后的所有行是正文。
        if let index = lines.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasSuffix(":") || t.hasSuffix("：")
        }), index + 1 < lines.count {
            let head = lines[0...index].joined(separator: "\n")
            let tail = lines[(index + 1)...].joined(separator: "\n")
            if head.count <= maxInstructionLength, isInstruction(head), !isBlank(tail) {
                return (head, clean(tail))
            }
        }

        // B. 冒号和正文在同一行。
        if let (head, tail) = firstInstructionColon(in: text) {
            return (head, clean(tail))
        }

        // C. 第一行是指令，但没有冒号。
        if let newline = text.firstIndex(of: "\n") {
            let head = String(text[text.startIndex..<newline])
            let tail = String(text[text.index(after: newline)...])
            if head.count <= maxInstructionLength, isInstruction(head), !isBlank(tail) {
                return (head, clean(tail))
            }
        }

        // D. 整段当正文。
        return ("", clean(text))
    }

    private static func firstInstructionColon(in text: String) -> (head: String, tail: String)? {
        let chars = Array(text)
        for (index, char) in chars.enumerated() where char == ":" || char == "：" {
            let head = String(chars[0...index])
            guard head.count <= maxInstructionLength, isInstruction(head) else { continue }
            let tail = index + 1 < chars.count ? String(chars[(index + 1)...]) : ""
            if !isBlank(tail) { return (head, tail) }
        }
        return nil
    }

    private static func isInstruction(_ text: String) -> Bool {
        guard !isBlank(text) else { return false }
        let lower = text.lowercased()
        if translationCues.contains(where: { lower.contains($0) }) { return true }
        // 没有「翻译」字样时，必须同时出现语言名和方向词才算指令。
        let hasMention = !LanguageCatalog.mentions(in: text).isEmpty
        return hasMention && targetCues.contains(where: { lower.contains($0) })
    }

    // MARK: - 目标语言

    static func targetLanguage(in instruction: String) -> String? {
        guard !isBlank(instruction) else { return nil }
        let mentions = LanguageCatalog.mentionOffsets(in: instruction)
        guard !mentions.isEmpty else { return nil }

        let lower = Array(instruction.lowercased())
        var best: (cuePosition: Int, id: String)?
        for cue in targetCues {
            let needle = Array(cue)
            guard !needle.isEmpty, needle.count <= lower.count else { continue }
            var start = 0
            while start <= lower.count - needle.count {
                if Array(lower[start..<(start + needle.count)]) == needle {
                    let after = start + needle.count
                    if let hit = mentions.first(where: { $0.offset >= after }) {
                        if best == nil || start > best!.cuePosition {
                            best = (start, hit.id)
                        }
                    }
                    start += needle.count
                } else {
                    start += 1
                }
            }
        }
        // 没有任何方向词，就认为「最后提到的语言」是目标语言。
        return best?.id ?? mentions.last?.id
    }

    // MARK: - 清理

    private static func clean(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("```"), out.hasSuffix("```"), out.count > 6 {
            var inner = String(out.dropFirst(3).dropLast(3))
            // 去掉 ``` 后面紧跟的语言标注（```markdown 之类）。
            if let newline = inner.firstIndex(of: "\n") {
                let firstLine = inner[inner.startIndex..<newline]
                if !firstLine.contains(" "), firstLine.count <= 20 {
                    inner = String(inner[inner.index(after: newline)...])
                }
            }
            out = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
