import Foundation
import Testing
@testable import RouteBarDomain

/// 发布件地址是「一键完成」在没有 Homebrew 的机器上唯一的下载来源。
/// 拼错任何一段都只会得到 404，而那种错误在真机上要等网络往返回来才暴露。
@Suite struct SingBoxReleaseTests {
    /// tag 带前导 v，文件名里没有——两处拿同一个字符串去拼必然错一处。
    @Test func versionDropsTheTagPrefix() {
        #expect(SingBoxRelease.normalizedVersion("v1.11.4") == "1.11.4")
        #expect(SingBoxRelease.normalizedVersion("1.11.4") == "1.11.4")
        #expect(SingBoxRelease.normalizedVersion("  v1.11.4\n") == "1.11.4")
    }

    @Test func assetPointsAtTheOfficialTarball() throws {
        let asset = try #require(SingBoxRelease.asset(version: "v1.11.4", architecture: .arm64))

        #expect(asset.version == "1.11.4")
        #expect(asset.archiveName == "sing-box-1.11.4-darwin-arm64.tar.gz")
        #expect(asset.downloadURL.absoluteString
            == "https://github.com/SagerNet/sing-box/releases/download/v1.11.4/sing-box-1.11.4-darwin-arm64.tar.gz")
        // tar 包带一层与包同名的目录，解压后要进这一层才拿得到二进制。
        #expect(asset.pathInArchive == "sing-box-1.11.4-darwin-arm64/sing-box")
    }

    /// Intel 机器上要下的是 amd64——sing-box 跟 Go 的叫法一致，不是 macOS 那套 x86_64。
    @Test func intelUsesTheGoArchitectureName() throws {
        let asset = try #require(SingBoxRelease.asset(version: "1.11.4", architecture: .amd64))

        #expect(asset.archiveName == "sing-box-1.11.4-darwin-amd64.tar.gz")
        #expect(asset.pathInArchive.hasSuffix("darwin-amd64/sing-box"))
    }

    /// 版本号来自 GitHub 的响应，是唯一一处把远端字符串接进下载地址的地方，
    /// 所以在拼 URL 之前就得挡住不像版本号的东西。
    @Test func rejectsVersionsThatCouldNotBeAVersion() {
        #expect(SingBoxRelease.asset(version: "") == nil)
        #expect(SingBoxRelease.asset(version: "v") == nil)
        #expect(SingBoxRelease.asset(version: "../../etc/passwd") == nil)
        #expect(SingBoxRelease.asset(version: "1.11.4 && rm -rf /") == nil)
    }
}
