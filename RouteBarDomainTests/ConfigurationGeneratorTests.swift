import Foundation
import Testing
@testable import RouteBarDomain

struct ConfigurationGeneratorTests {
    private func makeNode(_ name: String, _ server: String) -> ProxyNode {
        ProxyNode(id: server, name: name, server: server, serverPort: 443,
                  uuid: "11111111-1111-1111-1111-111111111111", flow: "xtls-rprx-vision",
                  serverName: "www.apple.com", publicKey: "public-key", shortID: "abcd",
                  fingerprint: "chrome", sourceIDs: [], isEnabled: true)
    }

    @Test func generatesStablePortsRoutesAndSurgeNodes() throws {
        let input = [makeNode("Tokyo 02", "b.example.com"), makeNode("Hong Kong 01", "a.example.com")]
        let result = try ConfigurationGenerator.generate(nodes: input, startingPort: 7701)
        #expect(result.nodes.count == 2)
        #expect(result.nodes[0].localPort == 7701)
        #expect(result.nodes[1].localPort == 7702)
        let object = try #require(JSONSerialization.jsonObject(with: result.singBoxJSON) as? [String: Any])
        #expect((object["inbounds"] as? [[String: Any]])?.count == 2)
        #expect((object["outbounds"] as? [[String: Any]])?.count == 2)
        let route = try #require(object["route"] as? [String: Any])
        #expect((route["rules"] as? [[String: Any]])?.count == 2)
        #expect(result.surgeProxySection.contains("RouteBar 01 - Hong Kong 01 = socks5, 127.0.0.1, 7701"))
        #expect(result.surgeProxySection.contains("RouteBar 02 - Tokyo 02 = socks5, 127.0.0.1, 7702"))
    }

    @Test func generatesOutboundMatchingEverySupportedProtocol() throws {
        let source = UUID()
        let credentials = Data("aes-256-gcm:secret".utf8).base64EncodedString()
        let vmessJSON = #"{"v":"2","ps":"VMess","add":"vmess.example.com","port":"443","id":"22222222-2222-2222-2222-222222222222","aid":"0","scy":"auto","net":"ws","path":"/ws","host":"cdn.example.com","tls":"tls","sni":"cdn.example.com"}"#
        let vmess = Data(vmessJSON.utf8).base64EncodedString()
        let body = [
            "vless://11111111-1111-1111-1111-111111111111@vless.example.com:443?security=tls&type=ws&path=%2Fedge&sni=vless.example.com#VLESS",
            "ss://\(credentials)@ss.example.com:8388#SS",
            "trojan://secret@trojan.example.com:443?security=tls&sni=trojan.example.com#Trojan",
            "vmess://\(vmess)",
            "hysteria2://secret@hy2.example.com:443?sni=hy2.example.com&insecure=1#Hysteria2",
        ].joined(separator: "\n")
        let nodes = try SubscriptionParser.parseSubscription(Data(body.utf8), sourceID: source)
        let result = try ConfigurationGenerator.generate(nodes: nodes)
        let object = try #require(JSONSerialization.jsonObject(with: result.singBoxJSON) as? [String: Any])
        let outbounds = try #require(object["outbounds"] as? [[String: Any]])
        let types = Set(outbounds.compactMap { $0["type"] as? String })

        #expect(types == ["vless", "shadowsocks", "trojan", "vmess", "hysteria2"])
        #expect(outbounds.first { $0["type"] as? String == "shadowsocks" }?["method"] as? String == "aes-256-gcm")
        #expect(outbounds.first { $0["type"] as? String == "trojan" }?["password"] as? String == "secret")
        #expect((outbounds.first { $0["type"] as? String == "vmess" }?["transport"] as? [String: Any])?["type"] as? String == "ws")
    }

    @Test func runtimePathsExposeManagedConfigLogAndLaunchAgentLocations() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let settings = RouteBarSettings.defaults(
            home: home,
            bundleIdentifier: "com.example.RouteBar",
            executableExists: { _ in true })
        let paths = RuntimePaths(home: home, userID: 501, settings: settings)

