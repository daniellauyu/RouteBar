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

    public nonisolated init(timeoutSeconds: TimeInterval = 20) {
        self.timeoutSeconds = timeoutSeconds
    }

    public nonisolated func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

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
            while true {
                let chunk = handle.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { break }
                box.append(chunk)
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
