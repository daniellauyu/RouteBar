import Foundation
import Network

/// 只读 GET 模型列表，不提交对话。密钥只在本次请求内存中存在，不写日志或报告。
public struct NetworkTester: Sendable {
    public nonisolated static var target: URL { URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/models")! }
    public typealias Transport = @Sendable (URLRequest, NetworkTestRoute) async -> NetworkProbeResponse
    private let transport: Transport

    public nonisolated init(transport: @escaping Transport = { request, route in
        await NetworkTester.send(request, route: route)
    }) {
        self.transport = transport
    }

    public nonisolated func run(route: NetworkTestRoute, apiKey: String = "") async -> NetworkTestResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = Self.request(Self.target)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let targetRequest = request
        async let targetResponse = transport(targetRequest, route)
        async let domestic = reference("myip.ipip.net", url: URL(string: "https://myip.ipip.net")!, route: route)
        async let cloudflare = reference("Cloudflare", url: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!, route: route)
        let (raw, first, second) = await (targetResponse, domestic, cloudflare)
        let object = (try? JSONSerialization.jsonObject(with: raw.body)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        // 响应可能回显请求中的内容；只保留必要字段并显式移除密钥。
        func clean(_ text: String?) -> String? {
            guard let text else { return nil }
            return String((key.isEmpty ? text : text.replacingOccurrences(of: key, with: "[已隐藏]")).prefix(2000))
        }
        let response = NetworkProbeResponse(statusCode: raw.statusCode,
            requestID: clean(raw.requestID ?? object?["request_id"] as? String),
            localAddress: raw.localAddress, remoteAddress: raw.remoteAddress, usedProxy: raw.usedProxy,
            elapsed: raw.elapsed, failure: clean(raw.failure))
        return NetworkTestResult(route: route, targetURL: Self.target.absoluteString,
            suppliedAPIKey: !key.isEmpty, response: response,
            errorCode: clean(error?["code"] as? String ?? error?["type"] as? String),
            message: clean(error?["message"] as? String), references: [first, second])
    }

    private nonisolated func reference(_ service: String, url: URL, route: NetworkTestRoute) async -> NetworkReferenceIP {
        let response = await transport(Self.request(url), route)
        guard response.failure == nil, let status = response.statusCode, (200..<300).contains(status) else {
            return NetworkReferenceIP(service: service, address: nil,
                failure: response.failure ?? "HTTP \(response.statusCode ?? 0)")
        }
        let address = NetworkTestParser.referenceIP(response.body, service: service)
        return NetworkReferenceIP(service: service, address: address,
                                  failure: address == nil ? "响应不含有效 IP" : nil)
    }

    private nonisolated static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("RouteBar Network Test", forHTTPHeaderField: "User-Agent")
        return request
    }

    public nonisolated static func configuration(for route: NetworkTestRoute) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        switch route {
        case .system: break
        case .withoutProxy:
            config.connectionProxyDictionary = [:]
        case let .node(_, port):
            var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: UInt16(clamping: port))!))
            proxy.allowFailover = false
            config.proxyConfigurations = [proxy]
        }
        return config
    }

    public nonisolated static func send(_ request: URLRequest, route: NetworkTestRoute) async -> NetworkProbeResponse {
        let delegate = NetworkProbeDelegate()
        let session = URLSession(configuration: configuration(for: route), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let metrics = delegate.snapshot
            return NetworkProbeResponse(statusCode: http?.statusCode, body: data,
                requestID: http?.value(forHTTPHeaderField: "x-request-id"),
                localAddress: metrics.local, remoteAddress: metrics.remote, usedProxy: metrics.proxy,
                elapsed: Date().timeIntervalSince(start))
        } catch {
            return NetworkProbeResponse(elapsed: Date().timeIntervalSince(start), failure: error.localizedDescription)
        }
    }
}

private final class NetworkProbeDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var addresses: (local: String?, remote: String?, proxy: Bool?) = (nil, nil, nil)

    nonisolated override init() { super.init() }

    nonisolated var snapshot: (local: String?, remote: String?, proxy: Bool?) {
        lock.lock(); defer { lock.unlock() }
        return addresses
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let last = metrics.transactionMetrics.last else { return }
        lock.lock(); defer { lock.unlock() }
        addresses = (last.localAddress, last.remoteAddress, last.isProxyConnection)
    }

    // 固定探测目标：重定向既不能证明目标连通，也不能携带用户的 key 跳到别处。
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
