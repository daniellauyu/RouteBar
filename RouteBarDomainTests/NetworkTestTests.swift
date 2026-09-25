import Foundation
import Network
import Testing
@testable import RouteBarDomain

@Suite struct NetworkTestTests {
    @Test func referenceParsersRejectErrorPagesAndInvalidAddresses() {
        #expect(NetworkTestParser.referenceIP(Data("当前 IP：152.175.6.85  来自于：中国 香港   sakura.as\n".utf8),
                                             service: "myip.ipip.net") == "152.175.6.85")
        #expect(NetworkTestParser.referenceIP(Data("fl=123\nip=2001:db8::1\nloc=HK\n".utf8),
                                             service: "Cloudflare") == "2001:db8::1")
        #expect(NetworkTestParser.referenceIP(Data("<html>IP: 152.175.6.85</html>".utf8), service: "myip.ipip.net") == nil)
        #expect(NetworkTestParser.referenceIP(Data("ip=999.2.3.4\n".utf8), service: "Cloudflare") == nil)
        #expect(NetworkTestParser.referenceIP(Data("ip=1.2.3.4\nip=5.6.7.8".utf8), service: "Cloudflare") == nil)
    }

    @Test func deniedRequestKeepsEvidenceWithoutLeakingKeyOrClaimingAnExit() async {
        let capture = ProbeCapture()
        let key = "sk-test-private-value"
        let tester = NetworkTester { request, route in
            await capture.append(request, route: route)
            if request.url?.host == "dashscope.aliyuncs.com" {
                return NetworkProbeResponse(statusCode: 403,
                    body: Data("{\"error\":{\"code\":\"AccessDenied\",\"message\":\"IP access denied by API-Key restriction. sk-test-private-value\"},\"request_id\":\"req-123\"}".utf8),
                    localAddress: "198.18.0.1", remoteAddress: "203.0.113.1", elapsed: 0.4)
            }
            let body = request.url?.host == "myip.ipip.net" ? "当前 IP：1.2.3.4  来自于：测试" : "ip=5.6.7.8\nloc=HK"
            return NetworkProbeResponse(statusCode: 200, body: Data(body.utf8))
        }
        let route = NetworkTestRoute.node(name: "测试节点", port: 7701)
        let result = await tester.run(route: route, apiKey: key)
        #expect(result.ipRestricted)
        #expect(result.response.requestID == "req-123")
        #expect(result.referenceIPsDiffer)
        #expect(result.sourceIPExplanation.contains("未确认"))
        #expect(!result.report.contains(key))
        #expect(result.response.body.isEmpty)
        #expect(result.report.contains("连接对端（非出口 IP）：203.0.113.1"))
        let requests = await capture.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.1 == route && $0.0.httpMethod == "GET" && $0.0.httpBody == nil })
        for (request, _) in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") ==
                    (request.url?.host == "dashscope.aliyuncs.com" ? "Bearer \(key)" : nil))
        }
    }

    @Test func unauthenticatedReachabilityDoesNotClaimWhitelistPassed() async {
        let result = await NetworkTester { request, _ in
            if request.url?.host == "dashscope.aliyuncs.com" {
                return NetworkProbeResponse(statusCode: 401, requestID: "unauthenticated")
            }
            return NetworkProbeResponse(statusCode: 503, body: Data("ip=1.2.3.4".utf8))
        }.run(route: .withoutProxy)
        #expect(!result.suppliedAPIKey)
        #expect(!result.ipRestricted)
        #expect(result.summary.contains("尚未验证 IP 权限"))
        #expect(result.references.allSatisfy { $0.address == nil })
    }

    @Test func failedTargetDoesNotBecomeSuccessWhenReferenceServicesWork() async {
        let result = await NetworkTester { request, _ in
            if request.url?.host == "dashscope.aliyuncs.com" {
                return NetworkProbeResponse(failure: "连接超时")
            }
            let body = request.url?.host == "myip.ipip.net" ? "当前 IP：1.2.3.4  来自于：测试" : "ip=1.2.3.4\nloc=HK"
            return NetworkProbeResponse(statusCode: 200, body: Data(body.utf8))
        }.run(route: .system)
        #expect(result.summary.contains("连接失败"))
        #expect(result.references.allSatisfy { $0.address == "1.2.3.4" })
        #expect(!result.referenceIPsDiffer)
        #expect(result.sourceIPExplanation.contains("未确认"))
    }

    @Test func explicitRoutesDisableSystemProxyAndPACFallback() {
        let direct = NetworkTester.configuration(for: .withoutProxy).connectionProxyDictionary
        #expect(direct?.isEmpty == true)
        let node = NetworkTester.configuration(for: .node(name: "测试", port: 7712)).proxyConfigurations
        #expect(node.count == 1)
        #expect(node.first?.allowFailover == false)
    }
}

private actor ProbeCapture {
    var requests: [(URLRequest, NetworkTestRoute)] = []
    func append(_ request: URLRequest, route: NetworkTestRoute) { requests.append((request, route)) }
}
