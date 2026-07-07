import AppKit
import SwiftUI

@main
struct RouteBarApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @NSApplicationDelegateAdaptor(SnapshotDelegate.self) private var snapshotDelegate

    var body: some Scene {
        WindowGroup(id: "manager") {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(ProcessInfo.processInfo.environment["ROUTEBAR_SNAPSHOT"] == "1" ? .light : nil)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.appBecameActive() }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    model.appBecameActive()
                }
        }
        .defaultSize(width: 1380, height: 820)
        .commands { CommandGroup(replacing: .newItem) { } }

        MenuBarExtra("RouteBar", systemImage: menuIcon) {
            RouteBarMenu().environmentObject(model)
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuIcon: String {
        if case .running = model.serviceState { "point.3.connected.trianglepath.dotted" }
        else { "point.3.filled.connected.trianglepath.dotted" }
    }
}

#if DEBUG
final class SnapshotDelegate: NSObject, NSApplicationDelegate {
    private var snapshotWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["ROUTEBAR_SNAPSHOT"] == "1" else { return }
        NSApp.appearance = NSAppearance(named: .aqua)
        let controller = NSHostingController(rootView: ContentView().environmentObject(AppModel()).environment(\.colorScheme, .light))
        let snapshotWindow = NSWindow(contentViewController: controller)
        snapshotWindow.setContentSize(NSSize(width: 1380, height: 820))
        snapshotWindow.center()
        snapshotWindow.orderFrontRegardless()
        self.snapshotWindow = snapshotWindow
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let window = self.snapshotWindow else { return }
            window.orderFrontRegardless()
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            guard let view = window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/routebar-app.png"))
            NSApp.terminate(nil)
        }
    }
}
#endif

private struct RouteBarMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(serviceTitle)
        Text("\(model.subscriptions.count) 个订阅 · \(model.mergedNodes.count) 个节点")
        if let next = model.nextUpdateDate {
            Text("下次更新：\(next.formatted(date: .omitted, time: .shortened))")
        } else if model.autoUpdatePaused {
            Text("自动更新已暂停")
        }
        Divider()
        Button("更新全部", systemImage: "arrow.clockwise") { Task { await model.updateAll() } }
            .disabled(model.isUpdating)
        Button(model.autoUpdatePaused ? "恢复自动更新" : "暂停自动更新",
               systemImage: model.autoUpdatePaused ? "play.circle" : "pause.circle") {
            model.toggleAutoUpdate()
        }
        if case .running = model.serviceState {
            Button("停止 sing-box", systemImage: "stop.fill") { model.stopService() }
        } else {
            Button("启动 sing-box", systemImage: "play.fill") { model.restartService() }
        }
        Button("刷新状态", systemImage: "checklist") { model.refreshRuntimeArtifacts() }
        Divider()
        Button("打开错误日志", systemImage: "doc.text") { model.openRuntimePath(model.runtimePaths.singBoxErrorLog) }
        Button("定位配置文件", systemImage: "folder") { model.revealRuntimePath(model.runtimePaths.singBoxConfig) }
        Button("打开 RouteBar", systemImage: "macwindow") {
            openWindow(id: "manager")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("退出 RouteBar", systemImage: "power") { NSApp.terminate(nil) }
    }

    private var serviceTitle: String {
        switch model.serviceState { case .running: "sing-box 运行中"; case .stopped: "sing-box 已停止"; case .failed: "sing-box 状态异常" }
    }
}
