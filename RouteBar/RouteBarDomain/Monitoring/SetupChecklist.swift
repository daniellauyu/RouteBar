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
    /// 自己动手时要敲的那一行。RouteBar 现在也能代劳（见 `SetupAutomation`），
    /// 但命令仍然给出来——愿意自己控制装什么版本的人不该被逼着走自动流程。
    public nonisolated static let installCommand = "brew install sing-box"

    /// 两条自动路径都走不通时的手工出路。
    ///
    /// 「没有 Homebrew，而且到不了 GitHub」不是边缘情况，恰恰是这个应用最典型的处境：
    /// 用户装它就是因为直连不通，而配好之前一个可用出口都没有——鸡生蛋。这时给一句
    /// 「安装失败」等于把人扔在死路上，所以这里给的是能照着敲完的完整步骤。
    ///
    /// 不推荐拷到 `/usr/local/bin`：那要 sudo，而这一步本来不需要管理员权限。
    /// 放进 RouteBar 自己的目录则有个额外好处——卸载时那一份会跟着一起删掉。
    public nonisolated static let manualInstallGuide = """
        没有 Homebrew、又到不了 GitHub 时，从另一台已经装好的 Mac 上拷一份过来最省事：

        1. 在那台机器上跑 which sing-box 找到它，通常是 /opt/homebrew/bin/sing-box
        2. 用 AirDrop、U 盘或 scp 把这个文件传到这台机器
        3. 在这台机器上安置好并给权限：
             mkdir -p ~/Library/Application\\ Support/RouteBar/bin
             mv ~/Downloads/sing-box ~/Library/Application\\ Support/RouteBar/bin/
             chmod +x ~/Library/Application\\ Support/RouteBar/bin/sing-box
             xattr -dr com.apple.quarantine ~/Library/Application\\ Support/RouteBar/bin/sing-box
        4. 回到「环境」页，把「sing-box 可执行文件」改成上面这个路径并保存

        第 4 步不能用「重新检测」代替：那颗按钮只认 Homebrew 与系统的几个固定前缀，
        找不到这个位置的文件，必须手工填一次。

        两台机器的芯片要一致——Apple 芯片上拷来的二进制在 Intel Mac 上跑不了，反之亦然。
        """

    public let steps: [SetupStep]

    /// 全部**必需**步骤都完成了。可选项（开机自启）不计入。
    public nonisolated var isComplete: Bool {
        !steps.contains { !$0.isDone && !$0.isOptional }
    }

    /// 「一键完成」会替用户做掉的步骤，按依赖顺序，已完成的不在其中。
    public nonisolated var automatableSteps: [SetupStep] {
        steps.filter { !$0.isDone && $0.automation == .automatic }
    }

    /// 一键跑完之后仍然只能用户自己做的那几步。
    ///
    /// 单独列出来是因为它决定了一键按钮该怎么收尾：全是自动项时可以直接说「配好了」，
    /// 剩了手动项就必须点名说清楚还差什么，否则用户看到进度跑完却没能用，只会以为是坏的。
    public nonisolated var manualSteps: [SetupStep] {
        steps.filter { !$0.isDone && $0.automation != .automatic }
    }

    /// 还有值得跑一次的自动步骤。全绿时按钮该灰掉，而不是让人点了什么都不发生。
    public nonisolated var canAutomate: Bool { !automatableSteps.isEmpty }

    /// 下一件该做的事：第一个未完成的必需步骤。全做完了再看可选项。
    public nonisolated var nextStep: SetupStep? {
        steps.first { !$0.isDone && !$0.isOptional } ?? steps.first { !$0.isDone }
    }

    public nonisolated var remainingRequiredCount: Int {
        steps.filter { !$0.isDone && !$0.isOptional }.count
    }

    public nonisolated init(environment: RouteBarEnvironmentReport,
                            subscriptionCount: Int,
                            subscriptionServing: Bool,
                            subscriptionURL: String,
                            serviceRunning: Bool,
                            launchesAtLogin: Bool) {
        var steps: [SetupStep] = []

        // 1. 排第一是因为没有二进制后面每一步都没意义：plist 会指向一个不存在的可执行文件，
        //    服务起不来，配置也无从校验。
        steps.append(SetupStep(
            kind: .singBox,
            title: "安装 sing-box",
            done: "已找到 sing-box 可执行文件。",
            todo: "RouteBar 不自带 sing-box，但可以替你装：机器上有 Homebrew 就走 "
                + "\(Self.installCommand)，没有就直接下载官方发布的二进制，放进 RouteBar 自己的目录。"
                + "也可以自己装好后点「重新检测」，或在「环境」页手工指定路径。"
                + "两条自动路径都不通时（没有 Homebrew 又到不了 GitHub），点「立即安装」，"
                + "失败信息里会给出从另一台机器拷一份过来的完整步骤。",
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
            isDone: subscriptionCount > 0,
            // 机场地址带着你的付费凭据，RouteBar 无处可猜也不该去猜——这是整条流水线上
            // 唯一必须由人提供的输入。
            automation: .manual("订阅地址只有你有，从机场后台复制过来粘一次即可。")))

        // 5. 最后一公里：端口已经在本机开好了，这一步只是把一份现成的清单摆出来。
        //
        //    这一步的「完成」判的是本地服务在不在监听——那是 RouteBar 自己起的，用户没做
        //    任何事。所以光说「已在监听」等于什么都没交代：他要做的是把下面这个地址复制走。
        //    地址就是这一步的产出，跟着步骤一起给出来，不必再跳去服务页找。
        steps.append(SetupStep(
            kind: .output,
            title: "把订阅地址交给客户端",
            done: "本地订阅服务已在监听。复制下面这个地址，填进 Surge 策略组的 policy-path 即可；"
                + "用别的客户端则不需要它——每个启用节点都有一个本机端口，直接当 SOCKS5/HTTP 代理填。",
            todo: "本地订阅服务还没起来，地址暂时给不出来（通常是端口被占用，见「服务」页）。"
                + "用别的客户端的话不必等它——每个启用节点都有一个本机端口，直接填进去就能用。",
            isDone: subscriptionServing,
            handout: subscriptionServing ? subscriptionURL : nil))

        steps.append(SetupStep(
            kind: .service,
            title: "启动 sing-box",
            done: "sing-box 正在运行。",
            todo: "前面几步就位后，启动服务即可。没有启用节点时配置为空，先添加订阅。",
            isDone: serviceRunning))

        // 标着可选，实际上接近必需：订阅地址由 RouteBar 自己提供，它没运行时那个端口是
        // 关的，客户端只能吃上一次拉到的缓存。sing-box 由 launchd 托管，不受影响。
        steps.append(SetupStep(
            kind: .autoLaunch,
            title: "开机自动启动 RouteBar",
            done: "已设为登录时启动。",
            todo: "订阅地址由 RouteBar 提供，它没运行时客户端就拉不到新节点（旧的仍可用），"
                + "自动更新订阅也只在它运行时进行。建议打开。",
            isDone: launchesAtLogin,
            isOptional: true))

        self.steps = steps
    }
}

