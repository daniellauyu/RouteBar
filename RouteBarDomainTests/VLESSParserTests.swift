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

    @Test func refreshCarriesForwardEnablementAndLatencyForStableNodes() throws {
        var old = try VLESSParser.parseSubscription(Data(uri.utf8), sourceID: sourceID)[0]
        old.isEnabled = false
        old.latency = LatencyRecord(outcome: .success, milliseconds: 76)
        let refreshed = try VLESSParser.parseSubscription(Data(uri.utf8), sourceID: sourceID)
        let carried = NodeCatalog.carryPersistedState(from: [old], to: refreshed)
        #expect(carried[0].isEnabled == false)
        #expect(carried[0].latency?.milliseconds == 76)
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
