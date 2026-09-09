import os
import Foundation
import Darwin

/// 替用户装一份 sing-box。
///
/// 两条路，按这个顺序试：
///
/// 1. **Homebrew**。机器上已经有 brew 就用它——装出来的东西归包管理器管，用户之后
///    `brew upgrade` 能一起升级，RouteBar 不必自己做版本维护。
/// 2. **官方发布件**。没有 brew（全新的 Mac 很常见），或者 brew 这一趟跑失败了，
///    就直接取 GitHub Release 的二进制放进 RouteBar 自己的目录。不需要管理员密码，
///    也不需要先装 Xcode 命令行工具。
///
/// 之所以不去自动装 Homebrew 本身：它的安装脚本要 sudo，会在图形界面之外弹出密码提示，
/// 而且会往 `/opt/homebrew` 铺一整套目录——那是用户该自己决定的事，不该由一个代理工具
/// 的「一键配置」顺手做掉。
public struct SingBoxInstaller: Sendable {
    /// 这一份是怎么来的。装完之后要如实告诉用户，否则他日后想升级都不知道该动哪儿。
    public enum Method: Sendable, Equatable {
        case homebrew(String)
        case download(URL)

        public nonisolated var label: String {
            switch self {
            case .homebrew: "Homebrew"
            case .download: "官方发布件"
            }
        }
    }

    public struct Outcome: Sendable, Equatable {
        public let binaryPath: String
        public let version: String
        public let method: Method
    }

    /// 一次进度汇报。
    ///
    /// 安装可能跑上十几分钟（brew 冷启动尤其），全程没有输出的话界面上就是一个转不完的
    /// 圈，用户无从判断是在下载还是已经挂死。所以每有动静就发一条。
    public struct Progress: Sendable {
        public let message: String
        /// 0…1。只有下载阶段给得出来——brew 不报总量，硬凑一个百分比只会是假的。
        public let fraction: Double?

        public nonisolated init(_ message: String, fraction: Double? = nil) {
            self.message = message
            self.fraction = fraction
        }
    }

    public typealias ProgressHandler = @Sendable (Progress) -> Void

    /// Homebrew 在 Apple Silicon 与 Intel 上的前缀不同，跟 sing-box 的探测同理。
    public nonisolated static let brewSearchPaths = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    /// brew 跑得慢的头号原因，也是这台机器最可能卡死的地方。
    ///
    /// `brew install` 默认先做一次 auto-update——那要从 GitHub 拉整个 formula 仓库。
    /// 而会走到「让 RouteBar 替我装」这条路的机器，恰恰常常是连 GitHub 都费劲的机器：
    /// 于是用户看到的是「卡在第一步十几分钟」，实际卡的根本不是 sing-box 的下载。
    /// 装一个已知的公式不需要更新索引，直接关掉。
    private nonisolated static let brewEnvironment = [
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1",
        // 提示文字对交互式终端有用，在这里只会把有效输出顶出视野。
        "HOMEBREW_NO_ENV_HINTS": "1",
    ]

    private let managedDirectory: URL
    private let progress: ProgressHandler

    public nonisolated init(managedDirectory: URL? = nil,
                            progress: @escaping ProgressHandler = { _ in }) {
        self.managedDirectory = managedDirectory
            ?? RuntimePaths().appSupportDirectory.appendingPathComponent("bin", isDirectory: true)
        self.progress = progress
    }

    private nonisolated func report(_ message: String, fraction: Double? = nil) {
        progress(Progress(message, fraction: fraction))
    }

    /// RouteBar 自己管的那份二进制的落点。
    public nonisolated var managedBinary: URL {
        managedDirectory.appendingPathComponent("sing-box")
    }

    // MARK: - 入口

    public nonisolated func install() async throws -> Outcome {
        if let brew = Self.brewPath() {
            report("找到 Homebrew（\(brew)），执行 brew install sing-box…")
            do {
                return try await installWithHomebrew(brew)
            } catch {
                // brew 失败的原因五花八门（没装命令行工具、源不通、tap 损坏），
                // 逐一识别没有意义：直接换第二条路，把原因记进日志备查即可。
                report("Homebrew 这一趟没成：\(error.localizedDescription)。改用官方发布件。")
            }
        } else {
            report("没有找到 Homebrew，直接取官方发布的二进制。")
        }
        return try await installFromRelease()
    }

