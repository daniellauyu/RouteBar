import Foundation

public struct ProxyNode: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var server: String
    public var serverPort: Int
    public var uuid: String
    public var flow: String
    public var serverName: String
    public var publicKey: String
    public var shortID: String
    public var fingerprint: String
    public var sourceIDs: [UUID]
    public var isEnabled: Bool
    public var latency: LatencyRecord?

    public init(id: String, name: String, server: String, serverPort: Int, uuid: String,
                flow: String, serverName: String, publicKey: String, shortID: String,
                fingerprint: String, sourceIDs: [UUID], isEnabled: Bool, latency: LatencyRecord? = nil) {
        self.id = id
        self.name = name
        self.server = server
        self.serverPort = serverPort
        self.uuid = uuid
        self.flow = flow
        self.serverName = serverName
        self.publicKey = publicKey
        self.shortID = shortID
        self.fingerprint = fingerprint
        self.sourceIDs = sourceIDs
        self.isEnabled = isEnabled
        self.latency = latency
    }
}

public enum NodeCatalog {
    public static func merge(_ nodes: [ProxyNode]) -> [ProxyNode] {
        var merged: [String: ProxyNode] = [:]
        for node in nodes {
            if var existing = merged[node.id] {
                existing.sourceIDs = Array(Set(existing.sourceIDs + node.sourceIDs))
                    .sorted { $0.uuidString < $1.uuidString }
                existing.isEnabled = existing.isEnabled || node.isEnabled
                merged[node.id] = existing
            } else {
                merged[node.id] = node
            }
        }
        return merged.values.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    public static func carryPersistedState(from previous: [ProxyNode], to refreshed: [ProxyNode]) -> [ProxyNode] {
        let oldByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        return refreshed.map { node in
            var node = node
            if let old = oldByID[node.id] {
                node.isEnabled = old.isEnabled
                node.latency = old.latency
            }
            return node
        }
    }
}

public struct PortMappedNode: Sendable {
    public let node: ProxyNode
    public let localPort: Int
}

public struct GeneratedConfiguration: Sendable {
    public let nodes: [PortMappedNode]
    public let singBoxJSON: Data
    public let surgeProxySection: String
}

public struct RuntimePaths: Sendable, Equatable {
    public let home: URL
    public let userID: uid_t
    public let settings: RouteBarSettings

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                userID: uid_t = getuid(),
                settings: RouteBarSettings? = nil) {
        self.home = home
        self.userID = userID
        self.settings = settings ?? RouteBarSettings.defaults(home: home)
    }

    public var label: String { settings.launchAgentLabel }
    public var singBoxBinary: URL { URL(fileURLWithPath: settings.singBoxBinaryPath) }
    public var singBoxConfig: URL { URL(fileURLWithPath: settings.singBoxConfigPath) }
    public var singBoxLog: URL { URL(fileURLWithPath: settings.singBoxLogPath) }
    public var singBoxErrorLog: URL { URL(fileURLWithPath: settings.singBoxErrorLogPath) }
    public var surgeProfile: URL { URL(fileURLWithPath: settings.surgeProfilePath) }
    public var launchAgent: URL { URL(fileURLWithPath: settings.launchAgentPath) }
    public var appSupportDirectory: URL { home.appendingPathComponent("Library/Application Support/RouteBar", isDirectory: true) }
    public var surgeProfilesDirectory: URL { home.appendingPathComponent("Library/Application Support/Surge/Profiles", isDirectory: true) }
    public var singBoxConfigDirectory: URL { singBoxConfig.deletingLastPathComponent() }
    public var launchctlTarget: String { "gui/\(userID)/\(settings.launchAgentLabel)" }
}

public struct RouteBarSettings: Codable, Equatable, Sendable {
    public var singBoxBinaryPath: String
    public var singBoxConfigPath: String
    public var singBoxLogPath: String
    public var singBoxErrorLogPath: String
    public var surgeProfilePath: String
    public var launchAgentPath: String
    public var launchAgentLabel: String

    public init(singBoxBinaryPath: String,
                singBoxConfigPath: String,
                singBoxLogPath: String,
                singBoxErrorLogPath: String,
                surgeProfilePath: String,
                launchAgentPath: String,
                launchAgentLabel: String) {
        self.singBoxBinaryPath = singBoxBinaryPath
        self.singBoxConfigPath = singBoxConfigPath
        self.singBoxLogPath = singBoxLogPath
        self.singBoxErrorLogPath = singBoxErrorLogPath
        self.surgeProfilePath = surgeProfilePath
        self.launchAgentPath = launchAgentPath
        self.launchAgentLabel = launchAgentLabel
    }

    public static func defaults(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> RouteBarSettings {
        let label = "com.daniellau.sing-box-surge"
        return RouteBarSettings(
            singBoxBinaryPath: "/opt/homebrew/bin/sing-box",
            singBoxConfigPath: home.appendingPathComponent(".config/sing-box/surge-vless.json").path,
            singBoxLogPath: home.appendingPathComponent(".config/sing-box/surge-vless.log").path,
            singBoxErrorLogPath: home.appendingPathComponent(".config/sing-box/surge-vless-error.log").path,
            surgeProfilePath: home.appendingPathComponent("Library/Application Support/Surge/Profiles/surge-singbox.conf").path,
            launchAgentPath: home.appendingPathComponent("Library/LaunchAgents/\(label).plist").path,
            launchAgentLabel: label
        )
    }
}

public enum EnvironmentItemState: String, Codable, Sendable {
    case ready
    case missing
}

public struct RouteBarEnvironmentReport: Equatable, Sendable {
    public let singBoxBinary: EnvironmentItemState
    public let surgeProfilesDirectory: EnvironmentItemState
    public let surgeProfile: EnvironmentItemState
    public let singBoxConfigDirectory: EnvironmentItemState
    public let launchAgent: EnvironmentItemState

