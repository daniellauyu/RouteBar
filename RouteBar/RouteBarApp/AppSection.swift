import SwiftUI

/// 侧栏分组。
///
/// 原来的侧栏是六个平铺的自绘按钮，「仪表盘 / 订阅管理 / 节点管理 / 服务管理 / 日志 / 设置」
/// 权重相同、没有层次，用户得逐个读过去才知道哪个是自己要的。按「看什么 / 管什么 / 配什么」
/// 分成四组之后，日常只在前两组里活动，后两组是偶尔才去一次的地方。
enum SidebarGroup: String, CaseIterable, Identifiable {
    case status = "状态"
    case content = "订阅与节点"
    case runtime = "运行"
    case advanced = "高级"

    var id: String { rawValue }

    var sections: [AppSection] {
        switch self {
        case .status: [.overview, .setup]
        case .content: [.subscriptions, .nodes]
        case .runtime: [.service, .logs]
        case .advanced: [.settings, .environment, .about]
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "概览"
    /// 分步引导。常驻侧栏而不是只在概览页顶部露一次：引导本身会把用户支使到订阅页、
    /// 环境页去做事，跳走之后得有一条回来的路；路径失效（Homebrew 升级、Surge 换配置名）
    /// 时步骤会重新变红，那时用户是「出问题了」的心态，不会想到去概览页找它。
    case setup = "开始"
    case subscriptions = "订阅"
    case nodes = "节点"
    case service = "服务"
    case logs = "日志"
    case settings = "通用"
    case environment = "环境"
    case about = "关于"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .setup: "play.circle"
        case .subscriptions: "square.3.layers.3d"
        case .nodes: "point.3.connected.trianglepath.dotted"
        case .service: "bolt.horizontal.circle"
        case .logs: "doc.text.magnifyingglass"
        case .settings: "gearshape"
        case .environment: "wrench.and.screwdriver"
        case .about: "info.circle"
        }
    }

    /// 是否为「列表 + 详情」页。
    ///
    /// 只有订阅和节点页有选中态；切到别的页要把选中清掉，否则回来时详情栏还停在
    /// 一个用户早就忘了自己选过的条目上。
    var hasSelection: Bool {
        switch self {
        case .subscriptions, .nodes: true
        default: false
        }
    }
}
