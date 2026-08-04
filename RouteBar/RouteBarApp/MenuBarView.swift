import SwiftUI

/// 菜单栏面板。
///
/// 原来是 `.menuBarExtraStyle(.menu)` 的一长条系统菜单：十来个条目平铺，状态信息只能
/// 塞成不可点的灰色文字，看一眼服务状态要先读三行字。改成 `.window` 之后，
/// 上半部分是状态卡片，下半部分才是操作，和主窗口概览页读的是同一份 `AppViewState`。
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if !model.healthMessages.isEmpty {
                healthList
                Divider()
            }

            serviceControls
            Divider()

            row("更新全部订阅", symbol: "arrow.clockwise", disabled: model.isUpdating) {
                Task { await model.updateAll() }
            }
            row(model.autoUpdatePaused ? "恢复自动更新" : "暂停自动更新",
                symbol: model.autoUpdatePaused ? "play.circle" : "pause.circle") {
                model.toggleAutoUpdate()
            }

            Divider()

            row("打开 RouteBar", symbol: "macwindow") { open(.overview) }
            if model.settings.surgeOutputMode.servesSubscription {
                row("打开 Web 界面", symbol: "safari") { model.openWebInterface() }
            }
            row("查看错误日志", symbol: "doc.text") { open(.service) }
            row("退出 RouteBar", symbol: "power") { NSApplication.shared.terminate(nil) }
        }
        .frame(width: 320)
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.overall.symbol)
                .font(.title)
                .foregroundStyle(model.overall.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.overall.label).font(.headline)
                Text(model.menuBarSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                versionBadge
                if model.isUpdating { ProgressView().controlSize(.small) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 版本号 + Debug 标记。
    ///
    /// 开发副本和已安装版本图标一模一样，两份同时跑着的时候，光看界面认不出眼前这个
    /// 菜单栏图标属于哪一份——「改了没生效」和「压根没在跑那一份」就分不开。
    /// 版本号相同也照样分得清，因为 Debug 构建带标记；连构建类型都一样时，
    /// 悬停看 tooltip 里的 bundle 路径。
    private var versionBadge: some View {
        HStack(spacing: 5) {
            if AppVersion.isDevelopmentBuild {
                Text("DEBUG")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(.orange, in: Capsule())
            }
            Text(verbatim: "v\(AppVersion.current)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(Bundle.main.bundlePath)
    }

    /// 待处理项直接列在面板里——这是用户点开菜单栏最可能想知道的事。
    private var healthList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("待处理")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            ForEach(model.healthMessages.prefix(3), id: \.self) { message in
                Button {
                    open(.overview)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if model.healthMessages.count > 3 {
                Text("另有 \(model.healthMessages.count - 3) 项…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .padding(.bottom, 4)
    }

    private var serviceControls: some View {
        Group {
            if model.serviceState.isRunning {
                row("停止 sing-box", symbol: "stop.fill") { model.stopService() }
            } else {
                row("启动 sing-box", symbol: "play.fill") { model.restartService() }
            }
            row("刷新状态", symbol: "checklist") { model.refreshService() }
        }
    }

    private func row(_ title: String, symbol: String, disabled: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func open(_ section: AppSection) {
        model.selectedSection = section
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
