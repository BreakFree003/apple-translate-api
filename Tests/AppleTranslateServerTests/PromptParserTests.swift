import Foundation
import Testing

@testable import AppleTranslateServer

/// 客户端发来的绝大多数都不是裸文本，而是「指令 + 正文」。切错了就是把指令本身翻出去，
/// 所以这里固定住几条最常遇到的形状。
@Suite("prompt 切分")
struct PromptParserTests {
    @Test("英文指令 + 冒号换行 + 正文")
    func englishInstruction() {
        let analysis = PromptParser.analyze("Translate the following into Japanese:\n\nHello, world.")
        #expect(analysis.targetLanguage == "ja")
        #expect(analysis.payload == "Hello, world.")
        #expect(analysis.instruction.contains("Translate"))
    }

    @Test("中文指令")
    func chineseInstruction() {
        let analysis = PromptParser.analyze("把下面这段翻译成中文：\n\nHello, world.")
        #expect(analysis.targetLanguage == "zh-Hans")
        #expect(analysis.payload == "Hello, world.")
    }

    @Test("冒号和正文同一行")
    func inlineInstruction() {
        let analysis = PromptParser.analyze("Translate this into French: Bonjour le monde")
        #expect(analysis.targetLanguage == "fr")
        #expect(analysis.payload == "Bonjour le monde")
    }

    @Test("围栏里的正文：剥掉 ``` 和语言标注")
    func stripsFences() throws {
        let analysis = PromptParser.analyze("```\nBonjour le monde\n```")
        #expect(analysis.payload == "Bonjour le monde")

        let marked = PromptParser.analyze("```markdown\nBonjour le monde\n```")
        #expect(marked.payload == "Bonjour le monde")
    }

    @Test("没有指令就整段翻，不许把正文切掉")
    func plainTextIsNotSplit() {
        let text = "The cat sat on the mat."
        let analysis = PromptParser.analyze(text)
        #expect(analysis.instruction.isEmpty)
        #expect(analysis.payload == text)
        #expect(analysis.targetLanguage == nil)
    }

    @Test("正文里带冒号、但看起来不是指令：不切")
    func colonWithoutInstructionIsNotSplit() {
        let text = "Note:\nThe cat sat on the mat."
        let analysis = PromptParser.analyze(text)
        #expect(analysis.instruction.isEmpty)
        #expect(analysis.payload == text)
    }

    @Test("目标语言取最靠后的方向词之后那个")
    func targetLanguagePrefersLastCue() {
        // 前面提到英语（源），最后一个方向词后面才是目标。
        let analysis = PromptParser.analyze("Translate from English into Korean:\n\nHello.")
        #expect(analysis.targetLanguage == "ko")
    }

    @Test("CRLF 正文也能切")
    func handlesCRLF() {
        let analysis = PromptParser.analyze("Translate into German:\r\n\r\nGuten Tag.")
        #expect(analysis.targetLanguage == "de")
        #expect(analysis.payload == "Guten Tag.")
    }
}
