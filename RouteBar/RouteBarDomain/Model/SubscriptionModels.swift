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
    /// 这条订阅的节点名模板，覆盖全局的 `RouteBarSettings.nodeNameTemplate`。
    ///
    /// nil 或空串都表示「跟随全局」。用 `Optional` 而不是 `String` 是为了向后兼容：
    /// 合成的 `Codable` 对可选字段走 `decodeIfPresent`，老 state.json 里没有这个键也解得出来；
    /// 换成非可选，一次升级就会让整份订阅列表解码失败、被静默清空。
    public var nodeNameTemplate: String?
    /// 最近一次**尝试**更新的时刻，成功与否都记。
    ///
    /// 与 `updatedAt`（最近一次**成功**）分开：退避要从上次尝试起算，而失败时
    /// `updatedAt` 按定义不能动——它是「这批节点有多新」，一次失败并不会让节点变新。
    public var lastAttemptAt: Date?
    /// 连续失败次数，成功一次即归零。退避阶梯按它取。
    public var consecutiveFailures: Int

    public nonisolated init(id: UUID = UUID(), name: String, note: String = "", isEnabled: Bool = true,
                            createdAt: Date = .now, updatedAt: Date? = nil, updateIntervalHours: Int = 6,
                            status: SubscriptionStatus = .idle, lastError: String? = nil, nodes: [ProxyNode] = [],
                            nodeNameTemplate: String? = nil,
                            lastAttemptAt: Date? = nil, consecutiveFailures: Int = 0) {
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
        self.nodeNameTemplate = nodeNameTemplate
        self.lastAttemptAt = lastAttemptAt
        self.consecutiveFailures = consecutiveFailures
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, note, isEnabled, createdAt, updatedAt, updateIntervalHours
        case status, lastError, nodes, nodeNameTemplate
        case lastAttemptAt, consecutiveFailures
    }

    /// 逐字段容错解码。
    ///
    /// `consecutiveFailures` 是非可选的新字段，而合成的 `Codable` **不会**用属性默认值补缺失键，
    /// 它直接抛 `keyNotFound`——那会让整份订阅列表解码失败，被 `StateStore.load` 的
    /// 「解不出来就回落到空状态」静默清空。新增非可选字段必须同时手写这个初始化器。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        updateIntervalHours = try container.decodeIfPresent(Int.self, forKey: .updateIntervalHours) ?? 6
        status = try container.decodeIfPresent(SubscriptionStatus.self, forKey: .status) ?? .idle
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        nodes = try container.decodeIfPresent([ProxyNode].self, forKey: .nodes) ?? []
        nodeNameTemplate = try container.decodeIfPresent(String.self, forKey: .nodeNameTemplate)
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        consecutiveFailures = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
    }
}

/// 落盘状态（`~/Library/Application Support/RouteBar/state.json`）。
public struct RouteBarState: nonisolated Codable, Sendable {
    public var subscriptions: [SubscriptionRecord]
    public var autoUpdatePaused: Bool

    public nonisolated init(subscriptions: [SubscriptionRecord] = [], autoUpdatePaused: Bool = false) {
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
    /// 连续失败后的重试间隔阶梯，第 N 次失败后等第 N 项（超出取最后一项）。
    ///
    /// 没有退避时，失败的订阅会永远「到期」：`updatedAt` 是最近一次**成功**的时刻，
    /// 失败不会推进它，于是调度器每 30 秒、外加每次窗口激活与系统唤醒，都会再拉一遍。
    /// 一个填错的地址或一夜断网就能打出上千次请求和上千行 ERROR，而日志页正是
    /// 唯一的诊断入口——它会被自己刷屏，真正的错因反而找不到。
    ///
    /// 封顶取 1 小时而不是跟随 `updateIntervalHours`（默认 6 小时）：机场临时抽风是
    /// 常态，等满一个正常周期太久；1 小时既不吵，恢复了也能较快跟上。
    public nonisolated static let retryBackoff: [TimeInterval] = [5 * 60, 15 * 60, 60 * 60]

    /// 连续失败 `failures` 次之后，距离下次自动重试还要等多久。
    public nonisolated static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return retryBackoff[min(failures, retryBackoff.count) - 1]
    }

    /// 下次自动更新的时刻。失败中的订阅按退避阶梯算，否则按正常周期。
    ///
    /// 界面上的「下次更新」读的也是这里：退避期间显示正常周期的话，用户会看着一个
    /// 早就过去的时间干等，以为自动更新坏了。
    public nonisolated static func nextUpdate(for subscription: SubscriptionRecord) -> Date? {
        if subscription.consecutiveFailures > 0, let attempted = subscription.lastAttemptAt {
            return attempted.addingTimeInterval(retryDelay(afterFailures: subscription.consecutiveFailures))
        }
        return subscription.updatedAt?.addingTimeInterval(TimeInterval(subscription.updateIntervalHours * 3600))
    }

    /// 从未更新过的订阅视为立即到期，否则新添加的订阅要等一个完整周期才会首次拉取。
    ///
    /// 只管**自动**更新。用户手动点「更新」走的是 `enabledSubscriptionIDs`，不经过这里，
    /// 所以退避期间照样能立刻重试——退避要挡的是后台的自动重复，不是用户的意图。
    public nonisolated static func isDue(_ subscription: SubscriptionRecord, at date: Date = .now, isPaused: Bool) -> Bool {
        guard !isPaused, subscription.isEnabled else { return false }
        guard let next = nextUpdate(for: subscription) else { return true }
        return next <= date
    }
}
