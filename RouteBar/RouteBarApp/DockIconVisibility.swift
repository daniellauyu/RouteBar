import AppKit

/// Dock 图标显隐。
///
/// 基线是 Info.plist 的 `LSUIElement = YES`：进程一出生就是 `.accessory`，需要显示图标时
/// 再运行时提升为 `.regular`。反过来做（以普通应用启动、启动后切 `.accessory`）会让图标
/// 先冒出来再消失，闪一下——图标已经由 LaunchServices 画出来了，代码再改也来不及。
///
/// 只靠 `LSUIElement` 又做不成设置项：它是静态的，改一次要重新打包。所以两者配合。
///
/// `.accessory` 下没有顶部应用菜单栏，也就没有 ⌘, 这条路。因此关掉图标后回到设置的通道是：
/// 菜单栏图标 →「打开 RouteBar」→ 侧栏「通用」。该页与 ⌘, 设置窗口共用同一视图。
enum DockIconVisibility {
    /// UserDefaults 键，与设置页的 `@AppStorage("hidesDockIcon")` 共用同一份存储。
    static let defaultsKey = "hidesDockIcon"

    static var isHidden: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// 套用激活策略。
    ///
    /// `activating` 为真时把应用带回前台，且与策略是否真的变化无关：切换策略会让应用
    /// 丢掉键盘焦点，窗口留在别的应用后面，看着就像「点了开关没反应」。
    @discardableResult
    static func apply(hidden: Bool, activating: Bool = true) -> Bool {
        let policy: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
        let applied = NSApp.activationPolicy() == policy || NSApp.setActivationPolicy(policy)
        if activating {
            NSApp.activate(ignoringOtherApps: true)
        }
        return applied
    }

    @discardableResult
    static func applyStoredPreference(activating: Bool = true) -> Bool {
        apply(hidden: isHidden, activating: activating)
    }
}
