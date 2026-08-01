import Foundation

/// 订阅拉取。
public struct SubscriptionFetcher: Sendable {
    public var timeout: TimeInterval

    public nonisolated init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    public nonisolated func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // 机场面板常按 UA 返回不同格式；固定一个不含版本号的 UA，
        // 输出格式才不会随 RouteBar 升级而变。
        request.setValue("RouteBar (macOS)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw FetchError.httpStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw FetchError.emptyResponse }
        return data
    }

    public enum FetchError: LocalizedError {
        case httpStatus(Int)
        case emptyResponse

        public var errorDescription: String? {
            switch self {
            case .httpStatus(let code): "订阅返回 HTTP \(code)"
            case .emptyResponse: "订阅返回内容为空"
            }
        }
    }
}
