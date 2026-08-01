import Foundation

/// 一条已解析完整的 HTTP 请求。
public struct HTTPRequest: Sendable, Equatable {
    public let method: String
    /// 不含查询串的路径，已做百分号解码。
    public let path: String
    public let query: [String: String]
    /// 头字段名一律转小写后作键——HTTP 头名大小写不敏感，调用方不该关心对方怎么写。
    public let headers: [String: String]
    public let body: Data

    public nonisolated init(method: String, path: String, query: [String: String] = [:],
                            headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    public nonisolated func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// 路径按 `/` 切分后的非空段，路由匹配用。
    public nonisolated var segments: [String] {
        path.split(separator: "/").map(String.init)
    }

    /// `Host` 头是否指向本机的指定端口。
    ///
    /// 监听已经绑死 127.0.0.1，但那挡不住 **DNS rebinding**：攻击者把自己域名的 A 记录
    /// 解到 127.0.0.1，浏览器便会以该域名为 Origin 向本机发请求——此时同源策略认为
    /// 这是「自家站点」，响应可读。绑定地址对此无能为力，只有校验 Host 头能否掉它。
    public nonisolated func isFromLoopback(port: Int) -> Bool {
        guard let value = header("host") else { return false }
        let (host, declaredPort) = Self.splitHostHeader(value)
        guard host == "127.0.0.1" || host == "localhost" || host == "::1" else { return false }
        // 省略端口意味着 80，而这个服务从不监听 80。
        guard let declaredPort else { return false }
        return declaredPort == port
    }

    /// 拆 `Host` 头。IPv6 字面量形如 `[::1]:7899`，得先剥括号再找端口冒号，
    /// 否则会把地址内部的冒号当成端口分隔符。
    nonisolated static func splitHostHeader(_ header: String) -> (host: String, port: Int?) {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return ("", nil) }

        if value.hasPrefix("[") {
            guard let closing = value.firstIndex(of: "]") else { return ("", nil) }
            let host = String(value[value.index(after: value.startIndex)..<closing]).lowercased()
            let remainder = value[value.index(after: closing)...]
            guard remainder.hasPrefix(":") else { return (host, nil) }
            return (host, Int(remainder.dropFirst()))
        }
        guard let colon = value.lastIndex(of: ":") else { return (value.lowercased(), nil) }
        return (String(value[value.startIndex..<colon]).lowercased(),
                Int(value[value.index(after: colon)...]))
    }
}

/// 定长字符串比较。
///
/// 令牌只有 16 个十六进制字符，逐位试探时靠响应耗时判断「前缀猜对了没有」在理论上可行。
/// 写成定长比较的成本是几行，没有理由留这个口子。
public nonisolated func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count, !right.isEmpty else { return false }
    var difference: UInt8 = 0
    for index in left.indices { difference |= left[index] ^ right[index] }
    return difference == 0
}

/// 增量解析的结果。
///
/// TCP 不保证一次 `receive` 就能拿到整条请求：请求头可能被拆包，带 body 的 POST 更是
/// 常态。调用方需要能区分「还没收完，继续等」和「这就不是个 HTTP 请求，断开」——
/// 把两者都塞进 `nil` 会让服务器在 body 稍大时随机丢请求。
public enum HTTPParseResult: Sendable, Equatable {
    case incomplete
    case invalid
    case complete(HTTPRequest)
}

extension HTTPRequest {
    /// 头部允许的最大字节数。超过就判定为畸形请求，避免无上限地缓冲。
    public nonisolated static let maximumHeaderBytes = 16 * 1024
    /// body 允许的最大字节数。这个 API 的写入体都是几百字节的 JSON。
    public nonisolated static let maximumBodyBytes = 1024 * 1024

