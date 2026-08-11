import Foundation
import Security

/// 订阅地址的钥匙串存储：所有订阅的 URL 合成一条 JSON 条目，键是订阅的 UUID。
///
/// 订阅 URL 里带机场的鉴权 token，等价于账号密码，不能进 `state.json`
/// ——那份文件会被备份、被同步、被随手打开看。
///
/// # 为什么是一条而不是一条订阅一条
///
/// login 钥匙串的每条条目各带一张 ACL，各自单独授权。一轮自动更新要读 N 条订阅，
/// 授权对话框就弹 N 次、密码要输 N 遍。合成一条之后最多只有一次。
///
/// # 为什么把 ACL 放开成「任何程序可访问」
///
/// ACL 里记的「可以免密访问的程序」是按代码签名的 designated requirement 匹配的，
/// 而 RouteBar 是 ad-hoc 签名（见 `scripts/package.sh`：公开分发的包不带开发者身份），
/// ad-hoc 的 DR 就是那串 cdhash 本身——**每出一个新版本 cdhash 就变**，用户上次点的
/// 「始终允许」立刻失效，于是每次升级后都要重新输一轮密码。这不是用户做错了什么，
/// 是签名方式决定的，点多少次「始终允许」都不管用。
///
/// 放开之后，同一用户下的任何进程都能静默读到 token。这仍然满足本类要解决的问题
/// ——token 不躺在会被备份、同步、随手打开的明文文件里，且钥匙串锁上时是加密的——
/// 安全性大致等同一个 0600 的文件。真正的根治是用稳定身份（Developer ID）签名，
/// 那样 DR 变成 identifier + team，跨版本不变，但那与当前的 ad-hoc 分发策略冲突。
public struct KeychainStore: Sendable {
    private let service: String

    /// 合并后那条条目的账号名。取一个不可能与 UUID 相撞的字面量，
    /// 好让它和迁移前遗留的按 UUID 命名的旧条目共存于同一个 service 下。
    private nonisolated static let blobAccount = "subscription-urls"

    public nonisolated init(service: String = "com.liuyude.RouteBar.subscriptions") {
        self.service = service
    }

    public nonisolated func value(for id: UUID) -> String? {
        if let url = loadAll()[id.uuidString] { return url }
        // 合并条目里没有，可能是升级前写下的旧条目。旧条目的 ACL 仍绑在某个历史版本的
        // 签名上，读它会弹一次授权——这是升级后的最后一轮，迁过来之后不会再弹。
        return migrateLegacyItems()[id.uuidString]
    }

    public nonisolated func set(_ value: String, for id: UUID) throws {
        var all = loadAll()
        all[id.uuidString] = value
        try saveAll(all)
        // 同一条订阅的旧条目留着只会是一份读不到也删不掉的过期 token。
        removeLegacyItem(id)
    }

    public nonisolated func remove(_ id: UUID) {
        var all = loadAll()
        if all.removeValue(forKey: id.uuidString) != nil {
            try? saveAll(all)
        }
        removeLegacyItem(id)
    }

    // MARK: - 合并条目的读写

