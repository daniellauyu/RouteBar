import Foundation
import Network
import os

/// 本地订阅服务：把当前启用节点以 Surge 策略集的形式通过 HTTP 提供出去。
///
/// Surge 的 `policy-path=` 就是这么用的（用户配置里接 sub.store 的正是同一个机制），
/// 好处是完全不碰 Surge 配置文件，可以和别的外部订阅并存。
///
/// **只监听 127.0.0.1。** 内容里没有机场凭据（只有 `socks5, 127.0.0.1, <端口>`，
/// 真正的 VLESS UUID 留在 sing-box.json 里），但没有理由把它暴露到局域网上。
public actor LocalSubscriptionServer {
    private var listener: NWListener?
    private var payload = "" // 当前要返回的策略集
    private var token = ""
    private var port: Int = 0

    public init() {}

    public private(set) var isRunning = false
    /// 最近一次启动失败的原因，供界面展示（端口被占用是最常见的一种）。
    public private(set) var lastError: String?

    /// 启动或重启监听。端口/令牌变了会先停掉旧的。
    public func start(port: Int, token: String, payload: String) async {
        if isRunning, self.port == port, self.token == token {
            self.payload = payload
            return
        }
        stop()
        self.payload = payload
        self.token = token
        self.port = port

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            lastError = "端口号非法：\(port)"
            return
        }
        let parameters = NWParameters.tcp
        // 关键：只绑定回环地址。
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handle(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.apply(state) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            CoreLog.subscription.error("本地订阅服务启动失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func apply(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            lastError = nil
            CoreLog.subscription.notice("本地订阅服务已监听 127.0.0.1:\(self.port)")
        case .failed(let error):
            isRunning = false
            // 端口被占用是最常见的失败，说清楚比抛一个 NWError 代码有用。
            lastError = error.errorCode == 48
                ? "端口 \(port) 已被占用，请在设置里换一个"
                : error.localizedDescription
            CoreLog.subscription.error("本地订阅服务失败：\(self.lastError ?? "", privacy: .public)")
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

    /// 内容变了就换一份，不必重启监听。
    public func update(payload: String) {
        self.payload = payload
    }

    // MARK: - 极简 HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            Task {
                let response = await self.response(for: request)
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func response(for request: String) -> String {
        guard let line = request.components(separatedBy: "\r\n").first else { return Self.badRequest }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { return Self.badRequest }
        // 路径必须完全匹配含令牌的那一条，否则一律 404——不泄露服务的存在细节。
        guard String(parts[1]) == "/\(token)/proxies" else { return Self.notFound }

        let body = payload
        return """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r
        \(body)
        """
    }

    private static let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    private static let badRequest = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
}