    public nonisolated static func brewPath() -> String? {
        brewSearchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 已经装好的 sing-box 在哪。安装之后要用它确认「东西真的落地了」。
    public nonisolated static func probeInstalledBinary(extraPaths: [String] = []) -> String? {
        (extraPaths + RouteBarSettings.singBoxSearchPaths).first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    // MARK: - Homebrew

    private nonisolated func installWithHomebrew(_ brew: String) async throws -> Outcome {
        // 默认 20 秒对 brew 完全不够：它要解析依赖、下载 bottle，冷启动几分钟都可能。
        let runner = CommandRunner(timeoutSeconds: 900, extraEnvironment: Self.brewEnvironment)
        let progress = progress
        let result = try await runner.run(brew, ["install", "sing-box"]) { line in
            // brew 一行一行地报它在干什么（==> Fetching / ==> Pouring），原样转出去。
            // 噪声行（警告、提示）也一并转——在「卡住了吗」这个问题面前，
            // 任何一行新输出都比精心筛选后的沉默有用。
            progress(Progress(line))
        }
        guard result.succeeded else {
            throw InstallError.homebrewFailed(Self.tail(result.output))
        }
        // brew 说成功了不等于我们找得到它——自定义前缀、link 失败都会落到这一步。
        guard let path = Self.probeInstalledBinary() else {
            throw InstallError.homebrewFailed(
                "brew 报告安装成功，但 \(RouteBarSettings.singBoxSearchPaths.joined(separator: "、")) 里都没有 sing-box。"
                    + "可以跑 brew --prefix sing-box 看看它装到哪了，然后在「环境」页手工填路径。")
        }
        let version = try await Self.reportedVersion(of: path)
        CoreLog.configuration.notice("已通过 Homebrew 安装 sing-box：\(path, privacy: .public)")
        return Outcome(binaryPath: path, version: version, method: .homebrew(brew))
    }

    // MARK: - 官方发布件

    private nonisolated func installFromRelease() async throws -> Outcome {
        let tag = try await latestReleaseTag()
        guard let asset = SingBoxRelease.asset(version: tag) else {
            throw InstallError.releaseLookupFailed("无法从版本号「\(tag)」推出下载地址")
        }
        report("最新版本 \(asset.version)（\(asset.architecture.rawValue)），开始下载 \(asset.archiveName)")

        let workspace = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let archive = workspace.appendingPathComponent(asset.archiveName)
        try await download(asset.downloadURL, to: archive)

        report("解压 \(asset.archiveName)")
        let extraction = try await CommandRunner(timeoutSeconds: 120)
            .run("/usr/bin/tar", ["-xzf", archive.path, "-C", workspace.path])
        guard extraction.succeeded else {
            throw InstallError.extractionFailed(Self.tail(extraction.output))
        }
        let extracted = workspace.appendingPathComponent(asset.pathInArchive)
        guard FileManager.default.fileExists(atPath: extracted.path) else {
            throw InstallError.extractionFailed("压缩包里没有 \(asset.pathInArchive)")
        }

        // 先在临时目录完成签名和启动验证，失败时保留当前可用版本。
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extracted.path)
        try await makeRunnable(extracted)
        let version = try await Self.reportedVersion(of: extracted.path)
        let destination = try install(extracted)
        CoreLog.configuration.notice("已下载安装 sing-box：\(destination.path, privacy: .public)")
        return Outcome(binaryPath: destination.path, version: version, method: .download(asset.downloadURL))
    }

    private nonisolated func latestReleaseTag() async throws -> String {
        var request = URLRequest(url: SingBoxRelease.latestReleaseAPI)
        // GitHub 对不带 User-Agent 的请求一律 403，报错文本还与限流一模一样，
        // 少了这一行会得到一个极难看懂的失败。
        request.setValue("RouteBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // 这台机器此刻还没有任何可用出口——直连到不了 GitHub 是完全正常的结果，
            // 不该报得像是程序出了故障。具体怎么绕开由调用方接着说（见 manualInstallGuide）。
            throw InstallError.releaseLookupFailed("连不上 GitHub：\(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.releaseLookupFailed("GitHub 返回 HTTP \(http.statusCode)")
        }
        struct Release: Decodable { let tagName: String }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let release = try? decoder.decode(Release.self, from: data) else {
            throw InstallError.releaseLookupFailed("读不懂 GitHub 返回的版本信息")
        }
        return release.tagName
    }

    private nonisolated func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue("RouteBar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 300
        // 用 delegate 拿字节数，而不是 `URLSession.bytes` 逐字节 await：后者对一个
        // 二十几 MB 的包要在异步序列上迭代两千多万次，光调度开销就够烧掉几十秒 CPU，
        // 为了一个进度条把下载本身拖慢，本末倒置。
        let reporter = DownloadProgressReporter { [progress] fraction, written, total in
            progress(Progress("正在下载 \(Self.megabytes(written)) / \(Self.megabytes(total))",
                              fraction: fraction))
        }
        do {
            let (temporary, response) = try await URLSession.shared.download(for: request, delegate: reporter)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw InstallError.downloadFailed("HTTP \(http.statusCode)：\(url.absoluteString)")
            }
            // 系统会在这次调用返回后回收那个临时文件，必须当场搬走。
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.downloadFailed("\(url.absoluteString)：\(error.localizedDescription)")
        }
    }

    private nonisolated static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// 把解压出来的二进制搬进 RouteBar 自己的目录，并给上可执行位。
    private nonisolated func install(_ binary: URL) throws -> URL {
        let destination = managedBinary
        try FileManager.default.createDirectory(at: managedDirectory, withIntermediateDirectories: true)
        // 同一目录内暂存，再用 rename 原子替换：任一步失败都保留旧文件，
        // 运行中的进程继续持有原 inode，不会读到只写了一半的新版本。
        let staged = managedDirectory.appendingPathComponent(".sing-box-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: binary, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        guard rename(staged.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return destination
    }

    /// 让这份二进制真的能被执行：去掉隔离标记，必要时补一个 ad-hoc 签名。
    private nonisolated func makeRunnable(_ binary: URL) async throws {
        let runner = CommandRunner(timeoutSeconds: 60)
        // 非沙盒应用下载的文件通常不带隔离标记，但这依赖于 LaunchServices 的行为，
        // 不值得赌——多跑一次没有代价，属性不存在时 xattr 只是返回非零。
        _ = try? await runner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", binary.path])

        // Apple Silicon 上没有有效签名的 arm64 二进制会被内核直接 SIGKILL，
        // 而 launchd 那一侧只会显示一个「服务起不来」，完全看不出是签名问题。
        // 上游已经签好时不动它——ad-hoc 覆盖等于把一个更强的签名换成更弱的。
        let verify = try? await runner.run("/usr/bin/codesign", ["--verify", "--strict", binary.path])
        guard verify?.succeeded != true else { return }
        report("发布件没有可用签名，就地做一次 ad-hoc 签名")
        let signed = try await runner.run("/usr/bin/codesign", ["--force", "--sign", "-", binary.path])
        guard signed.succeeded else {
            throw InstallError.unusableBinary("ad-hoc 签名失败：\(Self.tail(signed.output))")
        }
    }

    // MARK: - 工具

    /// 跑一次 `sing-box version`，既拿到版本号，也顺带证明这东西在这台机器上真的能跑。
    private nonisolated static func reportedVersion(of path: String) async throws -> String {
        guard let result = try? await CommandRunner(timeoutSeconds: 30).run(path, ["version"]),
              result.succeeded else {
            throw InstallError.unusableBinary("\(path) 装好了，但执行 sing-box version 失败")
        }
        let firstLine = result.output.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.trimmed().isEmpty ? "版本未知" : firstLine.trimmed()
    }

    private nonisolated static func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("routebar-singbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// brew 的输出动辄几十行，整段塞进弹窗只会把真正的错因顶出视野。
    private nonisolated static func tail(_ output: String, lines: Int = 8) -> String {
        let trimmed = output.trimmed()
        let all = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard all.count > lines else { return trimmed }
        return all.suffix(lines).joined(separator: "\n")
    }

    /// 只为拿下载进度而存在的 delegate。
    ///
    /// 节流到「整数百分比变了才报」：`didWriteData` 每收到一个数据包就调一次，
    /// 一次下载几千回，全转成界面更新的话，进度条本身会比下载更占 CPU。
    private final class DownloadProgressReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onProgress: @Sendable (Double, Int64, Int64) -> Void
        private var lastReportedPercent = -1

        init(onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            // 服务器没给 Content-Length 时是 -1，这时算不出百分比，也就不该假装有。
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let percent = Int(fraction * 100)
            guard percent != lastReportedPercent else { return }
            lastReportedPercent = percent
            onProgress(fraction, totalBytesWritten, totalBytesExpectedToWrite)
        }

        /// 协议要求实现。文件的搬运由 async 版 `download(for:delegate:)` 负责，这里无事可做。
        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }

    public enum InstallError: LocalizedError {
        case homebrewFailed(String)
        case releaseLookupFailed(String)
        case downloadFailed(String)
        case extractionFailed(String)
        case unusableBinary(String)

        public var errorDescription: String? {
            switch self {
            case .homebrewFailed(let detail): "brew install sing-box 失败：\(detail)"
            case .releaseLookupFailed(let detail): "查不到 sing-box 的最新版本：\(detail)"
            case .downloadFailed(let detail): "下载 sing-box 失败：\(detail)"
            case .extractionFailed(let detail): "解压 sing-box 失败：\(detail)"
            case .unusableBinary(let detail): detail
            }
        }
    }
}
