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
    private var connections: [UUID: NWConnection] = [:]
    private var connectionDeadlines: [UUID: Task<Void, Never>] = [:]
    private let maximumConnections = 64

    /// 每建一个监听器 +1。
    ///
    /// `NWListener.cancel()` 是异步的：被取代的那一个还会继续吐状态，而且吐的往往正是
    /// `.failed(48)`——占着这个端口的不是别人，就是刚刚接班的新监听器。没有代次判断的话，
    /// 一次正常的重启会让界面显示成「端口已被占用」，而服务其实好好地在跑。
    private var generation: UInt64 = 0

    public init() {}

    public private(set) var isRunning = false
    /// 最近一次启动失败的原因，供界面展示（端口被占用是最常见的一种）。
    public private(set) var lastError: String?

    /// 状态变化的推送出口。
    ///
    /// 监听状态是异步到达的：`start` 返回时通常还没 `.ready`，谁在那一刻读 `isRunning`
    /// 都会读到 false。原来界面只在几个固定时机去拉一次（服务页出现、保存设置），
    /// 于是「已经起来了但界面还停在未启动」是常态。改成起来了就通知。
    private var observer: StateObserver?

    public typealias StateObserver = @Sendable (Bool, String?) async -> Void

    public func observeState(_ observer: @escaping StateObserver) {
        self.observer = observer
    }

    private func notifyObserver() {
        guard let observer else { return }
        let running = isRunning
        let error = lastError
        Task { await observer(running, error) }
    }

    /// 启动监听，或在已监听同一端口时就地换掉路由。
    ///
    /// 换 handler 不重启监听：路由表每次都是新闭包，无法比较，而重启会让 Surge 恰好
    /// 在这一刻的拉取失败。端口变了才需要真的重来。
    public func start(port: Int, handler: @escaping Handler) async {
        self.handler = handler
        // 端口没变就只换路由，不重建监听器。
        //
        // 这里判的是「有没有监听器」而不是 `isRunning`——后者要等 `.ready` 异步到达才为真，
        // 启动后紧接着再调一次（保存设置、重新生成配置都会）就撞进那段空窗，
        // 把刚建好的监听器取消掉再建一个，新的那个转头和自己尚未释放的 socket 抢同一个端口。
        if listener != nil, self.port == port { return }
        stop()
        self.port = port

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0, port < 65_536 else {
            lastError = "端口号非法：\(port)"
            notifyObserver()
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        parameters.allowLocalEndpointReuse = true

        generation += 1
        let generation = self.generation

        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.serve(connection, generation: generation) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.apply(state, generation: generation) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            CoreLog.subscription.error("本地服务启动失败：\(error.localizedDescription, privacy: .public)")
        }
        notifyObserver()
    }

    private func apply(_ state: NWListener.State, generation: UInt64) {
        // 被取代的监听器的迟到状态一律丢弃：它已经不负责这个端口了，
        // 让它改写 `isRunning` / `lastError` 就等于用上一代的结局盖掉这一代的事实。
        guard generation == self.generation else { return }

        defer { notifyObserver() }
        switch state {
        case .ready:
            isRunning = true
            lastError = nil
            CoreLog.subscription.notice("本地服务已监听 127.0.0.1:\(self.port)")
        case .failed(let error):
            listener?.cancel()
            listener = nil
            self.generation += 1
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
        for connection in connections.values { connection.cancel() }
        for deadline in connectionDeadlines.values { deadline.cancel() }
        connections.removeAll()
        connectionDeadlines.removeAll()
        isRunning = false
        // 之后到达的状态都属于上一代，作废掉。
        generation += 1
        // 主动停掉时上一次的失败原因已经过期，留着它会在下次启动失败前一直显示旧错。
        lastError = nil
        notifyObserver()
    }

    // MARK: - 连接处理

    private func serve(_ connection: NWConnection, generation: UInt64) {
        guard generation == self.generation, connections.count < maximumConnections else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { Task { await self?.finishConnection(id) } }
            if case .failed = state { Task { await self?.finishConnection(id) } }
        }
        // A complete request must arrive promptly; handlers may legitimately run longer.
        connectionDeadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            await self?.finishConnection(id)
        }
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection, id: id, buffer: Data())
    }

    private func finishConnection(_ id: UUID) {
        connectionDeadlines.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }

    private func beginResponse(_ request: HTTPRequest, connection: NWConnection, id: UUID) async {
        guard connections[id] != nil else { return }
        connectionDeadlines.removeValue(forKey: id)?.cancel()
        // Bound abandoned long-running API connections, too.
        connectionDeadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(600)) } catch { return }
            await self?.finishConnection(id)
        }
        await respond(to: request, on: connection)
    }

    /// 递归收取直到攒够一条完整请求。
    ///
    /// 不能只 receive 一次：请求头会被拆包，带 body 的 POST 更是必然分两段到达。
    /// 单次读取的写法在 body 稍大时会随机地把 JSON 截断成畸形请求。
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
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
                Task { await self.beginResponse(request, connection: connection, id: id) }
            case .invalid:
                Self.send(HTTPResponse.badRequest, on: connection, includeBody: true)
            case .incomplete:
                // 对端已经关了写端却还没凑齐一条请求，再等下去就是永远。
                if isComplete {
                    connection.cancel()
                } else {
                    Task { await self.receive(connection, id: id, buffer: accumulated) }
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
