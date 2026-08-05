import Foundation

/// 首次使用要做的事，按顺序排好。
///
/// 「环境」页给的是一份**平铺的体检报告**：五个红叉，每个都对，但看不出先做哪个、
/// 哪些 RouteBar 能代劳、哪些必须自己动手。对第一次打开这个应用的人来说，
/// 那等于把排查工作原样丢给了他。
///
/// 这里把同样的信息重排成有序步骤：每步只回答「现在轮到什么、为什么要它、怎么做完」。
/// 判定逻辑放在 Domain 而不是视图里——概览页、README 和将来任何入口都该用同一套顺序，
/// 各写一遍必然会漂移。
public struct SetupChecklist: Sendable, Equatable {
    /// 唯一一件 RouteBar 代劳不了的事，命令原样给出来让用户复制。
    public static let installCommand = "brew install sing-box"

    public let steps: [SetupStep]

    /// 全部**必需**步骤都完成了。可选项（开机自启）不计入。
    public nonisolated var isComplete: Bool {
        !steps.contains { !$0.isDone && !$0.isOptional }
    }

    /// 下一件该做的事：第一个未完成的必需步骤。全做完了再看可选项。
    public nonisolated var nextStep: SetupStep? {
        steps.first { !$0.isDone && !$0.isOptional } ?? steps.first { !$0.isDone }
    }

    public nonisolated var remainingRequiredCount: Int {
        steps.filter { !$0.isDone && !$0.isOptional }.count
    }

    public nonisolated init(environment: RouteBarEnvironmentReport,
                            subscriptionCount: Int,
                            outputMode: SurgeOutputMode,
                            subscriptionServing: Bool,
                            subscriptionURL: String,
                            serviceRunning: Bool,
                            launchesAtLogin: Bool) {
        var steps: [SetupStep] = []

        // 1. 唯一一件 RouteBar 代劳不了的事，所以排第一：没有二进制，后面每一步都没意义。
        steps.append(SetupStep(
            kind: .singBox,
            title: "安装 sing-box",
            done: "已找到 sing-box 可执行文件。",
            todo: "RouteBar 不自带 sing-box，需要你自己装一份。装好后点「重新检测」，"
                + "路径也可以在「环境」页手工指定。",
            isDone: environment.singBoxBinary == .ready,
            handout: environment.singBoxBinary == .ready ? nil : Self.installCommand))

        // 2. 目录必须先于 LaunchAgent：plist 指向的配置文件写不进去，服务会起不来。
        steps.append(SetupStep(
            kind: .directories,
            title: "创建配置目录",
            done: "sing-box 配置目录已就位。",
            todo: "RouteBar 要往这里写 sing-box 配置。点一下就建好，不影响已有文件。",
            isDone: environment.singBoxConfigDirectory == .ready))

        // 3. 有了它，sing-box 才会开机自启、崩溃自愈，且不依赖 RouteBar 是否在运行。
        steps.append(SetupStep(
            kind: .launchAgent,
            title: "安装 LaunchAgent",
            done: "sing-box 已交给 launchd 托管。",
            todo: "sing-box 由 launchd 拉起并保活——装好之后它开机自启，也不受 RouteBar 开关影响。"
                + "RouteBar 会按「环境」页的路径生成 plist 并立即加载。",
            isDone: environment.launchAgent == .ready))

        steps.append(SetupStep(
            kind: .subscription,
            title: "添加订阅",
            done: "已有 \(subscriptionCount) 个订阅。",
            todo: "粘贴机场的订阅地址。地址只存进钥匙串，不写入任何配置文件。"
                + "目前只解析 VLESS Reality 节点，其它协议会被跳过。",
            isDone: subscriptionCount > 0))

        // 5. 最后一公里：节点已经在本机跑起来了，但 Surge 还不知道它们在哪。
        //    两种输出方式的「做完」标准完全不同，不能合并成一句话。
        switch outputMode {
        case .profile:
            steps.append(SetupStep(
                kind: .surge,
                title: "准备 Surge 配置",
                done: "已找到托管的 Surge 配置。",
                todo: "在 Surge 里新建一份配置，只要含 [Proxy] 和 [Proxy Group] 两个段即可，"
                    + "然后在「环境」页把路径指向它。RouteBar 只改写 [Proxy] 段和「sing-box 节点」策略组，"
                    + "规则与其它策略组原样保留。",
                isDone: environment.surgeProfile == .ready))
        case .subscription, .both:
            // 这一步的「完成」判的是本地服务在不在监听——那是 RouteBar 自己起的，用户没做任何事。
            // 所以光说「已在监听」等于什么都没交代：他要做的是把下面这个地址复制走。
            // 地址就是这一步的产出，跟着步骤一起给出来，不必再跳去服务页找。
            steps.append(SetupStep(
                kind: .surge,
                title: "把订阅地址交给客户端",
                done: "本地订阅服务已在监听。复制下面这个地址，填进 Surge 策略组的 policy-path 即可；"
                    + "用别的客户端则不需要它——每个启用节点都有一个本机端口，直接当 SOCKS5/HTTP 代理填。",
                todo: "本地订阅服务还没起来，地址暂时给不出来（通常是端口被占用，见「服务」页）。"
                    + "用别的客户端的话不必等它——每个启用节点都有一个本机端口，直接填进去就能用。",
                isDone: subscriptionServing,
                handout: subscriptionServing ? subscriptionURL : nil))
        }

        steps.append(SetupStep(
            kind: .service,
            title: "启动 sing-box",
            done: "sing-box 正在运行。",
            todo: "前面几步就位后，启动服务即可。没有启用节点时配置为空，先添加订阅。",
            isDone: serviceRunning))

        // 可选，但对订阅输出方式几乎是必需的：RouteBar 没在运行时，
        // 本地订阅端口是关的，Surge 只能吃上一次拉到的缓存。
        steps.append(SetupStep(
            kind: .autoLaunch,
            title: "开机自动启动 RouteBar",
            done: "已设为登录时启动。",
            todo: outputMode.servesSubscription
                ? "订阅地址由 RouteBar 提供，它没运行时 Surge 就拉不到新节点（旧的仍可用）。建议打开。"
                : "自动更新订阅只在 RouteBar 运行时进行。建议打开。",
            isDone: launchesAtLogin,
            isOptional: true))

        self.steps = steps
    }
}

public struct SetupStep: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case singBox, directories, launchAgent, subscription, surge, service, autoLaunch
    }

    public let kind: Kind
    public let title: String
    /// 完成后的一句话说明。
    public let done: String
    /// 未完成时该怎么做。
    public let todo: String
    public let isDone: Bool
    /// 可选步骤不阻塞「配置完成」，但仍然会列出来。
    public let isOptional: Bool
    /// 这一步要用户拿走的那串文本：待执行的命令，或做完之后产出的地址。
    ///
    /// 有些步骤的产出本身就是全部意义（订阅地址那一步尤其如此——服务是 RouteBar 自己起的，
    /// 用户什么都没做它就绿了，真正要做的是把地址复制走）。让视图各自去别处凑这串文本，
    /// 就会出现「步骤说完成了，但完成的是什么、东西在哪」没人回答的局面。
    public let handout: String?

    public nonisolated var id: String { kind.rawValue }
    public nonisolated var detail: String { isDone ? done : todo }

    public nonisolated init(kind: Kind, title: String, done: String, todo: String,
                            isDone: Bool, isOptional: Bool = false, handout: String? = nil) {
        self.kind = kind
        self.title = title
        self.done = done
        self.todo = todo
        self.isDone = isDone
        self.isOptional = isOptional
        self.handout = handout
    }
}
