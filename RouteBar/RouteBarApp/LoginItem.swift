import Foundation
import ServiceManagement

/// 登录自启。
///
/// 注意：实际生效需应用以 .app bundle 形式签名运行；从 Xcode 直接跑时注册可能失败，属预期。
enum LoginItem {
    /// 登录项的真实状态。
    ///
    /// `register()` 成功返回并不代表自启已生效：用户若曾在「系统设置 → 通用 → 登录项」
    /// 里关掉过本应用，注册不会抛错，但状态停在 `.requiresApproval`，必须由用户回到
    /// 系统设置批准。所以调用方必须看 `state`，不能只看有没有抛错。
    enum State: Sendable, Equatable {
        case enabled
        case requiresApproval
        case disabled
        case failed(String)

        /// 开关应显示的位置。`requiresApproval` 视为「开」——注册确实生效了，
        /// 只是还缺用户批准，此时要配合提示引导，而不是把开关弹回去。
        var isOn: Bool {
            switch self {
            case .enabled, .requiresApproval: true
            case .disabled, .failed: false
            }
        }
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered, .notFound: .disabled
        @unknown default: .disabled
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> State {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return .failed(error.localizedDescription)
        }
        return state
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