    /// 从累积缓冲区解析一条请求。
    ///
    /// 纯函数：调用方持续追加收到的字节并重复调用，直到不再返回 `.incomplete`。
    public nonisolated static func parse(_ buffer: Data) -> HTTPParseResult {
        guard let headerEnd = range(of: Data("\r\n\r\n".utf8), in: buffer) else {
            if buffer.count > maximumHeaderBytes { return .invalid }
            // 也接受纯 \n 分隔的请求（手写 nc 测试时常见），但仍需完整的空行。
            guard let looseEnd = range(of: Data("\n\n".utf8), in: buffer) else { return .incomplete }
            return parse(buffer, headerEndIndex: looseEnd.lowerBound, bodyStart: looseEnd.upperBound)
        }
        return parse(buffer, headerEndIndex: headerEnd.lowerBound, bodyStart: headerEnd.upperBound)
    }

    private nonisolated static func parse(_ buffer: Data,
                                          headerEndIndex: Data.Index,
                                          bodyStart: Data.Index) -> HTTPParseResult {
        let headerBlock = String(decoding: buffer[buffer.startIndex..<headerEndIndex], as: UTF8.self)
        guard headerBlock.utf8.count <= maximumHeaderBytes else { return .invalid }

        var lines = headerBlock.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return .invalid }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = value
        }

        let (path, query) = splitTarget(target)

        let declaredLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard declaredLength >= 0, declaredLength <= maximumBodyBytes else { return .invalid }
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= declaredLength else { return .incomplete }
        let bodyEnd = buffer.index(bodyStart, offsetBy: declaredLength)
        let body = Data(buffer[bodyStart..<bodyEnd])

        return .complete(HTTPRequest(method: method, path: path, query: query, headers: headers, body: body))
    }

    private nonisolated static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts.first ?? "")
        let path = rawPath.removingPercentEncoding ?? rawPath
        guard parts.count == 2 else { return (path, [:]) }

        var query: [String: String] = [:]
        for pair in parts[1].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            guard !key.isEmpty else { continue }
            let rawValue = kv.count == 2 ? String(kv[1]) : ""
            query[key] = rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawValue
        }
        return (path, query)
    }

    /// `Data` 没有子序列查找，自己扫一遍。请求头只有几百字节，朴素匹配足够。
    private nonisolated static func range(of pattern: Data, in data: Data) -> Range<Data.Index>? {
        guard !pattern.isEmpty, data.count >= pattern.count else { return nil }
        let limit = data.index(data.endIndex, offsetBy: -pattern.count)
        var index = data.startIndex
        while index <= limit {
            var matched = true
            for offset in 0..<pattern.count
            where data[data.index(index, offsetBy: offset)] != pattern[pattern.index(pattern.startIndex, offsetBy: offset)] {
                matched = false
                break
            }
            if matched { return index..<data.index(index, offsetBy: pattern.count) }
            index = data.index(after: index)
        }
        return nil
    }
}

/// 一条待发送的 HTTP 响应。
public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data
    public var extraHeaders: [String: String]

    public nonisolated init(status: Int = 200,
                            contentType: String = "text/plain; charset=utf-8",
                            body: Data = Data(),
                            extraHeaders: [String: String] = [:]) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.extraHeaders = extraHeaders
    }

    public nonisolated static func text(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(string.utf8))
    }

    public nonisolated static func html(_ string: String) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(string.utf8))
    }

    public nonisolated static func json(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    /// 出错时也回 JSON：前端只需要处理一种响应体形状。
    public nonisolated static func error(_ message: String, status: Int) -> HTTPResponse {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return json(Data("{\"error\":\"\(escaped)\"}".utf8), status: status)
    }

    public nonisolated static let notFound = HTTPResponse.error("未找到", status: 404)
    public nonisolated static let badRequest = HTTPResponse.error("请求格式错误", status: 400)

    public nonisolated func serialized(includeBody: Bool = true) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        // 页面里的令牌不应随任何跳转外泄。
        head += "Referrer-Policy: no-referrer\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n"
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        if includeBody { data.append(body) }
        return data
    }

    private nonisolated static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }
}
