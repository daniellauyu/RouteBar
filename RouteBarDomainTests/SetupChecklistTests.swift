import Foundation
import Testing
@testable import RouteBarDomain

@Suite struct SetupChecklistTests {
    private let paths = RuntimePaths(home: URL(fileURLWithPath: "/Users/tester"), userID: 501)

    /// 只有列出来的路径存在。用来精确摆出「装到一半」的各种局面。
    private func report(existing: Set<String>) -> RouteBarEnvironmentReport {
        RouteBarEnvironmentReport(paths: paths) { existing.contains($0.path) }
    }

    private func checklist(existing: Set<String> = [],
                           subscriptions: Int = 0,
                           mode: SurgeOutputMode = .subscription,
                           serving: Bool = false,
                           running: Bool = false,
                           login: Bool = false) -> SetupChecklist {
        SetupChecklist(environment: report(existing: existing),
                       subscriptionCount: subscriptions,
                       outputMode: mode,
                       subscriptionServing: serving,
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

    /// 两种输出方式的「Surge 那一步算不算做完」标准完全不同：
    /// 配置模式看托管配置在不在，订阅模式看本地服务有没有监听。
    @Test func surgeStepDependsOnTheOutputMode() {
        let everythingButSurge: Set<String> = [paths.singBoxBinary.path,
                                               paths.singBoxConfigDirectory.path,
                                               paths.launchAgent.path]

        let profile = checklist(existing: everythingButSurge, subscriptions: 1, mode: .profile, serving: true)
        #expect(profile.nextStep?.kind == .surge)          // 服务在监听也没用，配置模式看的是文件

        let withProfile = checklist(existing: everythingButSurge.union([paths.surgeProfile.path]),
                                    subscriptions: 1, mode: .profile)
        #expect(withProfile.nextStep?.kind == .service)

        let subscription = checklist(existing: everythingButSurge.union([paths.surgeProfile.path]),
                                     subscriptions: 1, mode: .subscription, serving: false)
        #expect(subscription.nextStep?.kind == .surge)     // 配置文件在也没用，订阅模式看的是端口
    }

    /// 开机自启是建议项：没开也算配置完成，但仍要出现在清单里。
    @Test func optionalStepDoesNotBlockCompletion() {
        let list = checklist(existing: [paths.singBoxBinary.path,
                                        paths.singBoxConfigDirectory.path,
                                        paths.launchAgent.path],
                             subscriptions: 1, mode: .subscription, serving: true, running: true, login: false)

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
                             subscriptions: 2, mode: .subscription, serving: true, running: true, login: true)

        #expect(list.isComplete)
        #expect(list.nextStep == nil)
        #expect(list.steps.allSatisfy { $0.isDone })
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
