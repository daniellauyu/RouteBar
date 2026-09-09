import Foundation

/// Stream into a bounded buffer; rejecting only after `data(for:)` finishes is too late.
enum BoundedHTTPData {
    enum ReadError: LocalizedError {
        case responseTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .responseTooLarge(let limit): "响应内容超过大小限制（\(limit) 字节）"
            }
        }
    }

    nonisolated static func read(_ request: URLRequest, session: URLSession, limit: Int,
                                 delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        guard response.expectedContentLength <= Int64(limit) else {
            throw ReadError.responseTooLarge(limit)
        }
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        for try await byte in bytes {
            guard data.count < limit else { throw ReadError.responseTooLarge(limit) }
            data.append(byte)
        }
        return (data, response)
    }
}