    private nonisolated func loadAll() -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.blobAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    /// 先 update 后 add：条目已存在时走 update，而不是从前那样先删后加——删除本身也要
    /// 一次授权，等于把好不容易省掉的对话框又请回来。
    ///
    /// 两条路径都要带上 access：**写入会把 ACL 重置成「只信任写它的那个程序」**
    /// （实测：用 `security -A` 建的开放条目，被另一个二进制 update 一次之后，
    /// 别的程序再读就开始弹框了）。所以放开这件事必须每次写都重新声明一遍，
    /// 只在创建时做一次是不够的。
    private nonisolated func saveAll(_ map: [String: String]) throws {
        let data = try JSONEncoder().encode(map)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.blobAccount,
        ]
        var attributes: [String: Any] = [kSecValueData as String: data]
        // 拿不到 access 就退化成默认 ACL：条目照样写得进去，只是往后会弹授权。
        // 为了少一个对话框而让用户的订阅地址存不下来，是本末倒置。
        if let access = unrestrictedAccess() {
            attributes[kSecAttrAccess as String] = access
        }

        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.status(updateStatus) }

        var item = base.merging(attributes) { current, _ in current }
        item[kSecAttrLabel as String] = "RouteBar 订阅地址"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    /// 造一个「受信任程序列表为空」的访问对象——ACL 的应用列表传 NULL 表示所有程序都受信任，
    /// 也就是 `security add-generic-password -A` 的效果。
    ///
    /// `SecAccessCreate` 建出来的 access 带三张 ACL（解密、加密、其余操作），
    /// 三张都要放开：只放开解密的话，删除与改 ACL 仍会弹框。
    ///
    /// 这几个 API 自 10.10 起标记为废弃，替代品是数据保护钥匙串，而它在 macOS 上要求
    /// 签名带 `keychain-access-groups` 权限——ad-hoc 签名给不出这个权限，这条路走不通。
    /// 函数自身标为 deprecated 是为了让编译器闭嘴，不是说它将被移除。
    @available(macOS, deprecated: 10.10, message: "SecAccess 系 API 已废弃，但数据保护钥匙串对 ad-hoc 签名不可用")
    private nonisolated func unrestrictedAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("RouteBar 订阅地址" as CFString, nil, &access) == errSecSuccess,
              let access else { return nil }

        var aclList: CFArray?
        guard SecAccessCopyACLList(access, &aclList) == errSecSuccess,
              let acls = aclList as? [SecACL] else { return nil }

        for acl in acls {
            var applications: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &applications, &description, &prompt) == errSecSuccess else { continue }
            // 应用列表传 nil = 所有程序都受信任；同时清掉 prompt 位，
            // 否则「需要密码」那一位仍会让系统在访问时要一次密码。
            guard SecACLSetContents(acl, nil, description ?? "" as CFString,
                                    SecKeychainPromptSelector()) == errSecSuccess else { return nil }
        }
        return access
    }

    // MARK: - 旧条目迁移

    /// 1.16.0 及以前：一条订阅一条条目，账号名是订阅 UUID。
    private nonisolated func legacyQuery(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    /// 一次把该 service 下所有旧条目全迁过来，而不是「读到哪条迁哪条」。
    ///
    /// 逐条迁的话，一条订阅要等到它自己到期被读时才迁——暂停的、停用的订阅可能几天后
    /// 才轮到，于是用户以为已经消停的授权框过阵子又冒出来一个。宁可在升级后的第一次
    /// 更新里把 N 个框一次弹完，也好过拖成几天里零星弹 N 次。
    private nonisolated func migrateLegacyItems() -> [String: String] {
        // 分两步：先列账号名，再逐条读值。老式钥匙串不接受 `MatchLimitAll` 与
        // `ReturnData` 同时出现（返回 errSecParam），一次批量把值全取回来是做不到的。
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        var all = loadAll()
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return all }

        var migrated: [UUID] = []
        for item in items {
            // 账号名是 UUID 的才是旧条目；合并条目自己的账号名不是 UUID，会在这里被跳过。
            guard let account = item[kSecAttrAccount as String] as? String,
                  let id = UUID(uuidString: account),
                  let url = legacyValue(id) else { continue }
            all[account] = url
            migrated.append(id)
        }
        guard !migrated.isEmpty else { return all }
        // 写不进去就先把值给调用方用着，下次再迁；这时删掉旧条目会把订阅地址弄丢。
        guard (try? saveAll(all)) != nil else { return all }
        for id in migrated { removeLegacyItem(id) }
        return all
    }

    private nonisolated func legacyValue(_ id: UUID) -> String? {
        var query = legacyQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 条目不存在时 `SecItemDelete` 直接返回 `errSecItemNotFound`，不会弹框，
    /// 所以无条件调用是安全的，不必先查一次存在与否。
    private nonisolated func removeLegacyItem(_ id: UUID) {
        SecItemDelete(legacyQuery(id) as CFDictionary)
    }

    public enum KeychainError: LocalizedError {
        case status(OSStatus)
        public var errorDescription: String? {
            switch self { case .status(let status): "钥匙串操作失败（\(status)）" }
        }
    }
}
