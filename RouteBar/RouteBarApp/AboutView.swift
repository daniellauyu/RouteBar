import SwiftUI

/// 关于页。
struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 38))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("RouteBar").font(.title.weight(.semibold))
                        Text("版本 \(AppVersion.displayText)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("把机场订阅编译成 sing-box 本地出口，并同步给 Surge。")
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Label("订阅地址存放在钥匙串，不写入任何配置文件。", systemImage: "lock.fill")
                    Label("覆盖 sing-box 与 Surge 配置前都会留一份 .routebar-backup。", systemImage: "clock.arrow.circlepath")
                    Label("新配置先经 sing-box check 校验，通过后才替换正式文件。", systemImage: "checkmark.shield")
                    Label("分流规则仍由 Surge 决定，RouteBar 只维护可用出口。", systemImage: "arrow.triangle.branch")
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("自用工具").font(.headline)
                    Text("当前构建关闭了 App Sandbox，以便读写用户目录并调用 launchctl。分发给他人前应改为 helper + 权限引导方案。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