        #expect(paths.singBoxConfig.path == "/Users/tester/.config/sing-box/surge-vless.json")
        #expect(paths.singBoxLog.path == "/Users/tester/.config/sing-box/surge-vless.log")
        #expect(paths.singBoxErrorLog.path == "/Users/tester/.config/sing-box/surge-vless-error.log")
        // Label 跟着 bundle id 走，plist 文件名与 launchctl 目标都由它派生。
        #expect(paths.launchAgent.path == "/Users/tester/Library/LaunchAgents/com.example.RouteBar.sing-box.plist")
        #expect(paths.launchctlTarget == "gui/501/com.example.RouteBar.sing-box")
    }

    @Test func runtimePathsCanBeBuiltFromUserSettings() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let settings = RouteBarSettings(
            singBoxBinaryPath: "/usr/local/bin/sing-box",
            singBoxConfigPath: "/tmp/custom-sing-box.json",
            singBoxLogPath: "/tmp/custom.log",
            singBoxErrorLogPath: "/tmp/custom-error.log",
            launchAgentPath: "/tmp/custom.plist",
            launchAgentLabel: "dev.routebar.test"
        )
        let paths = RuntimePaths(home: home, userID: 501, settings: settings)

        #expect(paths.singBoxBinary.path == "/usr/local/bin/sing-box")
        #expect(paths.singBoxConfig.path == "/tmp/custom-sing-box.json")
        #expect(paths.launchAgent.path == "/tmp/custom.plist")
        #expect(paths.launchctlTarget == "gui/501/dev.routebar.test")
    }

    @Test func environmentCheckReportsMissingRequiredPieces() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let paths = RuntimePaths(home: home, userID: 501)
        let existing: Set<String> = [
            paths.singBoxBinary.path,
        ]

        let report = RouteBarEnvironmentReport(paths: paths) { existing.contains($0.path) }

        #expect(report.singBoxBinary == .ready)
        #expect(report.singBoxConfigDirectory == .missing)
        #expect(report.launchAgent == .missing)
        #expect(report.needsSetup)
    }

    @Test func launchctlStatusParserDistinguishesLoadedStoppedAndFailedServices() {
        let running = """
        gui/501/com.daniellau.sing-box-surge = {
            state = running
            last exit code = (never exited)
        }
        """
        let waiting = """
        gui/501/com.daniellau.sing-box-surge = {
            state = waiting
            last exit code = 0
        }
        """
        let failed = """
        gui/501/com.daniellau.sing-box-surge = {
            state = exited
            last exit code = 1
        }
        """

        #expect(LaunchCtlStatusParser.parse(exitCode: 0, output: running) == .running)
        #expect(LaunchCtlStatusParser.parse(exitCode: 0, output: waiting) == .stopped)
        #expect(LaunchCtlStatusParser.parse(exitCode: 0, output: failed) == .failed("launchctl state exited, last exit code 1"))
        #expect(LaunchCtlStatusParser.parse(exitCode: 113, output: "Could not find service") == .stopped)
    }

    /// 「服务没被加载」必须能和「加载了但起不来」区分开：前者 RouteBar 自己 bootstrap 一次就好，
    /// 后者 bootstrap 也救不了，只会把真正的错误盖掉。
    @Test func detectsUnloadedService() {
        let notFound = #"Could not find service "com.daniellau.sing-box-surge" in domain for user gui: 501"#
        #expect(LaunchCtlStatusParser.indicatesServiceNotLoaded(exitCode: 113, output: notFound))
        #expect(LaunchCtlStatusParser.indicatesServiceNotLoaded(exitCode: 3, output: "Boot-out failed: 3: No such process"))
        // 措辞变了但退出码还在（反之亦然）时不能漏判。
        #expect(LaunchCtlStatusParser.indicatesServiceNotLoaded(exitCode: 113, output: ""))
        #expect(LaunchCtlStatusParser.indicatesServiceNotLoaded(exitCode: 1, output: notFound))

        #expect(!LaunchCtlStatusParser.indicatesServiceNotLoaded(exitCode: 0, output: ""))
        #expect(!LaunchCtlStatusParser.indicatesServiceNotLoaded(exitCode: 5, output: "Input/output error"))
        #expect(!LaunchCtlStatusParser.indicatesServiceNotLoaded(exitCode: 1, output: "Operation not permitted"))
    }
}

@Suite struct LatencyTestEndpointTests {
    @Test func resolvesPresetsAndFallsBackOnGarbage() {
        #expect(LatencyTestEndpoint.resolve(LatencyTestEndpoint.gstatic.rawValue).host == "www.gstatic.com")
        #expect(LatencyTestEndpoint.resolve(LatencyTestEndpoint.gstatic.rawValue).scheme == "http")
        #expect(LatencyTestEndpoint.fallback == .gstatic)
        #expect(LatencyTestEndpoint.resolve("https://example.com/204").host == "example.com")

        // 半截 URL、空串、纯文本都不能让测速悄悄打到一个不存在的地址上。
        let fallbackHost = URL(string: LatencyTestEndpoint.fallback.rawValue)?.host
        #expect(LatencyTestEndpoint.resolve("").host == fallbackHost)
        #expect(LatencyTestEndpoint.resolve("https:/").host == fallbackHost)
        #expect(LatencyTestEndpoint.resolve("随便写的").host == fallbackHost)
    }
}

@Suite struct PortMappingTests {
    private func node(_ id: String, enabled: Bool = true) -> ProxyNode {
        ProxyNode(id: id, name: "节点\(id)", server: "\(id).example.com", serverPort: 443,
                  uuid: "11111111-1111-1111-1111-111111111111", flow: "xtls-rprx-vision",
                  serverName: "www.apple.com", publicKey: "pk", shortID: "sid",
                  fingerprint: "chrome", sourceIDs: [UUID()], isEnabled: enabled)
    }

    /// 轻量端口映射与完整生成必须给出完全一致的编号。
    /// 一旦分叉，界面显示的端口就和真正写进 sing-box 的对不上，而这种错位极难察觉。
    @Test func portMappingMatchesFullGeneration() throws {
        let nodes = [node("c"), node("a"), node("b"), node("d", enabled: false)]
        let light = ConfigurationGenerator.portMapping(nodes: nodes)
        let full = try ConfigurationGenerator.generate(nodes: nodes).nodes

        #expect(light.map(\.node.id) == full.map(\.node.id))
        #expect(light.map(\.localPort) == full.map(\.localPort))
        // 禁用节点不占端口，否则启用的节点会跳号。
        #expect(!light.contains { $0.node.id == "d" })
        #expect(light.map(\.localPort) == [7701, 7702, 7703])
    }

    @Test func portMappingHonoursCustomStartingPort() {
        let mapped = ConfigurationGenerator.portMapping(nodes: [node("a"), node("b")], startingPort: 9000)
        #expect(mapped.map(\.localPort) == [9000, 9001])
    }
}
