import Foundation
import Testing
@testable import RouteBarDomain

struct VLESSParserTests {
    private let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let uri = "vless://11111111-1111-1111-1111-111111111111@hk.example.com:443?security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.apple.com&fp=chrome&pbk=public-key&sid=abcd#香港%2001"

    @Test func parsesPlainTextVLESSSubscription() throws {
        let nodes = try VLESSParser.parseSubscription(Data(uri.utf8), sourceID: sourceID)
        #expect(nodes.count == 1)
        #expect(nodes[0].name == "香港 01")
        #expect(nodes[0].server == "hk.example.com")
        #expect(nodes[0].serverPort == 443)
        #expect(nodes[0].flow == "xtls-rprx-vision")
        #expect(nodes[0].sourceIDs == [sourceID])
    }

    @Test func parsesBase64SubscriptionAndIgnoresMalformedLines() throws {
        let encoded = Data("not-a-node\n\(uri)\n".utf8).base64EncodedString()
        let nodes = try VLESSParser.parseSubscription(Data(encoded.utf8), sourceID: sourceID)
        #expect(nodes.count == 1)
    }

    @Test func mergingDeduplicatesSameEndpointAndCombinesSources() throws {
        let secondSource = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = try VLESSParser.parseSubscription(Data(uri.utf8), sourceID: sourceID)
        let second = try VLESSParser.parseSubscription(Data(uri.utf8), sourceID: secondSource)
        let merged = NodeCatalog.merge(first + second)
        #expect(merged.count == 1)
        #expect(merged[0].sourceIDs == [sourceID, secondSource])
    }

    @Test func parserPreservesDuplicateSubscriptionEntriesForDisplay() throws {
        let renamed = uri.replacingOccurrences(of: "香港%2001", with: "同出口的另一个名称")
        let nodes = try SubscriptionParser.parseSubscription(
            Data("\(uri)\n\(renamed)".utf8), sourceID: sourceID)

        #expect(nodes.count == 2)
        #expect(Set(nodes.map(\.id)).count == 1)
        #expect(Set(nodes.map(\.entryID)).count == 2)
        #expect(Set(nodes.map(\.name)) == ["香港 01", "同出口的另一个名称"])
    }

    @Test func refreshCarriesForwardEnablementAndLatencyForStableNodes() throws {
        var old = try VLESSParser.parseSubscription(Data(uri.utf8), sourceID: sourceID)[0]
        old.isEnabled = false
        old.latency = LatencyRecord(outcome: .success, milliseconds: 76)
        let refreshed = try VLESSParser.parseSubscription(Data(uri.utf8), sourceID: sourceID)
        let carried = NodeCatalog.carryPersistedState(from: [old], to: refreshed)
        #expect(carried[0].isEnabled == false)
        #expect(carried[0].latency?.milliseconds == 76)
    }

    @Test func refreshCarriesStateForEachDuplicateEntryIndependently() throws {
        let renamed = uri.replacingOccurrences(of: "香港%2001", with: "同出口的另一个名称")
        let data = Data("\(uri)\n\(renamed)".utf8)
        var previous = try SubscriptionParser.parseSubscription(data, sourceID: sourceID)
        previous[0].isEnabled = false

        let refreshed = try SubscriptionParser.parseSubscription(data, sourceID: sourceID)
        let carried = NodeCatalog.carryPersistedState(from: previous, to: refreshed)

        #expect(carried.map(\.isEnabled) == [false, true])
    }

