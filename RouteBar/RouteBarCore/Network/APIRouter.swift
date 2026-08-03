import Foundation
import os

/// API 能驱动的全部动作。
///
/// 每一项都对应 `AppModel` 上已经存在的、SwiftUI 界面正在用的那个方法——**API 层不新增
/// 任何业务逻辑**。两个前端共用一套动词，防抖、进度、错误提示的行为因此不可能分叉；
/// 若让 API 直连引擎，网页上改完节点就不会触发那 500ms 的合并重装，行为会和窗口里不一样。
public protocol RouteBarAPIHost: AnyObject, Sendable {
    func apiSnapshot() async -> APISnapshot
    /// 给 Surge 拉取的裸策略集。
    func apiPolicyList() async -> String
    func apiSaveSubscription(_ input: APISubscriptionInput) async throws
    func apiDeleteSubscription(_ id: UUID) async
    func apiSetSubscriptionEnabled(_ enabled: Bool, id: UUID) async
    func apiUpdateSubscription(_ id: UUID) async
    func apiUpdateAll() async
    func apiSetNodeEnabled(_ enabled: Bool, id: String) async
    func apiTestNode(_ id: String) async
    func apiTestAllNodes() async
    func apiRegenerate() async
    func apiStartService() async
    func apiStopService() async
    func apiRefreshService() async
    func apiSetAutoUpdatePaused(_ paused: Bool) async
    /// 改全局节点名模板（每条订阅的覆盖走 `apiSaveSubscription`）。
    func apiSetNodeNameTemplate(_ template: String) async
    /// 按给定模板试跑，不保存也不改任何东西。
    func apiPreviewNodeNames(_ template: String) async -> APINamingPreview
    func apiLogs() async -> APILogs
}

/// 把 HTTP 请求分派到 `RouteBarAPIHost`。
///
/// 路径一律带令牌前缀：`/<token>/…`。这既是鉴权，也让网页能从自己的 URL 里读出令牌，
/// 不必再往页面里内联一份。
public struct APIRouter: Sendable {
    private let token: String
    private let port: Int
    private weak var host: RouteBarAPIHost?

    public nonisolated init(token: String, port: Int, host: RouteBarAPIHost) {
        self.token = token
        self.port = port
        self.host = host
    }

    /// 交给 `LocalHTTPServer` 的处理闭包。
    public nonisolated func handler() -> @Sendable (HTTPRequest) async -> HTTPResponse {
        { request in await self.route(request) }
    }

    public nonisolated func route(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.isFromLoopback(port: port) else {
            return .error("仅接受来自本机的请求", status: 403)
        }

        var segments = request.segments
        // 令牌不匹配一律 404，不返回 403——403 等于确认「这个端口上确实有 RouteBar」。
        guard let first = segments.first, constantTimeEquals(first, token) else { return .notFound }
        segments.removeFirst()

        guard let host = self.host else { return .error("RouteBar 尚未就绪", status: 500) }

        // Surge 拉取策略集。放在 API 之外：它是给第三方用的稳定契约，不该跟着界面改。
        if segments == ["proxies"] {
            guard request.method == "GET" || request.method == "HEAD" else {
                return .error("不支持的方法", status: 405)
            }
            return .text(await host.apiPolicyList())
        }

        if segments.isEmpty {
            guard request.method == "GET" || request.method == "HEAD" else {
                return .error("不支持的方法", status: 405)
            }
            return .html(WebUIPage.html)
        }

        guard segments.first == "api" else { return .notFound }
        segments.removeFirst()

        // 写操作必须声明 JSON。
        //
        // 这是 CSRF 的关键一环：浏览器对 `application/json` 的跨源请求会先发预检，
        // 而这个服务不返回任何 CORS 头，预检必然失败。没有这一条，恶意页面可以用
        // 表单发出 `text/plain` 的简单 POST——读不到响应，但副作用已经产生了。
        let isMutation = request.method != "GET" && request.method != "HEAD"
        if isMutation {
            let contentType = request.header("content-type") ?? ""
            guard contentType.lowercased().hasPrefix("application/json") else {
                return .error("写操作需要 Content-Type: application/json", status: 403)
            }
        }

        return await dispatch(segments: segments, request: request, host: host)
    }

