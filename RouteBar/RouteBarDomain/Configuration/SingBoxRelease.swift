import Foundation

/// sing-box 官方发布件的命名规则。
///
/// 没有 Homebrew 的机器上，「一键完成」直接从 GitHub Release 取二进制。下载与解压是
/// I/O，放在 Core 层；但**地址长什么样**是纯规则，放在这里才测得动——拼错一个字段
/// 只会得到 404，而那种错误在真机上要等到网络请求回来才暴露。
public enum SingBoxRelease {
    public nonisolated static let repository = "SagerNet/sing-box"

    /// 查最新版本用的接口。GitHub 对无 UA 的请求直接返回 403，调用方必须带上 UA。
    public nonisolated static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// 发布件里用的架构名。sing-box 跟 Go 的叫法一致：`arm64` / `amd64`，
    /// 而不是 macOS 那套 `arm64` / `x86_64`。
    public enum Architecture: String, Sendable, Equatable {
        case arm64
        case amd64

        /// 当前进程跑在哪种架构上。
        ///
        /// 用编译期条件而不是 `uname`：Rosetta 下 `uname -m` 报的是 x86_64，
        /// 而在那种情况下我们**确实**该下 amd64 的包——它要跟宿主进程一样能跑。
        public nonisolated static var current: Architecture {
            #if arch(arm64)
            .arm64
            #else
            .amd64
            #endif
        }
    }

    /// 一个具体的下载目标。
    public struct Asset: Sendable, Equatable {
        /// 归一化后的版本号，不带前导 v。
        public let version: String
        public let architecture: Architecture
        public let downloadURL: URL
        /// 解压后二进制在压缩包里的相对路径。tar 包带一层与包同名的目录。
        public let pathInArchive: String

        public nonisolated var archiveName: String { "\(stem).tar.gz" }
        private nonisolated var stem: String { "sing-box-\(version)-darwin-\(architecture.rawValue)" }
    }

    /// 版本号可能来自 tag（`v1.11.4`）也可能来自别处（`1.11.4`），统一去掉前导 v：
    /// tag 里有它，而文件名里没有，两处都拿同一个字符串去拼必然错一处。
    public nonisolated static func normalizedVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    }

    public nonisolated static func asset(version raw: String,
                                         architecture: Architecture = .current) -> Asset? {
        let version = normalizedVersion(raw)
        // 版本号会直接拼进 URL，必须先确认它只有版本号该有的字符。接口返回什么本不该
        // 全盘信任——这里是唯一一处把远端字符串接进下载地址的地方。
        guard !version.isEmpty,
              version.allSatisfy({ $0.isNumber || $0 == "." || $0.isLetter || $0 == "-" }) else {
            return nil
        }
        let stem = "sing-box-\(version)-darwin-\(architecture.rawValue)"
        guard let url = URL(string:
            "https://github.com/\(repository)/releases/download/v\(version)/\(stem).tar.gz") else {
            return nil
        }
        return Asset(version: version,
                     architecture: architecture,
                     downloadURL: url,
                     pathInArchive: "\(stem)/sing-box")
    }
}
