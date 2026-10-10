import Foundation
import Testing

@testable import AppleTranslateServer

/// 请求解析是这一版新增的把关逻辑（chunked / body 上限 / 100-continue），
/// 出错的表现又是「客户端一直等」这种最难查的形态，所以单独测厚一点。
@Suite("HTTP 请求解析")
struct HTTPParseTests {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    @Test("完整 GET：无 body 也是 complete")
    func parsesSimpleGet() throws {
        let outcome = HTTPParse.parse(data("GET /health HTTP/1.1\r\nHost: x\r\n\r\n"))
        guard case .complete(let request) = outcome else {
            Issue.record("期望 .complete，实际 \(outcome)")
            return
        }
        #expect(request.method == "GET")
        #expect(request.path == "/health")
        #expect(request.body.isEmpty)
    }

    @Test("body 没收全时是 incomplete，收全才 complete")
    func waitsForWholeBody() {
        let head = "POST /v1/translate HTTP/1.1\r\nContent-Length: 13\r\n\r\n"
        if case .complete = HTTPParse.parse(data(head + "{\"text\":\"H")) {
            Issue.record("body 还差 4 字节，不该判为 complete")
        }
        guard case .complete(let request) = HTTPParse.parse(data(head + "{\"text\":\"Hi\"}")) else {
            Issue.record("body 收全了却没判为 complete")
            return
        }
        #expect(String(decoding: request.body, as: UTF8.self) == "{\"text\":\"Hi\"}")
    }

    @Test("多收的字节不算进 body（一条连接一个请求）")
    func ignoresBytesBeyondContentLength() {
        let head = "POST / HTTP/1.1\r\nContent-Length: 2\r\n\r\n"
        guard case .complete(let request) = HTTPParse.parse(data(head + "{}GARBAGE")) else {
            Issue.record("没解析出来")
            return
        }
        #expect(String(decoding: request.body, as: UTF8.self) == "{}")
    }

    @Test("只认 \\n 的客户端也能解析")
    func acceptsLFOnlyHeaders() {
        let outcome = HTTPParse.parse(data("POST /v1/translate HTTP/1.1\nContent-Length: 2\n\n{}"))
        guard case .complete(let request) = outcome else {
            Issue.record("LF-only 头解析失败")
            return
        }
        #expect(request.path == "/v1/translate")
    }

    @Test("chunked 请求体：明确 411，不再冒充空 body")
    func rejectsChunked() {
        let request = data("POST /v1/translate HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n1a\r\n{\"text\":\"Hi\"}\r\n0\r\n\r\n")
        guard case .rejected(let rejection) = HTTPParse.parse(request) else {
            Issue.record("chunked 应该被明确拒绝")
            return
        }
        #expect(rejection.status == 411)
        #expect(rejection.code == "length_required")
    }

    @Test("声明了超大 body：413，且不必等 body 到齐")
    func rejectsOversizedBody() {
        let request = data("POST /v1/translate HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n")
        guard case .rejected(let rejection) = HTTPParse.parse(request) else {
            Issue.record("超大 body 应该被拒绝")
            return
        }
        #expect(rejection.status == 413)
        #expect(rejection.code == "body_too_large")
    }

    @Test("上限按 maxBodyBytes 走，不是写死的")
    func bodyLimitIsConfigurable() {
        let request = data("POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\n")
        if case .rejected = HTTPParse.parse(request, maxBodyBytes: 16) {} else {
            Issue.record("超过自定义上限却没拒绝")
        }
        if case .rejected = HTTPParse.parse(request, maxBodyBytes: 4096) {
            Issue.record("没超上限却被拒绝")
        }
    }

    @Test("Content-Length 不是合法整数：400")
    func rejectsBadContentLength() {
        let request = data("POST / HTTP/1.1\r\nContent-Length: abc\r\n\r\n")
        guard case .rejected(let rejection) = HTTPParse.parse(request) else {
            Issue.record("非法 Content-Length 应该被拒绝")
            return
        }
        #expect(rejection.status == 400)
        #expect(rejection.code == "invalid_content_length")
    }

    @Test("一直发头不发 terminator：431，而不是无限等")
    func rejectsOversizedHeaders() {
        let flood = "GET / HTTP/1.1\r\n" + String(repeating: "X-Pad: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n", count: 100)
        guard case .rejected(let rejection) = HTTPParse.parse(data(flood), maxHeaderBytes: 1024) else {
            Issue.record("超长头应该被拒绝")
            return
        }
        #expect(rejection.status == 431)
    }

    @Test("Expect: 100-continue 能被认出来（大小写、无空格都算）")
    func detectsExpectContinue() {
        let base = "POST / HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 10\r\n\r\n"
        #expect(HTTPParse.expectsContinue(in: data(base)))
        #expect(HTTPParse.expectsContinue(in: data("POST / HTTP/1.1\r\nexpect:100-Continue\r\nContent-Length: 1\r\n\r\n")))
        #expect(!HTTPParse.expectsContinue(in: data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n")))
        // 头还没收全时不能急着回 100。
        #expect(!HTTPParse.expectsContinue(in: data("POST / HTTP/1.1\r\nExpect: 100-con")))
    }

    @Test("query 解析 + 百分号解码")
    func parsesQuery() {
        guard case .complete(let request) = HTTPParse.parse(data("GET /v1/languages?source=en&target=zh-Hans HTTP/1.1\r\n\r\n")) else {
            Issue.record("没解析出来")
            return
        }
        #expect(request.path == "/v1/languages")
        #expect(request.query["source"] == "en")
        #expect(request.query["target"] == "zh-Hans")

        guard case .complete(let encoded) = HTTPParse.parse(data("GET /v1/languages?target=zh%2DHans&q=a+b HTTP/1.1\r\n\r\n")) else {
            Issue.record("没解析出来")
            return
        }
        #expect(encoded.query["target"] == "zh-Hans")
        #expect(encoded.query["q"] == "a b")
    }

    @Test("头名大小写不敏感，method 归一成大写")
    func normalizesHeadersAndMethod() {
        guard case .complete(let request) = HTTPParse.parse(data("post /x HTTP/1.1\r\nCONTENT-LENGTH: 0\r\n\r\n")) else {
            Issue.record("没解析出来")
            return
        }
        #expect(request.method == "POST")
        #expect(request.header("content-length") == "0")
        #expect(request.header("Content-Length") == "0")
    }
}