/// 这一步 RouteBar 能不能自己做完。
///
/// 判定放在步骤定义里而不是「一键」那段执行代码里：执行器只负责按顺序调动词，
/// 「哪些能代劳」是清单本身的性质，两边各写一份的话，加了新步骤必然漏掉一处。
public enum SetupAutomation: Sendable, Equatable {
    /// 一键流程会做掉。
    case automatic
    /// 只能用户自己做，附上一句为什么——光说「不能自动」等于把问题原样退回去。
    case manual(String)

    public nonisolated static func == (lhs: SetupAutomation, rhs: SetupAutomation) -> Bool {
        switch (lhs, rhs) {
        case (.automatic, .automatic): true
        case (.manual(let lhsReason), .manual(let rhsReason)): lhsReason == rhsReason
        default: false
        }
    }
}

public struct SetupStep: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case singBox, directories, launchAgent, subscription, output, service, autoLaunch
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
    /// 「一键完成」拿这个字段决定跳过还是动手。
    public let automation: SetupAutomation
    /// 这一步要用户拿走的那串文本：待执行的命令，或做完之后产出的地址。
    ///
    /// 有些步骤的产出本身就是全部意义（订阅地址那一步尤其如此——服务是 RouteBar 自己起的，
    /// 用户什么都没做它就绿了，真正要做的是把地址复制走）。让视图各自去别处凑这串文本，
    /// 就会出现「步骤说完成了，但完成的是什么、东西在哪」没人回答的局面。
    public let handout: String?

    public nonisolated var id: String { kind.rawValue }
    public nonisolated var detail: String { isDone ? done : todo }

    /// 未完成、且只能用户自己动手时的那句解释。
    public nonisolated var manualReason: String? {
        guard !isDone, case .manual(let reason) = automation else { return nil }
        return reason
    }

    public nonisolated init(kind: Kind, title: String, done: String, todo: String,
                            isDone: Bool, isOptional: Bool = false,
                            automation: SetupAutomation = .automatic, handout: String? = nil) {
        self.kind = kind
        self.title = title
        self.done = done
        self.todo = todo
        self.isDone = isDone
        self.isOptional = isOptional
        self.automation = automation
        self.handout = handout
    }
}
