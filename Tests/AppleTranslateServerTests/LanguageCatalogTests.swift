import Foundation
import Testing

@testable import AppleTranslateServer

@Suite("语言目录")
struct LanguageCatalogTests {
    @Test("目录 20 条、id 不重复")
    func catalogIsSane() {
        #expect(LanguageCatalog.all.count == 20)
        let ids = LanguageCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("en-GB 归并进 en，不占一条 —— 框架原始返回 21 条，去重后是 20")
    func collapsesRegionalVariants() {
        #expect(LanguageCatalog.all.contains { $0.id == "en" })
        #expect(!LanguageCatalog.all.contains { $0.id == "en-GB" })
    }

    @Test("各种写法都能归一到规范 id")
    func canonicalizesAliases() {
        #expect(LanguageCatalog.canonical("ja") == "ja")
        #expect(LanguageCatalog.canonical("jp") == "ja")
        #expect(LanguageCatalog.canonical("Japanese") == "ja")
        #expect(LanguageCatalog.canonical("日本語") == "ja")
        #expect(LanguageCatalog.canonical("日语") == "ja")
        #expect(LanguageCatalog.canonical("EN") == "en")
        #expect(LanguageCatalog.canonical("  zh-Hans  ") == "zh-Hans")
        #expect(LanguageCatalog.canonical("zh-CN") == "zh-Hans")
        #expect(LanguageCatalog.canonical("") == nil)
        #expect(LanguageCatalog.canonical("klingon") == nil)
    }

    @Test("mentions 按出现顺序、不重叠")
    func mentionsKeepOrder() {
        #expect(LanguageCatalog.mentions(in: "Translate from English into Korean") == ["en", "ko"])
        #expect(LanguageCatalog.mentions(in: "The cat sat on the mat.").isEmpty)
    }

    @Test("mentions 不会把词中片段当语言名")
    func mentionsRespectWordBoundaries() {
        // "many" 里含不了语言名，但 "chinese" 里的 "hi"（印地语别名）不该被认出来。
        #expect(!LanguageCatalog.mentions(in: "This is chinese food").contains("hi"))
    }
}
