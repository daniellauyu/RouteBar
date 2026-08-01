import Foundation
import Network
import os

/// 只监听回环的极简 HTTP 服务器。
///
/// 承载两样东西：给 Surge 用的 `policy-path` 策略集，和 RouteBar 自己的 Web 界面 + API。
/// 两者同进程同端口，因为它们是同一个信任域——能访问其一就能访问其二。
///
/// **只绑定 127.0.0.1**（`requiredLocalEndpoint`，不是监听全部接口再过滤）。策略集里没有
/// 机场凭据，但 API 能改配置、起停服务，没有任何理由让它出现在局域网上。
///
/// 连接一次一响应随后关闭：没有 keep-alive、没有分块编码。请求方只有 Surge 和自家网页，
/// 复用连接省下的那点开销不值得再引入一套状态机。
public actor LocalHTTPServer {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private var listener: NWListener?
    private var handler: Handler?
    private var port: Int = 0

    public init() {}

    public private(set) var isRunning = false
    /// 最近一次启动失败的原因，供界面展示（端口被占用是最常见的一种）。
    public private(set) var lastError: String?

    /// 启动监听，或在已监听同一端口时就地换掉路由。
    ///
    /// 换 handler 不重启监听：路由表每次都是新闭包，无法比较，而重启会让 Surge 恰好
    /// 在这一刻的拉取失败。端口变了才需要真的重来。
    public func start(port: Int, handler: @escaping Handler) async {
        self.handler = handler
        if isRunning, self.port == port { return }
        stop()
        self.port = port

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0, port < 65_536 else {
            lastError = "端口号非法：\(port)"
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.serve(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.apply(state) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            CoreLog.subscription.error("本地服务启动失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func apply(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            lastError = nil
            CoreLog.subscription.notice("本地服务已监听 127.0.0.1:\(self.port)")
        case .failed(let error):
            isRunning = false
            // 端口被占用是最常见的失败，说清楚比抛一个 NWError 代码有用。
            lastError = error.errorCode == 48
                ? "端口 \(port) 已被占用，请在设置里换一个"
                : error.localizedDescription
            CoreLog.subscription.error("本地服务失败：\(self.lastError ?? "", privacy: .public)")
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - 连接处理

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection, buffer: Data())
    }

    /// 递归收取直到攒够一条完整请求。
    ///
    /// 不能只 receive 一次：请求头会被拆包，带 body 的 POST 更是必然分两段到达。
    /// 单次读取的写法在 body 稍大时会随机地把 JSON 截断成畸形请求。
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if error != nil {
                connection.cancel()
                return
            }

            switch HTTPRequest.parse(accumulated) {
            case .complete(let request):
                Task { await self.respond(to: request, on: connection) }
            case .invalid:
                Self.send(HTTPResponse.badRequest, on: connection, includeBody: true)
            case .incomplete:
                // 对端已经关了写端却还没凑齐一条请求，再等下去就是永远。
                if isComplete {
                    connection.cancel()
                } else {
                    Task { await self.receive(connection, buffer: accumulated) }
                }
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        guard let handler else {
            Self.send(HTTPResponse.error("服务未就绪", status: 500), on: connection, includeBody: true)
            return
        }
        let response = await handler(request)
        // HEAD 只回头部：Surge 会用它探测策略集是否变化。
        Self.send(response, on: connection, includeBody: request.method != "HEAD")
    }

    private nonisolated static func send(_ response: HTTPResponse, on connection: NWConnection, includeBody: Bool) {
        connection.send(content: response.serialized(includeBody: includeBody),
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
