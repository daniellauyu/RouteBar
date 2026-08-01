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

    @Test func replacesProxySectionAndRouteBarGroupWithoutTouchingRules() throws {
        let generated = try ConfigurationGenerator.generate(nodes: [makeNode("Hong Kong 01", "a.example.com")])
        let profile = """
        [General]
        ipv6 = false
        [Proxy]
        old = socks5, 127.0.0.1, 9999
        [Proxy Group]
        Main = select, sing-box 节点, DIRECT
        sing-box 节点 = select, old
        [Rule]
        FINAL,Main
        """
        let updated = try SurgeProfileUpdater.update(profile, with: generated)
        #expect(updated.contains("RouteBar 01 - Hong Kong 01 = socks5, 127.0.0.1, 7701"))
        #expect(updated.contains("sing-box 节点 = select, \"RouteBar 01 - Hong Kong 01\""))
        #expect(updated.contains("[Rule]\nFINAL,Main"))
        #expect(!updated.contains("old = socks5"))
    }

    @Test func runtimePathsExposeManagedConfigLogAndLaunchAgentLocations() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let paths = RuntimePaths(home: home, userID: 501)

        #expect(paths.singBoxConfig.path == "/Users/tester/.config/sing-box/surge-vless.json")
        #expect(paths.singBoxLog.path == "/Users/tester/.config/sing-box/surge-vless.log")
        #expect(paths.singBoxErrorLog.path == "/Users/tester/.config/sing-box/surge-vless-error.log")
        #expect(paths.surgeProfile.path == "/Users/tester/Library/Application Support/Surge/Profiles/surge-singbox.conf")
        #expect(paths.launchAgent.path == "/Users/tester/Library/LaunchAgents/com.daniellau.sing-box-surge.plist")
        #expect(paths.launchctlTarget == "gui/501/com.daniellau.sing-box-surge")
    }

    @Test func runtimePathsCanBeBuiltFromUserSettings() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let settings = RouteBarSettings(
            singBoxBinaryPath: "/usr/local/bin/sing-box",
            singBoxConfigPath: "/tmp/custom-sing-box.json",
            singBoxLogPath: "/tmp/custom.log",
            singBoxErrorLogPath: "/tmp/custom-error.log",
            surgeProfilePath: "/tmp/custom-surge.conf",
            launchAgentPath: "/tmp/custom.plist",
            launchAgentLabel: "dev.routebar.test"
        )
        let paths = RuntimePaths(home: home, userID: 501, settings: settings)

        #expect(paths.singBoxBinary.path == "/usr/local/bin/sing-box")
        #expect(paths.singBoxConfig.path == "/tmp/custom-sing-box.json")
        #expect(paths.surgeProfile.path == "/tmp/custom-surge.conf")
        #expect(paths.launchAgent.path == "/tmp/custom.plist")
        #expect(paths.launchctlTarget == "gui/501/dev.routebar.test")
    }

    @Test func environmentCheckReportsMissingRequiredPieces() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let paths = RuntimePaths(home: home, userID: 501)
        let existing: Set<String> = [
            paths.singBoxBinary.path,
            paths.surgeProfilesDirectory.path,
        ]

        let report = RouteBarEnvironmentReport(paths: paths) { existing.contains($0.path) }

        #expect(report.singBoxBinary == .ready)
        #expect(report.surgeProfilesDirectory == .ready)
        #expect(report.surgeProfile == .missing)
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
}

@Suite struct LatencyTestEndpointTests {
    @Test func resolvesPresetsAndFallsBackOnGarbage() {
        #expect(LatencyTestEndpoint.resolve(LatencyTestEndpoint.gstatic.rawValue).host == "www.gstatic.com")
        #expect(LatencyTestEndpoint.resolve("https://example.com/204").host == "example.com")

        // 半截 URL、空串、纯文本都不能让测速悄悄打到一个不存在的地址上。
        let fallbackHost = URL(string: LatencyTestEndpoint.fallback.rawValue)?.host
        #expect(LatencyTestEndpoint.resolve("").host == fallbackHost)
        #expect(LatencyTestEndpoint.resolve("https:/").host == fallbackHost)
        #expect(LatencyTestEndpoint.resolve("随便写的").host == fallbackHost)
    }
}
