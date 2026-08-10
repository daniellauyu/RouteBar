import SwiftUI

/// 菜单栏菜单。
///
/// 这里用系统菜单（`.menuBarExtraStyle(.menu)`）而不是自绘面板。曾经改成 `.window` 想把
/// 状态做成卡片，代价是整套菜单交互都得自己重写一遍：悬停高亮、按下反馈、禁用变灰、
/// 键盘导航、Esc 关闭、点开后拖到某一项松手即触发——少写一样就不像 macOS 的菜单。
/// 换回 `.menu` 之后这些全部由 AppKit 提供，代码里只剩「有哪些条目」这一件事。
///
/// 状态信息因此不能再画成卡片，改成菜单顶部的一组不可点条目（AppKit 渲染为灰字）。
/// 这是菜单栏应用展示状态的通行做法，信息量没少，只是从「读卡片」变成「读前几行」。
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // 顶部状态区：不可点，AppKit 自动渲染成灰字。
        Section(model.overall.label) {
            Text(model.menuBarSummary)
            Text(versionLine)
        }

        Divider()

        if !model.setupChecklist.isComplete {
            item(setupTitle, symbol: "list.bullet.clipboard") { open(.setup) }
            Divider()
        }

        if !model.healthMessages.isEmpty {
            Section("待处理") {
                // 菜单条目是单行的，长文案交给 AppKit 截断，不再自己折行。
                ForEach(model.healthMessages.prefix(3), id: \.self) { message in
                    item(message, symbol: "exclamationmark.triangle") { open(.overview) }
                }
                if model.healthMessages.count > 3 {
                    Text("另有 \(model.healthMessages.count - 3) 项…")
                }
            }
            Divider()
        }

        if model.serviceState.isRunning {
            item("停止 sing-box", symbol: "stop.fill") { model.stopService() }
        } else {
            item("启动 sing-box", symbol: "play.fill") { model.restartService() }
        }
        item("刷新状态", symbol: "checklist") { model.refreshService() }

        Divider()

        // 更新中不弹 ProgressView——菜单里放不下动画，改成条目本身变灰并说明在做什么。
        item(model.isUpdating ? "正在更新订阅…" : "更新全部订阅", symbol: "arrow.clockwise") {
            Task { await model.updateAll() }
        }
        .disabled(model.isUpdating)
        item(model.autoUpdatePaused ? "恢复自动更新" : "暂停自动更新",
             symbol: model.autoUpdatePaused ? "play.circle" : "pause.circle") {
            model.toggleAutoUpdate()
        }

        Divider()

        item("打开 RouteBar", symbol: "macwindow") { open(.overview) }
        item("打开 Web 界面", symbol: "safari") { model.openWebInterface() }
        item("查看错误日志", symbol: "doc.text") { open(.service) }

        Divider()

        item("退出 RouteBar", symbol: "power") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// 一条带图标的菜单项。
    ///
    /// 图标必须写成 `Button` 直接持有的 `Label`：`Image` 单独放、或者外面再裹一层
    /// `HStack`，AppKit 都只会取到文字，符号被丢掉。
    private func item(_ title: String, symbol: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
    }

    /// 版本号 + Debug 标记。
    ///
    /// 开发副本和已安装版本图标一模一样，两份同时跑着的时候，光看界面认不出眼前这个
    /// 菜单栏图标属于哪一份——「改了没生效」和「压根没在跑那一份」就分不开。
    /// 之前这里是个带 tooltip 的胶囊，菜单条目没有 tooltip，改成把标记直接写进文字。
    private var versionLine: String {
        let version = "版本 v\(AppVersion.current)"
        return AppVersion.isDevelopmentBuild ? "\(version)（DEBUG）" : version
    }

    /// 还没配完时的入口。
    ///
    /// 这时候「自检」全是红的、指标全是 0，但那些都是**结果**；用户要的是「还差几步、
    /// 下一步做什么」。菜单栏又是他最先碰到的地方——不放在这里，就得指望他自己想到
    /// 去开主窗口。配完之后整条消失。
    private var setupTitle: String {
        let checklist = model.setupChecklist
        let head = "还有 \(checklist.remainingRequiredCount) 步没配完"
        guard let next = checklist.nextStep else { return head }
        return "\(head)：\(next.title)"
    }

    private func open(_ section: AppSection) {
        model.selectedSection = section
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
