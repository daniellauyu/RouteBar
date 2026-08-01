import Foundation
import Testing
@testable import RouteBarDomain

@Suite("HTTP 请求解析")
struct HTTPMessageTests {
    private func parse(_ text: String) -> HTTPParseResult {
        HTTPRequest.parse(Data(text.utf8))
    }

    @Test("解析请求行、查询串与头字段")
    func parsesRequestLineQueryAndHeaders() throws {
        let result = parse("GET /abc123/api/state?filter=hk%20node&bare HTTP/1.1\r\nHost: 127.0.0.1:7899\r\nX-Mixed-Case: Yes\r\n\r\n")
        guard case .complete(let request) = result else {
            Issue.record("应解析成完整请求，实际是 \(result)")
            return
        }
        #expect(request.method == "GET")
        #expect(request.path == "/abc123/api/state")
        #expect(request.segments == ["abc123", "api", "state"])
        #expect(request.query["filter"] == "hk node")
        #expect(request.query["bare"] == "")
        // 头字段名大小写不敏感，调用方不该关心对方怎么写。
        #expect(request.header("x-mixed-case") == "Yes")
        #expect(request.header("HOST") == "127.0.0.1:7899")
    }

    @Test("body 未收齐时报 incomplete 而不是当成畸形请求")
    func waitsForTheDeclaredBodyLength() throws {
        // 这是分包的核心场景：头已到齐，body 还差几个字节。
        // 若把这种情况判成 invalid，稍大的 POST 就会随机失败。
        let head = "POST /t/api/subscriptions HTTP/1.1\r\nHost: 127.0.0.1:7899\r\nContent-Length: 20\r\n\r\n"
        #expect(parse(head) == .incomplete)
        #expect(parse(head + "{\"name\":\"x\"}") == .incomplete)

        let full = head + "{\"name\":\"abcdefghi\"}" // 正好 20 字节
        guard case .complete(let request) = parse(full) else {
            Issue.record("body 收齐后应解析成功")
            return
        }
        #expect(request.body.count == 20)
    }

    @Test("多收到的字节不会混进 body")
    func doesNotOverreadTheBody() throws {
        let text = "POST /t/api/update HTTP/1.1\r\nHost: 127.0.0.1:7899\r\nContent-Length: 2\r\n\r\n{}TRAILING"
        guard case .complete(let request) = parse(text) else {
            Issue.record("应解析成功")
            return
        }
        #expect(String(decoding: request.body, as: UTF8.self) == "{}")
    }

    @Test("没有 body 的请求 body 为空")
    func noBodyMeansEmptyBody() throws {
        guard case .complete(let request) = parse("GET /t/ HTTP/1.1\r\nHost: 127.0.0.1:7899\r\n\r\n") else {
            Issue.record("应解析成功")
            return
        }
        #expect(request.body.isEmpty)
        #expect(request.segments == ["t"])
    }

    @Test("头部过大或 body 过大判为畸形")
    func rejectsOversizedRequests() {
        let hugeHeader = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPRequest.maximumHeaderBytes)
        #expect(parse(hugeHeader) == .invalid)

        let hugeBody = "POST /t/api/update HTTP/1.1\r\nHost: 127.0.0.1:7899\r\nContent-Length: \(HTTPRequest.maximumBodyBytes + 1)\r\n\r\n"
        #expect(parse(hugeBody) == .invalid)
    }

    @Test("请求行不完整判为畸形")
    func rejectsMalformedRequestLine() {
        #expect(parse("GARBAGE\r\n\r\n") == .invalid)
    }
}

@Suite("回环校验")
struct LoopbackGuardTests {
    private func request(host: String?) -> HTTPRequest {
        HTTPRequest(method: "GET", path: "/", headers: host.map { ["host": $0] } ?? [:])
    }

    @Test("只接受端口相符的回环 Host")
    func acceptsOnlyLoopbackHostsOnTheRightPort() {
        #expect(request(host: "127.0.0.1:7899").isFromLoopback(port: 7899))
        #expect(request(host: "localhost:7899").isFromLoopback(port: 7899))
        #expect(request(host: "LocalHost:7899").isFromLoopback(port: 7899))
        #expect(request(host: "[::1]:7899").isFromLoopback(port: 7899))

        // 端口不符：说明请求根本不是发给这个服务的。
        #expect(!request(host: "127.0.0.1:7900").isFromLoopback(port: 7899))
        // 缺 Host 头的请求（HTTP/1.0 客户端）也一并拒掉。
        #expect(!request(host: nil).isFromLoopback(port: 7899))
    }

    @Test("拒绝解析到本机的外部域名")
    func rejectsRebindingDomains() {
        // DNS rebinding 的形态：域名的 A 记录被指向 127.0.0.1，连接确实落在回环上，
        // 唯一能暴露它的就是 Host 头里的域名。
        #expect(!request(host: "evil.example.com:7899").isFromLoopback(port: 7899))
        #expect(!request(host: "127.0.0.1.evil.com:7899").isFromLoopback(port: 7899))
        #expect(!request(host: "192.168.50.18:7899").isFromLoopback(port: 7899))
        // 省略端口意味着 80，而这个服务从不监听 80。
        #expect(!request(host: "127.0.0.1").isFromLoopback(port: 7899))
    }

    @Test("定长比较对长度与内容都敏感")
    func constantTimeComparisonStillCompares() {
        #expect(constantTimeEquals("ea577fc32fcfec45", "ea577fc32fcfec45"))
        #expect(!constantTimeEquals("ea577fc32fcfec45", "ea577fc32fcfec44"))
        #expect(!constantTimeEquals("ea577fc32fcfec4", "ea577fc32fcfec45"))
        #expect(!constantTimeEquals("", ""))
    }
}

@Suite("HTTP 响应序列化")
struct HTTPResponseTests {
    private func head(_ response: HTTPResponse, includeBody: Bool = true) -> String {
        String(decoding: response.serialized(includeBody: includeBody), as: UTF8.self)
    }

    @Test("状态行、长度与安全头都在")
    func writesStatusLengthAndSecurityHeaders() {
        let text = head(.text("hello"))
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 5\r\n"))
        // 页面 URL 里带令牌，任何外链跳转都不该把它捎出去。
        #expect(text.contains("Referrer-Policy: no-referrer\r\n"))
        #expect(text.contains("X-Content-Type-Options: nosniff\r\n"))
        #expect(text.hasSuffix("\r\n\r\nhello"))
    }

    @Test("HEAD 只回头部但 Content-Length 照写")
    func headOmitsBodyButKeepsLength() {
        // Surge 用 HEAD 探测策略集是否变化，长度不写它就判断不出来。
        let text = head(.text("hello"), includeBody: false)
        #expect(text.contains("Content-Length: 5\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test("错误响应是合法 JSON 且转义了引号")
    func errorBodyIsValidJSON() throws {
        let response = HTTPResponse.error("找不到 \"节点\"\n再试一次", status: 404)
        #expect(response.status == 404)
        let decoded = try JSONSerialization.jsonObject(with: response.body) as? [String: String]
        #expect(decoded?["error"] == "找不到 \"节点\"\n再试一次")
    }
}