    /// 按首段分派。
    ///
    /// Swift 的 switch 不支持数组模式（`case ["subscriptions", let id]` 不合法），
    /// 因此按资源分组、组内再看段数，而不是拼一张扁平路由表。
    private nonisolated func dispatch(segments: [String],
                                      request: HTTPRequest,
                                      host: RouteBarAPIHost) async -> HTTPResponse {
        let method = request.method
        let rest = Array(segments.dropFirst())

        switch segments.first {
        case "state":
            guard method == "GET", rest.isEmpty else { return .notFound }
            return encode(await host.apiSnapshot())

        case "logs":
            guard method == "GET", rest.isEmpty else { return .notFound }
            return encode(await host.apiLogs())

        case "update":
            guard method == "POST", rest.isEmpty else { return .notFound }
            await host.apiUpdateAll()
            return encode(await host.apiSnapshot())

        case "regenerate":
            guard method == "POST", rest.isEmpty else { return .notFound }
            await host.apiRegenerate()
            return encode(await host.apiSnapshot())

        case "auto-update":
            guard method == "POST", rest.isEmpty else { return .notFound }
            guard let input: APIEnabledInput = decode(request.body) else { return .badRequest }
            // 请求体里的 enabled 说的是「自动更新开着」，内部存的是「已暂停」。
            await host.apiSetAutoUpdatePaused(!input.enabled)
            return encode(await host.apiSnapshot())

        case "naming":
            guard method == "POST" else { return .notFound }
            guard let input: APINamingInput = decode(request.body) else { return .badRequest }
            // 试跑是只读的，但仍走 POST：模板要放在请求体里，而且写操作那套
            // `Content-Type: application/json` 的跨源防护对它同样适用。
            if rest == ["preview"] {
                return encode(await host.apiPreviewNodeNames(input.template))
            }
            guard rest.isEmpty else { return .notFound }
            await host.apiSetNodeNameTemplate(input.template)
            return encode(await host.apiSnapshot())

        case "subscriptions":
            return await subscriptionRoute(rest, method: method, request: request, host: host)

        case "nodes":
            return await nodeRoute(rest, method: method, request: request, host: host)

        case "service":
            guard method == "POST", rest.count == 1 else { return .notFound }
            switch rest[0] {
            case "start": await host.apiStartService()
            case "stop": await host.apiStopService()
            case "refresh": await host.apiRefreshService()
            default: return .notFound
            }
            return encode(await host.apiSnapshot())

        default:
            return .notFound
        }
    }

    private nonisolated func subscriptionRoute(_ rest: [String],
                                               method: String,
                                               request: HTTPRequest,
                                               host: RouteBarAPIHost) async -> HTTPResponse {
        // 新建 / 编辑：POST /api/subscriptions
        if rest.isEmpty {
            guard method == "POST" else { return .notFound }
            guard let input: APISubscriptionInput = decode(request.body) else { return .badRequest }
            guard !input.name.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .error("订阅名称不能为空", status: 400)
            }
            do {
                try await host.apiSaveSubscription(input)
            } catch {
                return .error(error.localizedDescription, status: 400)
            }
            return encode(await host.apiSnapshot())
        }

        guard let id = UUID(uuidString: rest[0]) else { return .badRequest }

        if rest.count == 1 {
            guard method == "DELETE" else { return .notFound }
            await host.apiDeleteSubscription(id)
            return encode(await host.apiSnapshot())
        }

        guard rest.count == 2, method == "POST" else { return .notFound }
        switch rest[1] {
        case "enabled":
            guard let input: APIEnabledInput = decode(request.body) else { return .badRequest }
            await host.apiSetSubscriptionEnabled(input.enabled, id: id)
        case "update":
            await host.apiUpdateSubscription(id)
        default:
            return .notFound
        }
        return encode(await host.apiSnapshot())
    }

    private nonisolated func nodeRoute(_ rest: [String],
                                       method: String,
                                       request: HTTPRequest,
                                       host: RouteBarAPIHost) async -> HTTPResponse {
        guard method == "POST" else { return .notFound }

        // 全量测速：POST /api/nodes/test。节点 id 是连接参数的 SHA256 十六进制串，
        // 不可能等于 "test"，所以这条捷径不会遮住任何单节点路由。
        if rest == ["test"] {
            await host.apiTestAllNodes()
            return encode(await host.apiSnapshot())
        }

        guard rest.count == 2 else { return .notFound }
        let id = rest[0]
        switch rest[1] {
        case "enabled":
            guard let input: APIEnabledInput = decode(request.body) else { return .badRequest }
            await host.apiSetNodeEnabled(input.enabled, id: id)
        case "test":
            await host.apiTestNode(id)
        default:
            return .notFound
        }
        return encode(await host.apiSnapshot())
    }

    // MARK: - 编解码

    private nonisolated func encode<T: Encodable>(_ value: T) -> HTTPResponse {
        do {
            return .json(try APICoding.encoder().encode(value))
        } catch {
            CoreLog.subscription.error("API 序列化失败：\(error.localizedDescription, privacy: .public)")
            return .error("序列化失败", status: 500)
        }
    }

    private nonisolated func decode<T: Decodable>(_ data: Data) -> T? {
        try? APICoding.decoder().decode(T.self, from: data)
    }

}
