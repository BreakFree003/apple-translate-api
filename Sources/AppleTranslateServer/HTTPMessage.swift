import Foundation

struct HTTPRequest: Sendable {
    let method: String
    /// 原始 request-target，例如 /v1/models?x=1
    let target: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var jsonBody: Any? {
        try? JSONSerialization.jsonObject(with: body)
    }
}

struct HTTPResponse: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ status: Int, _ value: some Encodable) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data(#"{"error":"encoding failed"}"#.utf8)
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data
        )
    }

    static func text(_ status: Int, _ value: String) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(value.utf8)
        )
    }
}

enum HTTPStatus {
    static func reason(_ code: Int) -> String {
        switch code {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        default: "Status"
        }
    }
}

/// 请求头块解析出来的东西（此时还没碰 body）。
private struct HTTPHead {
    let method: String
    let target: String
    let headers: [String: String]
    /// body 在原始 Data 里的起点。
    let bodyStart: Int
}

enum HTTPParse {
    /// 请求体上限默认值：1 MiB。20 000 字符的上限换成最费的编码也远远够。
    static let defaultMaxBodyBytes = 1 << 20
    /// 请求头上限默认值。防住「一直发 header 不发 terminator」把内存拖爆。
    static let defaultMaxHeaderBytes = 64 << 10

    /// 解析结果。`rejected` 表示「头收全了，但这个请求服务端不收」——
    /// 这种要回一个说得清楚的 HTTP 错误，而不是像以前那样把它当空 body 报 invalid_request。
    enum Outcome: Sendable {
        case incomplete
        case complete(HTTPRequest)
        case rejected(Rejection)
    }

    struct Rejection: Sendable {
        let status: Int
        let code: String
        let message: String
    }

    /// 从累积的字节里解出一整个请求；还没收全返回 `.incomplete`。
    static func parse(
        _ data: Data,
        maxBodyBytes: Int = defaultMaxBodyBytes,
        maxHeaderBytes: Int = defaultMaxHeaderBytes
    ) -> Outcome {
        guard let head = head(from: data) else {
            // 头都没收全就已经超过上限 —— 不用再等了。
            if data.count > maxHeaderBytes {
                return .rejected(Rejection(
                    status: 431,
                    code: "headers_too_large",
                    message: "Request headers exceed \(maxHeaderBytes) bytes."
                ))
            }
            return .incomplete
        }

        // 分块传输我们不解码。与其把它当「空 body」报个看不懂的 invalid_request，
        // 不如明确让客户端改用 Content-Length。
        if let encoding = head.headers["transfer-encoding"], encoding.lowercased().contains("chunked") {
            return .rejected(Rejection(
                status: 411,
                code: "length_required",
                message: "Chunked request bodies are not supported. Send Content-Length instead."
            ))
        }

        guard let contentLength = Int(head.headers["content-length"] ?? "0"), contentLength >= 0 else {
            return .rejected(Rejection(
                status: 400,
                code: "invalid_content_length",
                message: "Content-Length must be a non-negative integer."
            ))
        }

        guard contentLength <= maxBodyBytes else {
            return .rejected(Rejection(
                status: 413,
                code: "body_too_large",
                message: "Body is \(contentLength) bytes; the limit is \(maxBodyBytes). "
                       + "Raise it with AT_MAX_BODY if you need to."
            ))
        }

        let bodyOffset = data.distance(from: data.startIndex, to: head.bodyStart)
        guard data.count - bodyOffset >= contentLength else { return .incomplete }

        let body = data.subdata(in: head.bodyStart..<data.index(head.bodyStart, offsetBy: contentLength))
        let (path, query) = splitTarget(head.target)
        return .complete(HTTPRequest(
            method: head.method,
            target: head.target,
            path: path,
            query: query,
            headers: head.headers,
            body: body
        ))
    }

    /// 客户端是不是在等 `100 Continue`？等的话服务端得先回一个中间响应，
    /// 否则它会一直不传 body，直到自己的超时。
    static func expectsContinue(in data: Data) -> Bool {
        guard let head = head(from: data), let expect = head.headers["expect"] else { return false }
        return expect.lowercased().contains("100-continue")
    }

    // MARK: - Private

    private static func head(from data: Data) -> HTTPHead? {
        guard let terminator = headerTerminator(in: data) else { return nil }
        let headData = data[data.startIndex..<terminator.headerEnd]
        guard let text = String(data: headData, encoding: .utf8) else { return nil }

        var lines = text.components(separatedBy: "\r\n")
        if lines.count == 1 { lines = text.components(separatedBy: "\n") }
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        return HTTPHead(
            method: parts[0].uppercased(),
            target: parts[1],
            headers: headers,
            bodyStart: terminator.bodyStart
        )
    }

    private static func headerTerminator(in data: Data) -> (headerEnd: Int, bodyStart: Int)? {
        if let range = data.range(of: Data("\r\n\r\n".utf8)) {
            return (range.lowerBound, range.upperBound)
        }
        if let range = data.range(of: Data("\n\n".utf8)) {
            return (range.lowerBound, range.upperBound)
        }
        return nil
    }

    private static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        guard let mark = target.firstIndex(of: "?") else {
            return (percentDecoded(target), [:])
        }
        let path = String(target[target.startIndex..<mark])
        let rawQuery = String(target[target.index(after: mark)...])
        var query: [String: String] = [:]
        for pair in rawQuery.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = kv.first else { continue }
            let value = kv.count > 1 ? String(kv[1]) : ""
            query[percentDecoded(String(key))] = percentDecoded(value.replacingOccurrences(of: "+", with: " "))
        }
        return (percentDecoded(path), query)
    }

    private static func percentDecoded(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}
