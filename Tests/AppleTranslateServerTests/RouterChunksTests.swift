import Testing

@testable import AppleTranslateServer

/// `Router.chunks` 是 SSE 的切块规则。它从 O(n²) 改成 O(n) 时**边界不许动**，
/// 下面这些期望值是从改动前的实现上录下来的（记录现状，不是重新推导规则）。
@Suite("SSE 切块")
struct RouterChunksTests {
    @Test("短文本不切")
    func keepsShortTextWhole() {
        #expect(Router.chunks(of: "hello", limit: 40) == ["hello"])
    }

    @Test("到 limit 之后只在下一个断句符处切")
    func cutsAtBreakCharacterAfterLimit() {
        #expect(Router.chunks(of: "ab。cd，ef", limit: 5) == ["ab。cd，", "ef"])
        // 中间那个 `。` 出现时还没到 limit，所以只能等到最后那个 —— 不是见断句符就切。
        #expect(Router.chunks(of: "a。bcdef。", limit: 3) == ["a。bcdef。"])
        #expect(Router.chunks(of: "今天天气不错，我们去散步吧。", limit: 4) == ["今天天气不错，", "我们去散步吧。"])
    }

    @Test("切完重新计数（漏了 reset 的话这块会切碎）")
    func resetsCountAfterEachChunk() {
        // reset 版两个块；忘记把 count 归零会变成 ["ab。", "c。", "def"]。
        #expect(Router.chunks(of: "ab。c。def", limit: 3) == ["ab。", "c。def"])
    }

    @Test("拼回去还是原文")
    func chunksReassembleToInput() {
        let text = String(repeating: "这是一句中文，还有 English words. ", count: 20)
        let pieces = Router.chunks(of: text)
        #expect(pieces.count > 1)
        #expect(pieces.joined() == text)
    }
}
