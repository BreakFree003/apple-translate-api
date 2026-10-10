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
        let config = self.config
        listener.newConnectionHandler = { [handler, queue, config] connection in
            ConnectionHandler(connection: connection, queue: queue, config: config, handler: handler).start()
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Log.info("listening on http://\(config.host):\(listener.port?.rawValue ?? config.port)")
            case .failed(let error):
                // 端口占用是在这里异步报出来的，`NWListener(using:)` 不会抛 ——
                // 所以排查提示必须放在这一支，别放在 start() 的 catch 里。
                Log.error("listener failed: \(error)")
                Log.error("port \(config.port) may already be in use — set AT_PORT to pick another one.")
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
    /// 单次读上限。请求体上限由 HTTPParse 按 Content-Length 把关，这里只决定分几次收。
    private static let receiveChunk = 64 * 1024

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let config: Config
    private let handler: HTTPServer.Handler
    private var buffer = Data()
    private var sentContinue = false
    private var idleTimer: DispatchSourceTimer?
    /// 自己把自己留住：NWListener 不管连接处理对象，不这么做对象会在 start() 返回后
    /// 立刻释放，receive 回调里的 weak self 全变 no-op，连接就一直挂着不响应。
    private var selfRetain: ConnectionHandler?

    init(connection: NWConnection, queue: DispatchQueue, config: Config, handler: @escaping HTTPServer.Handler) {
        self.connection = connection
        self.queue = queue
        self.config = config
        self.handler = handler
    }

    func start() {
        selfRetain = self
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        armIdleTimeout()
        receive()
    }

    /// 连上却不发请求的连接不能一直吊着 —— 后台服务跑几周，这种连接会攒起来。
    private func armIdleTimeout() {
        let seconds = config.readTimeout
        guard seconds > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Log.info("no complete request within \(Int(seconds))s, closing connection")
            self.close()
        }
        timer.resume()
        idleTimer = timer
    }

    /// 唯一的下线路径。timer 必须先 cancel 再放手 —— 释放一个还活着的
    /// DispatchSourceTimer 会触发 libdispatch 的 "source that has not been cancelled" 崩溃。
    private func close() {
        idleTimer?.cancel()
        idleTimer = nil
        connection.cancel()
        selfRetain = nil
    }

    /// 请求收全了，之后的时间归路由和翻译，不再受空闲超时约束。
    private func disarmIdleTimeout() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunk) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                switch HTTPParse.parse(
                    self.buffer,
                    maxBodyBytes: self.config.maxBodyBytes,
                    maxHeaderBytes: self.config.maxHeaderBytes
                ) {
                case .complete(let request):
                    self.buffer.removeAll()
                    self.disarmIdleTimeout()
                    let writer = ConnectionWriter(connection: self.connection, isHead: request.method == "HEAD")
                    Task {
                        await self.handler(request, writer)
                        await writer.finish()
                    }
                    return
                case .rejected(let rejection):
                    self.reject(rejection)
                    return
                case .incomplete:
                    self.sendContinueIfWaiting()
                }
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            self.receive()
        }
    }

    /// 客户端发了 `Expect: 100-continue` 就先回一个中间响应。不回的话它不会传 body，
    /// 只能等自己的超时 —— .NET / Java 的 HttpClient 对大 body 默认就发这个头。
    private func sendContinueIfWaiting() {
        guard !sentContinue, HTTPParse.expectsContinue(in: buffer) else { return }
        sentContinue = true
        connection.send(
            content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8),
            completion: .contentProcessed { _ in }
        )
    }

    private func reject(_ rejection: HTTPParse.Rejection) {
        disarmIdleTimeout()
        let writer = ConnectionWriter(connection: connection)
        Task {
            await writer.send(.json(rejection.status, APIErrorEnvelope.make(rejection.message, code: rejection.code)))
            await writer.finish()
        }
    }
}

private final class ConnectionWriter: ResponseWriter, @unchecked Sendable {
    private let connection: NWConnection
    private let isHead: Bool
    private let lock = NSLock()
    private var closed = false

    init(connection: NWConnection, isHead: Bool = false) {
        self.connection = connection
        self.isHead = isHead
    }

    func send(_ response: HTTPResponse) async {
        var head = "HTTP/1.1 \(response.status) \(HTTPStatus.reason(response.status))\r\n"
        // RFC 9110 §8.6：204/1xx/304 的语义就包含「没有 body」，再带 Content-Length
        // 会让中间设备以为后面还有东西。
        if !Self.forbidsBody(response.status) {
            head += "Content-Length: \(response.body.count)\r\n"
        }
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += corsHeaders
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        // RFC 9110 §9.3.2：HEAD 的响应只发头；Content-Length 照留（它描述的是等价 GET 的 body）。
        if !isHead {
            payload.append(response.body)
        }
        await write(payload)
    }

    private static func forbidsBody(_ status: Int) -> Bool {
        status == 204 || status == 304 || (100..<200).contains(status)
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
