import Foundation
import Network

/// 路由层写响应用的接口：要么一次性返回，要么自己流式写（SSE）。
protocol ResponseWriter: Sendable {
    func send(_ response: HTTPResponse) async
    func beginStream(status: Int, contentType: String, extraHeaders: [String: String]) async
    func write(_ chunk: String) async
    func endStream() async
}

/// 极小的 HTTP/1.1 服务：只监听回环地址，每个连接处理一个请求，响应完就关。
///
/// 刻意不用 chunked 编码 —— 反正一条连接只服务一个请求，用 `Connection: close` 做边界，
/// SSE 也能这么推。
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest, any ResponseWriter) async -> Void

    private let config: Config
    private let handler: Handler
    private let queue = DispatchQueue(label: "apple-translate.api.listener")
    private var listener: NWListener?

    init(config: Config, handler: @escaping Handler) {
        self.config = config
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // 只绑回环地址：不触发 macOS 防火墙弹窗，也不对外暴露。
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(rawValue: config.port) ?? 8787
        )

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [handler, queue] connection in
            ConnectionHandler(connection: connection, queue: queue, handler: handler).start()
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Log.info("listening on http://\(self.config.host):\(listener.port?.rawValue ?? self.config.port)")
            case .failed(let error):
                Log.error("listener failed: \(error)")
                exit(1)
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }
}

// MARK: - 单连接

private final class ConnectionHandler: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPServer.Handler
    private var buffer = Data()
    /// 自己把自己留住：NWListener 不管连接处理对象，不这么做对象会在 start() 返回后
    /// 立刻释放，receive 回调里的 weak self 全变 no-op，连接就一直挂着不响应。
    private var selfRetain: ConnectionHandler?

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping HTTPServer.Handler) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        selfRetain = self
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                guard let self else { return }
                self.connection.cancel()
                self.selfRetain = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if let request = HTTPParse.request(from: self.buffer) {
                    self.buffer.removeAll()
                    let writer = ConnectionWriter(connection: self.connection)
                    Task {
                        await self.handler(request, writer)
                        await writer.finish()
                    }
                    return
                }
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }
}

private final class ConnectionWriter: ResponseWriter, @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var closed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func send(_ response: HTTPResponse) async {
        var head = "HTTP/1.1 \(response.status) \(HTTPStatus.reason(response.status))\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += corsHeaders
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(response.body)
        await write(payload)
    }

    func beginStream(status: Int, contentType: String, extraHeaders: [String: String] = [:]) async {
        var head = "HTTP/1.1 \(status) \(HTTPStatus.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "X-Accel-Buffering: no\r\n"
        for (name, value) in extraHeaders {
            head += "\(name): \(value)\r\n"
        }
        head += corsHeaders
        head += "Connection: close\r\n\r\n"
        await write(Data(head.utf8))
    }

    func write(_ chunk: String) async {
        await write(Data(chunk.utf8))
    }

    func endStream() async {
        await finish()
    }

    /// 兜底关闭：路由处理器忘了关也要关。
    func finish() async {
        guard !markClosed() else { return }
        connection.cancel()
    }

    /// 只在同步上下文里碰锁（async 上下文里 NSLock.lock() 会被编译器拦下）。
    private func markClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let alreadyClosed = closed
        closed = true
        return alreadyClosed
    }

    private var corsHeaders: String {
        "Access-Control-Allow-Origin: *\r\n"
            + "Access-Control-Allow-Headers: *\r\n"
            + "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
    }

    private func write(_ data: Data) async {
        guard !data.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}