    @Test func keepsMixedProtocolNodesFromPlainAndBase64Subscriptions() throws {
        let credentials = Data("aes-128-gcm:secret".utf8).base64EncodedString()
        let vmessObject: [String: Any] = [
            "v": "2", "ps": "新加坡 VMess", "add": "vmess.example.com", "port": "443",
            "id": "22222222-2222-2222-2222-222222222222", "aid": "0", "scy": "auto",
            "net": "ws", "host": "cdn.example.com", "path": "/ws", "tls": "tls",
            "sni": "cdn.example.com",
        ]
        let vmessData = try JSONSerialization.data(withJSONObject: vmessObject)
        let mixed = [
            uri,
            "ss://\(credentials)@ss.example.com:8388#东京%20SS",
            "trojan://p%40ss@trojan.example.com:443?security=tls&sni=example.com&type=grpc&serviceName=edge#美国%20Trojan",
            "vmess://\(vmessData.base64EncodedString())",
            "hysteria2://secret@hy2.example.com:443?sni=edge.example.com&insecure=1#香港%20HY2",
        ].joined(separator: "\n")

        let plain = try SubscriptionParser.parseSubscription(Data(mixed.utf8), sourceID: sourceID)
        let encoded = try SubscriptionParser.parseSubscription(
            Data(Data(mixed.utf8).base64EncodedString().utf8), sourceID: sourceID)

        #expect(plain.count == 5)
        #expect(Set(plain.map(\.protocolType)) == Set(ProxyProtocol.allCases))
        #expect(encoded.map(\.id) == plain.map(\.id))
        #expect(plain.first { $0.protocolType == .shadowsocks }?.method == "aes-128-gcm")
        #expect(plain.first { $0.protocolType == .trojan }?.password == "p@ss")
        #expect(plain.first { $0.protocolType == .vmess }?.transport == "ws")
    }

    @Test func legacyPersistedNodeDecodesAsVLESSReality() throws {
        let legacy = """
        {"id":"legacy","name":"旧节点","server":"old.example.com","serverPort":443,
         "uuid":"11111111-1111-1111-1111-111111111111","flow":"xtls-rprx-vision",
         "serverName":"www.apple.com","publicKey":"pk","shortID":"sid","fingerprint":"chrome",
         "sourceIDs":[],"isEnabled":true}
        """
        let node = try JSONDecoder().decode(ProxyNode.self, from: Data(legacy.utf8))
        #expect(node.protocolType == .vless)
        #expect(node.tlsEnabled)
        #expect(node.protocolLabel == "VLESS-Reality")
    }

    /// 真实订阅会把 Hysteria2 与 VLESS 混在同一份 base64 URI 列表中；不能静默丢掉前者。
    @Test func keepsHysteria2URIFromSubscription() throws {
        let uri = "hysteria2://secret@hy2.example.com:443?sni=edge.example.com&insecure=1#香港%20HY2"
        let nodes = try SubscriptionParser.parseSubscription(Data(uri.utf8), sourceID: sourceID)

        #expect(nodes.count == 1)
        #expect(nodes.first?.protocolLabel == "Hysteria2")
        #expect(nodes.first?.name == "香港 HY2")
        let generated = try ConfigurationGenerator.generate(nodes: nodes)
        let document = try #require(JSONSerialization.jsonObject(with: generated.singBoxJSON) as? [String: Any])
        let outbound = try #require((document["outbounds"] as? [[String: Any]])?.first)
        #expect(outbound["type"] as? String == "hysteria2")
        #expect(outbound["password"] as? String == "secret")
        #expect((outbound["tls"] as? [String: Any])?["insecure"] as? Bool == true)
    }
}

