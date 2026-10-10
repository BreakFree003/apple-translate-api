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
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        default: "Status"
        }
    }
}

enum HTTPParse {
    /// 从累积的字节里解出一整个请求；还没收全就返回 nil。
    static func request(from data: Data) -> HTTPRequest? {
        guard let headerEnd = headerTerminator(in: data) else { return nil }
        let headData = data[data.startIndex..<headerEnd.bodyStart]
        guard let head = String(data: headData, encoding: .utf8) else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        if lines.count == 1 { lines = head.components(separatedBy: "\n") }
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0].uppercased()
        let target = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyOffset = data.distance(from: data.startIndex, to: headerEnd.bodyStart)
        guard data.count - bodyOffset >= contentLength else { return nil }

        let body = data.subdata(in: headerEnd.bodyStart..<data.index(headerEnd.bodyStart, offsetBy: contentLength))

        let (path, query) = splitTarget(target)
        return HTTPRequest(
            method: method,
            target: target,
            path: path,
            query: query,
            headers: headers,
            body: body
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
