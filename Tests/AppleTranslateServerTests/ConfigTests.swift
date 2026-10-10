import Foundation
import Testing

@testable import AppleTranslateServer

@Suite("配置解析")
struct ConfigTests {
    @Test("空环境变量 = 全默认")
    func defaults() {
        let c = Config.fromEnvironment([:])
        #expect(c.host == "127.0.0.1")
        #expect(c.port == 8787)
        #expect(c.maxBodyBytes == 1 << 20)
        #expect(c.maxHeaderBytes == 64 << 10)
        #expect(c.readTimeout == 30)
        #expect(c.logRequests)
        #expect(c.sourceMode == .auto)
        #expect(c.translationStrategy == nil)
        #expect(c.strategyKey == "default")
    }

    @Test("正常值被采纳")
    func overrides() {
        let c = Config.fromEnvironment([
            "AT_HOST": "0.0.0.0",
            "AT_PORT": "9999",
            "AT_MAX_BODY": "2048",
            "AT_MAX_HEADERS": "4096",
            "AT_READ_TIMEOUT": "5",
            "AT_SOURCE_MODE": "retry",
            "AT_STRATEGY": "fast",
            "AT_LOG": "0",
        ])
        #expect(c.host == "0.0.0.0")
        #expect(c.port == 9999)
        #expect(c.maxBodyBytes == 2048)
        #expect(c.maxHeaderBytes == 4096)
        #expect(c.readTimeout == 5)
        #expect(c.sourceMode == .retry)
        #expect(c.translationStrategy == .lowLatency)
        #expect(!c.logRequests)
    }

    @Test("乱七八糟的值不该把配置搞崩，退回默认")
    func garbageFallsBack() {
        let c = Config.fromEnvironment([
            "AT_PORT": "not-a-port",
            "AT_PORT_OVERFLOW": "1",
            "AT_MAX_BODY": "0",
            "AT_MAX_HEADERS": "-5",
            "AT_READ_TIMEOUT": "abc",
            "AT_SOURCE_MODE": "whatever",
            "AT_STRATEGY": "whatever",
            "AT_HOST": "",
        ])
        #expect(c.port == 8787)
        #expect(c.maxBodyBytes == 1 << 20)
        #expect(c.maxHeaderBytes == 64 << 10)
        #expect(c.readTimeout == 30)
        #expect(c.sourceMode == .auto)
        #expect(c.translationStrategy == nil)
        #expect(c.host == "127.0.0.1")
    }

    @Test("端口超出 UInt16 就退回默认，不截断")
    func portOverflowFallsBack() {
        #expect(Config.fromEnvironment(["AT_PORT": "70000"]).port == 8787)
        #expect(Config.fromEnvironment(["AT_PORT": "65535"]).port == 65535)
    }

    @Test("AT_READ_TIMEOUT=0 是「不超时」，不是「立刻超时」")
    func zeroReadTimeoutDisablesIt() {
        #expect(Config.fromEnvironment(["AT_READ_TIMEOUT": "0"]).readTimeout == 0)
    }

    @Test("AT_LOG 的假值写法")
    func falsyLogValues() {
        for raw in ["0", "false", "no", "off", "FALSE"] {
            #expect(!Config.fromEnvironment(["AT_LOG": raw]).logRequests, "\(raw) 应判为假")
        }
        for raw in ["1", "true", "yes", "on", ""] {
            #expect(Config.fromEnvironment(["AT_LOG": raw]).logRequests, "\(raw) 应判为真")
        }
    }

    @Test("换策略 = 换一套 session（缓存键要跟着变）")
    func strategyKeyChangesWithStrategy() {
        #expect(Config.fromEnvironment(["AT_STRATEGY": "lowLatency"]).strategyKey == "lowLatency")
        #expect(Config.fromEnvironment(["AT_STRATEGY": "high"]).strategyKey == "highFidelity")
    }
}