struct SchedulingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func calculatesNextUpdateFromLastSuccess() {
        var subscription = SubscriptionRecord(name: "Primary", updateIntervalHours: 6)
        subscription.updatedAt = now.addingTimeInterval(-5 * 3600)
        #expect(UpdateSchedule.nextUpdate(for: subscription) == now.addingTimeInterval(3600))
        subscription.updatedAt = now.addingTimeInterval(-7 * 3600)
        #expect(UpdateSchedule.isDue(subscription, at: now, isPaused: false))
    }

    @Test func newSubscriptionsAreDueButDisabledOrPausedSubscriptionsAreNot() {
        let enabled = SubscriptionRecord(name: "Enabled")
        var disabled = SubscriptionRecord(name: "Disabled", isEnabled: false)
        disabled.status = .disabled
        #expect(UpdateSchedule.isDue(enabled, at: now, isPaused: false))
        #expect(!UpdateSchedule.isDue(disabled, at: now, isPaused: false))
        #expect(!UpdateSchedule.isDue(enabled, at: now, isPaused: true))
    }

    @Test func latencyResultsBecomeStaleAfterConfiguredAge() {
        let record = LatencyRecord(outcome: .success, milliseconds: 82, measuredAt: now.addingTimeInterval(-601))
        #expect(record.isStale(at: now, maximumAge: 600))
        #expect(!record.isStale(at: now, maximumAge: 700))
    }

    @Test func classifiesEndToEndLatencyUsingRouteBarThresholds() {
        #expect(LatencyClassification.band(for: nil) == .untested)
        #expect(LatencyClassification.band(for: LatencyRecord(outcome: .timeout, milliseconds: nil)) == .failed)
        #expect(LatencyClassification.band(for: LatencyRecord(outcome: .success, milliseconds: 437)) == .fast)
        #expect(LatencyClassification.band(for: LatencyRecord(outcome: .success, milliseconds: 800)) == .medium)
        #expect(LatencyClassification.band(for: LatencyRecord(outcome: .success, milliseconds: 1_428)) == .slow)
    }

    @Test func viewStateCountsEnabledSubscriptionsMergedNodesAndFailures() {
        let source = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let firstNode = ProxyNode(id: "a", name: "A", server: "a.example.com", serverPort: 443,
                                  uuid: UUID().uuidString, flow: "xtls-rprx-vision",
                                  serverName: "www.apple.com", publicKey: "pk", shortID: "sid",
                                  fingerprint: "chrome", sourceIDs: [source], isEnabled: true,
                                  latency: LatencyRecord(outcome: .success, milliseconds: 88, measuredAt: now))
        let secondNode = ProxyNode(id: "b", name: "B", server: "b.example.com", serverPort: 443,
                                   uuid: UUID().uuidString, flow: "xtls-rprx-vision",
                                   serverName: "www.apple.com", publicKey: "pk", shortID: "sid",
                                   fingerprint: "chrome", sourceIDs: [source], isEnabled: false,
                                   latency: LatencyRecord(outcome: .timeout, milliseconds: nil, measuredAt: now))
        let active = SubscriptionRecord(id: source, name: "Active", isEnabled: true, status: .success, nodes: [firstNode, secondNode])
        let failed = SubscriptionRecord(name: "Failed", isEnabled: true, status: .failed)
        let disabled = SubscriptionRecord(name: "Disabled", isEnabled: false, status: .disabled, nodes: [firstNode])

        let state = AppViewState(
            subscriptions: [active, failed, disabled],
            serviceState: .running,
            environment: RouteBarEnvironmentReport(paths: RuntimePaths()) { _ in true },
            settings: RouteBarSettings.defaults(),
            autoUpdatePaused: false
        )

        #expect(state.subscriptions.count == 3)
        #expect(state.enabledSubscriptionCount == 2)
        // 被禁用订阅里的节点不计入合并结果，但仍算进「原始节点数」。
        #expect(state.rawNodeCount == 3)
        #expect(state.displayedNodes.count == 3)
        #expect(state.displayedNodes.contains { !$0.node.isEnabled })
        #expect(state.displayedNodes.contains { !$0.subscriptionEnabled })
        #expect(state.mergedNodes.count == 2)
        #expect(state.enabledNodes.count == 1)
        #expect(state.testedNodeCount == 2)
        #expect(state.failedLatencyCount == 1)
        #expect(state.failedSubscriptionCount == 1)
    }

    @Test func overallStatusFlagsHealthIssuesBeforeReportingRunning() {
        let environment = RouteBarEnvironmentReport(paths: RuntimePaths()) { _ in true }
        // 服务在跑，但一个订阅都没有：这仍然不是「运行正常」。
        let empty = AppViewState(subscriptions: [], serviceState: .running, environment: environment,
                                 settings: RouteBarSettings.defaults(), autoUpdatePaused: false)
        #expect(empty.overall == .needsAttention)

        let failing = AppViewState(subscriptions: [], serviceState: .failed("last exit code 1"),
                                   environment: environment, settings: RouteBarSettings.defaults(),
                                   autoUpdatePaused: false)
        #expect(failing.overall == .failed)
    }
}
