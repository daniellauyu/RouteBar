import Foundation

/// 应用版本号。单一来源是仓库根 `VERSION` 文件，由 `scripts/sync-version.sh`
/// 同步到下面的 `fallback`（以及 Xcode 工程 MARKETING_VERSION）。
/// 打包为 .app 后优先读取 bundle 的 CFBundleShortVersionString。
enum AppVersion {
    static let fallback = "1.8.2"

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? fallback
    }

    /// Debug 构建为真。
    ///
    /// 开发副本和已安装版本图标一模一样，同时跑着的时候光看界面认不出在用哪一个，
    /// 「改了没生效」还是「压根没在跑那一份」就无从判断。
    static var isDevelopmentBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static var build: String? {
        let value = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// 关于页展示用，如 `v1.1.0 (2) dev`；正式构建不带 `dev` 后缀。
    static var displayText: String {
        let base = build.map { "v\(current) (\($0))" } ?? "v\(current)"
        return isDevelopmentBuild ? "\(base) dev" : base
    }
}
