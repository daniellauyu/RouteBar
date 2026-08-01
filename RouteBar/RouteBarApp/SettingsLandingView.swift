import AppKit
import SwiftUI

/// 通用设置。
///
/// ⌘, 设置窗口与侧栏「通用」页共用这一个视图——两套界面必然发散，而隐藏 Dock 图标后
/// 根本没有 ⌘, 这条路，侧栏那份才是唯一能用的入口。
struct SettingsLandingView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(DockIconVisibility.defaultsKey) private var hidesDockIcon = false
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage("defaultWindowSize") private var defaultWindowSizeRaw = DefaultWindowSize.small.rawValue
    @State private var loginItem = LoginItem.state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                settingsSection("自动更新") {
                    settingsRow(
                        title: "自动更新订阅",
                        detail: model.autoUpdatePaused
                            ? "已暂停。只有手动点「更新全部」才会拉取。"
                            : "按每条订阅各自的间隔更新。仅在 RouteBar 运行时生效，退出后不会后台更新。",
                        detailColor: model.autoUpdatePaused ? .orange : .secondary
                    ) {
                        Toggle("自动更新订阅", isOn: Binding(
                            get: { !model.autoUpdatePaused },
                            set: { _ in model.toggleAutoUpdate() }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    Divider()
                    settingsRow(
                        title: "下次更新",
                        detail: "更新间隔在「订阅」页选中订阅后点「编辑」逐条设置。"
                    ) {
                        Text(nextUpdateText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                settingsSection("启动") {
                    settingsRow(
                        title: "登录时自动启动 RouteBar",
                        detail: loginItemDetail,
                        detailColor: loginItemDetailColor
                    ) {
                        VStack(alignment: .trailing, spacing: 8) {
                            // 用真实状态驱动开关，而不是本地布尔：注册成功不等于自启已生效。
                            Toggle("登录时自动启动 RouteBar", isOn: Binding(
                                get: { loginItem.isOn },
                                set: { loginItem = LoginItem.setEnabled($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            if loginItem == .requiresApproval {
                                Button("打开登录项设置") { LoginItem.openSettings() }
                                    .controlSize(.small)
                            }
                        }
                    }
                    Divider()
                    settingsRow(
                        title: "隐藏 Dock 图标",
                        detail: hidesDockIcon
                            ? "已隐藏。点菜单栏图标 →「打开 RouteBar」可唤出主窗口。"
                            : "在 Dock 中显示 RouteBar 图标。隐藏后仍可从菜单栏访问全部功能。"
                    ) {
                        Toggle("隐藏 Dock 图标", isOn: $hidesDockIcon)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: hidesDockIcon) { _, newValue in
                                DockIconVisibility.apply(hidden: newValue)
                            }
                    }
                }

                settingsSection("外观") {
                    settingsRow(title: "主题", detail: "切换浅色 / 深色，或跟随系统设置。") {
                        Picker("主题", selection: $appearanceRaw) {
                            ForEach(AppAppearance.allCases) { option in
                                Label(option.rawValue, systemImage: option.symbol).tag(option.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    Divider()
                    settingsRow(title: "默认窗口尺寸", detail: "选择后立即调整当前窗口；也可把手动调好的尺寸设为默认。") {
                        VStack(alignment: .trailing, spacing: 8) {
                            Picker("默认窗口尺寸", selection: $defaultWindowSizeRaw) {
                                ForEach(DefaultWindowSize.allCases) { option in
                                    Text(option.rawValue).tag(option.rawValue)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                            HStack(spacing: 10) {
                                Text("当前尺寸：\(model.currentWindowDimensions.label)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("设为默认") { model.saveCurrentWindowAsDefault() }
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                settingsSection("数据") {
                    settingsRow(title: "订阅地址", detail: "存放在钥匙串，不写入任何配置文件。") {
                        Label("钥匙串", systemImage: "lock.fill").foregroundStyle(.green)
                    }
                    Divider()
                    settingsRow(title: "应用数据", detail: "订阅元数据、节点与生成副本。") {
                        Button("在访达中显示") { model.reveal(model.runtimePaths.appSupportDirectory) }
                            .controlSize(.small)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 用户可能在系统设置里改了登录项，回到窗口时重读，别让开关停在旧值上。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem = LoginItem.state
        }
    }

    private var nextUpdateText: String {
        guard !model.autoUpdatePaused else { return "已暂停" }
        guard let next = model.nextUpdateDate else { return "暂无计划" }
        return next.formatted(date: .abbreviated, time: .shortened)
    }

    private var loginItemDetail: String {
        switch loginItem {
        case .enabled, .disabled:
            "登录后自动运行，订阅按计划更新。"
        case .requiresApproval:
            "已注册，但需要你在「系统设置 → 通用 → 登录项」中批准后才会真正开机启动。"
        case .failed(let message):
            "无法设置登录项：\(message)（未打包直接运行时注册必然失败，属预期）"
        }
    }

    private var loginItemDetailColor: Color {
        switch loginItem {
        case .enabled, .disabled: .secondary
        case .requiresApproval, .failed: .orange
        }
    }
}
