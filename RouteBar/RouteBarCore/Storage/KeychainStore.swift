import Foundation
import Security

/// 订阅地址的钥匙串存储，账号名用订阅的 UUID。
///
/// 订阅 URL 里带机场的鉴权 token，等价于账号密码，不能进 `state.json`
/// ——那份文件会被备份、被同步、被随手打开看。
public struct KeychainStore: Sendable {
    private let service: String

    public nonisolated init(service: String = "com.liuyude.RouteBar.subscriptions") {
        self.service = service
    }

    public nonisolated func value(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 先删后加而不是 `SecItemUpdate`：条目不存在时 update 会失败，
    /// 于是每个调用点都得先查一次存在与否，不如统一成幂等写入。
    public nonisolated func set(_ value: String, for id: UUID) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        // AfterFirstUnlock：登录项自启时钥匙串已解锁，自动更新才能拿到 URL。
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public nonisolated func remove(_ id: UUID) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ] as CFDictionary)
    }

    public enum KeychainError: LocalizedError {
        case status(OSStatus)
        public var errorDescription: String? {
            switch self { case .status(let status): "钥匙串操作失败（\(status)）" }
        }
    }
}
