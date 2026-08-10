import os
import Foundation

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let output: String

    public nonisolated init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }

    public nonisolated var succeeded: Bool { exitCode == 0 }
}

public enum CommandError: LocalizedError {
    case launchFailed(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason): "启动命令失败：\(reason)"
        case .timedOut(let path): "命令执行超时：\(path)"
        }
    }
}

/// 受控命令执行器。
///
/// 安全约束：
/// - 参数以数组传递，**不经 Shell 拼接**——订阅名、节点名都可能含引号和分号。
/// - 有执行超时；超时先 SIGTERM，宽限后 SIGKILL，避免 `waitUntilExit` 永久挂住调用方。
/// - 合并 stdout/stderr 并在后台线程排空管道，防止子进程写满缓冲区后死锁。
///
/// 这里不做可执行文件白名单：RouteBar 要调的 sing-box 路径本身就是用户设置项
/// （Homebrew 前缀因机器而异），白名单挡不住任何东西，只会挡住合法配置。
/// 真正的边界是「只在明确的几处调用点使用」，见 `RuntimeManager`。
public struct CommandRunner: Sendable {
    public var timeoutSeconds: TimeInterval
    /// 要额外塞进子进程环境的变量。nil 表示原样继承。
    ///
    /// 只做**增量**而不是整份替换：替换掉的话 PATH、HOME 都得自己补齐，
    /// 而 brew 这类工具少一个就会以匪夷所思的方式失败。
    public var extraEnvironment: [String: String]?

    public nonisolated init(timeoutSeconds: TimeInterval = 20,
                            extraEnvironment: [String: String]? = nil) {
        self.timeoutSeconds = timeoutSeconds
        self.extraEnvironment = extraEnvironment
    }

    /// 子进程与管道读取全部放到后台任务，调用方 actor 在等待期间可以继续处理其他消息。
    ///
    /// `onLine` 按行实时回调，用于「这条命令还活着，而且正在干这个」。跑得久的命令
    /// （`brew install` 冷启动能到十几分钟）只在结束时给出全部输出的话，界面上
    /// 就是一个转不完的圈——用户无从判断是在下载还是已经挂死。
    /// 回调发生在后台线程，调用方自己负责跳回需要的执行域。
    public nonisolated func run(_ executable: String,
                                _ arguments: [String],
                                onLine: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        let timeoutSeconds = timeoutSeconds
        let extraEnvironment = extraEnvironment
        return try await Task.detached(priority: .userInitiated) {
            try Self.runSynchronously(executable, arguments,
                                      timeoutSeconds: timeoutSeconds,
                                      extraEnvironment: extraEnvironment,
                                      onLine: onLine)
        }.value
    }

    private nonisolated static func runSynchronously(
        _ executable: String,
        _ arguments: [String],
        timeoutSeconds: TimeInterval,
        extraEnvironment: [String: String]?,
        onLine: (@Sendable (String) -> Void)?
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let extraEnvironment {
            process.environment = ProcessInfo.processInfo.environment.merging(extraEnvironment) { _, new in new }
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // stdin 接空设备，绝不继承。
        //
        // RouteBar 是图形程序，子进程没有终端可用；而 brew 这类工具在某些情况下会
        // 停下来征询确认（不受信任的 tap、`--ask`）。继承下来的 stdin 上永远不会有人
        // 回答，进程就那么挂着，用户看到的是「卡在第一步十几分钟」，直到超时才收场。
        // 接 /dev/null 的话它立刻读到 EOF，走默认分支——失败也比无限期沉默好。
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            CoreLog.command.error("启动失败 \(executable, privacy: .public)：\(error.localizedDescription, privacy: .public)")
            throw CommandError.launchFailed(error.localizedDescription)
        }

        let timedOut = AtomicFlag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)

        // 必须在 waitUntilExit 之前开始读：输出超过管道缓冲区时子进程会阻塞在写上，
        // 而我们阻塞在等它退出，双方互等。
        let box = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = pipe.fileHandleForReading
            var pending = Data()
            while true {
                let chunk = handle.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { break }
                box.append(chunk)
                guard let onLine else { continue }
                // 按行切分再回调：管道给的是任意大小的字节块，一行可能被劈成两块，
                // 直接把块当行发出去，界面上会看到半截句子。
                pending.append(chunk)
                // brew 的进度条用 \r 回到行首重画，不带 \n——只按 \n 切的话，
                // 整个下载过程会被攒成一行，最后一次性冒出来，等于没有进度。
                while let separator = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let line = String(decoding: pending[..<separator], as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                    pending.removeSubrange(...separator)
                    if !line.isEmpty { onLine(line) }
                }
            }
            if let onLine {
                let tail = String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { onLine(tail) }
            }
            group.leave()
        }

        process.waitUntilExit()
        group.wait()
        watchdog.cancel()

        if timedOut.value {
            CoreLog.command.error("执行超时 \(executable, privacy: .public)")
            throw CommandError.timedOut(executable)
        }

        let output = String(decoding: box.value, as: UTF8.self)
        CoreLog.command.debug("\(executable, privacy: .public) 退出码 \(process.terminationStatus)")
        return CommandResult(exitCode: process.terminationStatus, output: output)
    }
}

// MARK: - 线程安全小工具

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var storage = Data()

    nonisolated init() {}

    nonisolated var value: Data {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    nonisolated func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        storage.append(data)
    }
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var flag = false

    nonisolated init() {}

    nonisolated var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    nonisolated func set() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }
}
