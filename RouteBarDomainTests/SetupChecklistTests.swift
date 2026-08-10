import Foundation
import Testing
@testable import RouteBarDomain

@Suite struct SetupChecklistTests {
    private let paths = RuntimePaths(home: URL(fileURLWithPath: "/Users/tester"), userID: 501)

    /// 只有列出来的路径存在。用来精确摆出「装到一半」的各种局面。
    private func report(existing: Set<String>) -> RouteBarEnvironmentReport {
        RouteBarEnvironmentReport(paths: paths) { existing.contains($0.path) }
    }

    private static let subscriptionURL = "http://127.0.0.1:7788/tok/proxies"

    private func checklist(existing: Set<String> = [],
                           subscriptions: Int = 0,
                           serving: Bool = false,
                           running: Bool = false,
                           login: Bool = false) -> SetupChecklist {
        SetupChecklist(environment: report(existing: existing),
                       subscriptionCount: subscriptions,
                       subscriptionServing: serving,
                       subscriptionURL: Self.subscriptionURL,
                       serviceRunning: running,
                       launchesAtLogin: login)
    }

    /// 全新装机：第一件事必须是装 sing-box——它是唯一一件 RouteBar 代劳不了的，
    /// 没有它后面每一步都白做。
    @Test func freshInstallStartsAtSingBox() {
        let list = checklist()

        #expect(!list.isComplete)
        #expect(list.nextStep?.kind == .singBox)
        #expect(list.steps.first?.kind == .singBox)
    }

    /// 二进制就位后轮到目录，再轮到 LaunchAgent——目录必须先建，
    /// 否则 plist 指向的配置写不进去，服务起不来。
    @Test func stepsAdvanceInDependencyOrder() {
        let binary = checklist(existing: [paths.singBoxBinary.path])
        #expect(binary.nextStep?.kind == .directories)

        let directories = checklist(existing: [paths.singBoxBinary.path, paths.singBoxConfigDirectory.path])
        #expect(directories.nextStep?.kind == .launchAgent)

        let agent = checklist(existing: [paths.singBoxBinary.path,
                                         paths.singBoxConfigDirectory.path,
                                         paths.launchAgent.path])
        #expect(agent.nextStep?.kind == .subscription)
    }

    /// 开机自启是建议项：没开也算配置完成，但仍要出现在清单里。
    @Test func optionalStepDoesNotBlockCompletion() {
        let list = checklist(existing: [paths.singBoxBinary.path,
                                        paths.singBoxConfigDirectory.path,
                                        paths.launchAgent.path],
                             subscriptions: 1, serving: true, running: true, login: false)

        #expect(list.isComplete)
        #expect(list.remainingRequiredCount == 0)
        // 必需项做完之后，下一步指向唯一没做的可选项，而不是变成 nil。
        #expect(list.nextStep?.kind == .autoLaunch)
        #expect(list.steps.contains { $0.kind == .autoLaunch && $0.isOptional })
    }

    @Test func everythingDoneLeavesNothingToDo() {
        let list = checklist(existing: [paths.singBoxBinary.path,
                                        paths.singBoxConfigDirectory.path,
                                        paths.launchAgent.path],
                             subscriptions: 2, serving: true, running: true, login: true)

        #expect(list.isComplete)
        #expect(list.nextStep == nil)
        #expect(list.steps.allSatisfy { $0.isDone })
    }

    /// 每一步要交给用户的那串文本由清单本身给出，视图不必自己去别处凑。
    ///
    /// 订阅地址那一步尤其重要：它的「完成」判的是 RouteBar 自己起的本地服务在不在监听，
    /// 用户什么都没做它就绿了——真正要做的事就是把这个地址复制走，不给出来等于没这一步。
    @Test func stepsCarryTheTextTheUserHasToTakeAway() {
        let fresh = checklist()
        #expect(fresh.steps.first { $0.kind == .singBox }?.handout == SetupChecklist.installCommand)

        // 装好之后就不必再给命令了。
        let installed = checklist(existing: [paths.singBoxBinary.path])
        #expect(installed.steps.first { $0.kind == .singBox }?.handout == nil)

        let serving = checklist(serving: true)
        #expect(serving.steps.first { $0.kind == .output }?.handout == Self.subscriptionURL)

        // 服务没起来时地址是死的，给了只会让人白贴一次。
        let notServing = checklist(serving: false)
        #expect(notServing.steps.first { $0.kind == .output }?.handout == nil)

    }

    /// 「一键完成」的边界：订阅地址和 Surge 配置之外的每一步 RouteBar 都能自己做完。
    ///
    /// 这两项不是「暂时没做」而是原则上做不了——机场凭据只有用户有，Surge 只认自己
    /// 新建的配置文件。判定必须留在清单里，否则加了新步骤时执行器那边会漏掉一处。
    @Test func onlyTheUserSuppliedStepsStayManual() {
        let list = checklist()
        // 只剩订阅地址一项要用户自己给——其余每一步 RouteBar 都能做完。
        #expect(list.manualSteps.map(\.kind) == [.subscription])
        #expect(list.steps.first { $0.kind == .output }?.automation == .automatic)

        // 手动项得说清为什么，光标一个「不能自动」等于把问题原样退回去。
        #expect(list.manualSteps.allSatisfy { $0.manualReason?.isEmpty == false })
    }

    /// 一键只跑「还没做完」的自动步骤：已经绿了的重跑一遍，轻则白等，
    /// 重则把已经在跑的服务无谓地重启一次。
    @Test func automationSkipsWhatIsAlreadyDone() {
        let fresh = checklist()
        #expect(fresh.canAutomate)
        #expect(fresh.automatableSteps.map(\.kind) == [.singBox, .directories, .launchAgent, .output,
                                                       .service, .autoLaunch])

        let halfway = checklist(existing: [paths.singBoxBinary.path, paths.singBoxConfigDirectory.path])
        #expect(!halfway.automatableSteps.contains { $0.kind == .singBox || $0.kind == .directories })
    }

    /// 全绿之后按钮该灰掉，而不是让人点了什么都不发生。
    @Test func nothingLeftToAutomateWhenEverythingIsDone() {
        let done = checklist(existing: [paths.singBoxBinary.path,
                                        paths.singBoxConfigDirectory.path,
                                        paths.launchAgent.path],
                             subscriptions: 1, serving: true, running: true, login: true)

        #expect(!done.canAutomate)
        #expect(done.automatableSteps.isEmpty)
    }

    /// 未完成的步骤给的是「怎么做」，完成的给的是「已就位」——同一个字段两种用途，
    /// 视图不必自己判断该显示哪一句。
    @Test func detailSwitchesBetweenTodoAndDone() {
        let pending = checklist().steps.first { $0.kind == .singBox }
        let done = checklist(existing: [paths.singBoxBinary.path]).steps.first { $0.kind == .singBox }

        #expect(pending?.detail == pending?.todo)
        #expect(done?.detail == done?.done)
        #expect(pending?.detail != done?.detail)
    }
}