    public init(paths: RuntimePaths, exists: (URL) -> Bool) {
        singBoxBinary = exists(paths.singBoxBinary) ? .ready : .missing
        surgeProfilesDirectory = exists(paths.surgeProfilesDirectory) ? .ready : .missing
        surgeProfile = exists(paths.surgeProfile) ? .ready : .missing
        singBoxConfigDirectory = exists(paths.singBoxConfigDirectory) ? .ready : .missing
        launchAgent = exists(paths.launchAgent) ? .ready : .missing
    }

    public var needsSetup: Bool {
        [singBoxBinary, surgeProfilesDirectory, surgeProfile, singBoxConfigDirectory, launchAgent].contains(.missing)
    }
}

public enum ServiceState: Equatable, Sendable {
    case running
    case stopped
    case failed(String)
}

public enum LaunchCtlStatusParser {
    public static func parse(exitCode: Int32, output: String) -> ServiceState {
        guard exitCode == 0 else { return .stopped }
        if output.contains("state = running") { return .running }
        if let lastExitCode = firstCapture(in: output, pattern: #"last exit code = ([0-9]+)"#),
           lastExitCode != "0" {
            let state = firstCapture(in: output, pattern: #"state = ([A-Za-z]+)"#) ?? "unknown"
            return .failed("launchctl state \(state), last exit code \(lastExitCode)")
        }
        return .stopped
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

public enum SubscriptionStatus: String, Codable, Sendable {
    case idle, updating, success, failed, disabled
}

public struct SubscriptionRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var note: String
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date?
    public var updateIntervalHours: Int
    public var status: SubscriptionStatus
    public var lastError: String?
    public var nodes: [ProxyNode]

    public init(id: UUID = UUID(), name: String, note: String = "", isEnabled: Bool = true,
                createdAt: Date = .now, updatedAt: Date? = nil, updateIntervalHours: Int = 6,
                status: SubscriptionStatus = .idle, lastError: String? = nil, nodes: [ProxyNode] = []) {
        self.id = id
        self.name = name
        self.note = note
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updateIntervalHours = updateIntervalHours
        self.status = status
        self.lastError = lastError
        self.nodes = nodes
    }
}

public struct RouteBarState: Codable, Sendable {
    public var subscriptions: [SubscriptionRecord]
    public var autoUpdatePaused: Bool

    public init(subscriptions: [SubscriptionRecord] = [], autoUpdatePaused: Bool = false) {
        self.subscriptions = subscriptions
        self.autoUpdatePaused = autoUpdatePaused
    }

    private enum CodingKeys: String, CodingKey {
        case subscriptions
        case autoUpdatePaused
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscriptions = try container.decodeIfPresent([SubscriptionRecord].self, forKey: .subscriptions) ?? []
        autoUpdatePaused = try container.decodeIfPresent(Bool.self, forKey: .autoUpdatePaused) ?? false
    }
}

public struct RouteBarSummary: Sendable, Equatable {
    public let totalSubscriptions: Int
    public let enabledSubscriptions: Int
    public let rawNodes: Int
    public let mergedNodes: Int
    public let enabledNodes: Int
    public let disabledNodes: Int
    public let testedNodes: Int
    public let failedLatencyNodes: Int
    public let failedSubscriptions: Int

    public init(subscriptions: [SubscriptionRecord]) {
        let enabledSubscriptionRecords = subscriptions.filter(\.isEnabled)
        let merged = NodeCatalog.merge(enabledSubscriptionRecords.flatMap(\.nodes))
        totalSubscriptions = subscriptions.count
        enabledSubscriptions = enabledSubscriptionRecords.count
        rawNodes = subscriptions.reduce(0) { $0 + $1.nodes.count }
        mergedNodes = merged.count
        enabledNodes = merged.filter(\.isEnabled).count
        disabledNodes = merged.filter { !$0.isEnabled }.count
        testedNodes = merged.filter { $0.latency != nil }.count
        failedLatencyNodes = merged.filter { $0.latency != nil && $0.latency?.outcome != .success }.count
        failedSubscriptions = subscriptions.filter { $0.status == .failed }.count
    }
}

public enum LatencyOutcome: String, Codable, Sendable {
    case success, timeout, connectionFailed, httpFailed
}

public struct LatencyRecord: Codable, Hashable, Sendable {
    public var outcome: LatencyOutcome
    public var milliseconds: Int?
    public var measuredAt: Date

    public init(outcome: LatencyOutcome, milliseconds: Int?, measuredAt: Date = .now) {
        self.outcome = outcome
        self.milliseconds = milliseconds
        self.measuredAt = measuredAt
    }

    public func isStale(at date: Date = .now, maximumAge: TimeInterval = 600) -> Bool {
        date.timeIntervalSince(measuredAt) > maximumAge
    }
}

public enum UpdateSchedule {
    public static func nextUpdate(for subscription: SubscriptionRecord) -> Date? {
        subscription.updatedAt?.addingTimeInterval(TimeInterval(subscription.updateIntervalHours * 3600))
    }

    public static func isDue(_ subscription: SubscriptionRecord, at date: Date = .now, isPaused: Bool) -> Bool {
        guard !isPaused, subscription.isEnabled else { return false }
        guard let next = nextUpdate(for: subscription) else { return true }
        return next <= date
    }
}
