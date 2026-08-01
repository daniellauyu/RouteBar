import Foundation

public enum SubscriptionStatus: String, Codable, Sendable {
    case idle, updating, success, failed, disabled

    public nonisolated var label: String {
        switch self {
        case .idle: "待更新"
        case .updating: "更新中"
        case .success: "更新成功"
        case .failed: "更新失败"
        case .disabled: "已禁用"
        }
    }

    public nonisolated var symbol: String {
        switch self {
        case .idle: "clock"
        case .updating: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .disabled: "minus.circle.fill"
        }
    }
}

/// 一条订阅。
///
/// 注意这里**没有 URL 字段**：订阅地址含机场凭据，只存钥匙串（`KeychainStore`，以 `id` 为账号），
/// 落盘的 `state.json` 里只有元数据和节点。
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

/// 落盘状态（`~/Library/Application Support/RouteBar/state.json`）。
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

    /// 逐字段容错解码：旧版本写下的 state.json 缺字段时不应整份作废。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscriptions = try container.decodeIfPresent([SubscriptionRecord].self, forKey: .subscriptions) ?? []
        autoUpdatePaused = try container.decodeIfPresent(Bool.self, forKey: .autoUpdatePaused) ?? false
    }
}

/// 自动更新排期。
public enum UpdateSchedule {
    public nonisolated static func nextUpdate(for subscription: SubscriptionRecord) -> Date? {
        subscription.updatedAt?.addingTimeInterval(TimeInterval(subscription.updateIntervalHours * 3600))
    }

    /// 从未更新过的订阅视为立即到期，否则新添加的订阅要等一个完整周期才会首次拉取。
    public nonisolated static func isDue(_ subscription: SubscriptionRecord, at date: Date = .now, isPaused: Bool) -> Bool {
        guard !isPaused, subscription.isEnabled else { return false }
        guard let next = nextUpdate(for: subscription) else { return true }
        return next <= date
    }
}
