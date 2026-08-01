import AppKit
import SwiftUI

/// 只负责把 Dock 图标偏好落到激活策略上。
///
/// 进程按 `LSUIElement` 以 `.accessory` 起步（见 `DockIconVisibility`），所以这里做的是
/// 「需要图标时提升为 `.regular`」，隐藏模式下什么都不用改。
///
/// 放在 `applicationDidFinishLaunching` 而不是 SwiftUI 的 `.task`：后者要等窗口开始渲染才触发，
/// 显示模式下会看到图标姗姗来迟。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIconVisibility.applyStoredPreference()
    }

    /// 每次「重新打开」都要再套用一遍偏好，否则策略会被系统改回 Info.plist 里的样子。
    ///
    /// 应用已经在跑时又从 Spotlight / Finder / `open` 打开一次，LaunchServices 会按
    /// **Info.plist** 重新登记这个进程，运行时设过的策略被覆盖掉：显示模式下图标会凭空消失。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        DockIconVisibility.applyStoredPreference()
        return true
    }
}

@main
struct RouteBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var runtimeLog = RuntimeLog.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage("defaultWindowSize") private var defaultWindowSizeRaw = DefaultWindowSize.small.rawValue
    @AppStorage("customWindowWidth") private var customWindowWidth = 1_180.0
    @AppStorage("customWindowHeight") private var customWindowHeight = 760.0

    private var appearance: AppAppearance { AppAppearance.resolve(appearanceRaw) }
    private var defaultWindowDimensions: WindowDimensions {
        DefaultWindowSize.resolve(defaultWindowSizeRaw)
            .dimensions(custom: WindowDimensions(width: customWindowWidth, height: customWindowHeight))
    }

    var body: some Scene {
        // 用 Window 而不是 WindowGroup：RouteBar 管的是一份全局状态，开出两个一模一样的
        // 窗口只会让人分不清哪个是当前的。固定 id 也让菜单栏的「打开 RouteBar」有明确目标。
        Window("RouteBar", id: "main") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .environmentObject(model)
                .environmentObject(runtimeLog)
                .preferredColorScheme(appearance.colorScheme)
                .task { await model.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.appBecameActive() }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    // 睡眠期间订阅可能已到期，launchctl 状态也可能变了。
                    model.appBecameActive()
                }
                .background(DefaultWindowSizeApplier(dimensions: defaultWindowDimensions) {
                    model.updateWindowDimensions($0)
                })
                .alert("RouteBar", isPresented: Binding(
                    get: { model.alertMessage != nil },
                    set: { if !$0 { model.alertMessage = nil } }
                )) {
                    Button("好") { model.alertMessage = nil }
                } message: {
                    Text(model.alertMessage ?? "")
                }
        }
        .defaultSize(width: defaultWindowDimensions.width, height: defaultWindowDimensions.height)
        .commands { CommandGroup(replacing: .newItem) { } }

        Settings {
            // ⌘, 设置窗口与侧栏「通用」页共用同一视图，避免两套界面发散。
            SettingsLandingView()
                .frame(width: 560, height: 620)
                .environmentObject(model)
                .preferredColorScheme(appearance.colorScheme)
        }

        MenuBarExtra("RouteBar", systemImage: menuBarSymbol) {
            MenuBarView()
                .environmentObject(model)
                .preferredColorScheme(appearance.colorScheme)
        }
        .menuBarExtraStyle(.window)
    }

    /// 菜单栏图标按整体状态区分：菜单栏是单色的，只能靠形状差异传达状态，颜色在这里没用。
    private var menuBarSymbol: String {
        switch model.overall {
        case .running: "point.3.filled.connected.trianglepath.dotted"
        case .stopped: "point.3.connected.trianglepath.dotted"
        case .needsAttention, .failed: "exclamationmark.triangle.fill"
        }
    }
}
