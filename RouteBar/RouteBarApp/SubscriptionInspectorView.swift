import SwiftUI

/// 订阅详情栏。
struct SubscriptionInspectorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var url = ""
    let edit: (SubscriptionRecord, String) -> Void

    var body: some View {
        if let subscription = model.selectedSubscription {
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(spacing: 14) {
                        InfoCard("基本信息") {
                            InfoRow("名称", subscription.name)
                            Divider()
                            InfoRow("地址", maskedURL)
                            Divider()
                            InfoRow("更新间隔", "\(subscription.updateIntervalHours) 小时")
                            if !subscription.note.isEmpty {
                                Divider()
                                InfoRow("备注", subscription.note)
                            }
                        }

                        InfoCard("节点与更新") {
                            InfoRow("节点数", "\(subscription.nodes.count)")
                            Divider()
                            InfoRow("启用节点", "\(subscription.nodes.filter(\.isEnabled).count)")
                            Divider()
                            InfoRow("最后更新",
                                    subscription.updatedAt?.formatted(date: .numeric, time: .shortened) ?? "尚未更新")
                            Divider()
                            InfoRow("下次更新",
                                    UpdateSchedule.nextUpdate(for: subscription)?
                                        .formatted(date: .omitted, time: .shortened) ?? "更新后计算")
                        }

                        InfoCard("安全") {
                            InfoRow("凭据存储") {
                                Label("钥匙串", systemImage: "lock.fill").foregroundStyle(.green)
                            }
                            Divider()
                            InfoRow("连接方式") {
                                if url.hasPrefix("https://") {
                                    Label("HTTPS", systemImage: "checkmark.shield").foregroundStyle(.green)
                                } else {
                                    Label("非 HTTPS，订阅内容可能被中间人读取", systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }

                        if let error = subscription.lastError {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("最近一次更新失败", systemImage: "exclamationmark.triangle.fill")
                                    .font(.headline)
                                    .foregroundStyle(.orange)
                                Text(error)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.orange.opacity(0.3)))
                        }

                        actions(subscription)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .task(id: subscription.id) {
                url = await model.subscriptionURL(for: subscription)
            }
        } else {
            ContentUnavailableView("选择一个订阅", systemImage: "sidebar.right")
        }
    }

    private var topBar: some View {
        HStack {
            Text("订阅详情").font(.title3.bold())
            Spacer()
            Button {
                model.selectedSubscriptionID = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭详情")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private func actions(_ subscription: SubscriptionRecord) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("立即更新", systemImage: "arrow.clockwise") {
                    Task { await model.update(subscription.id) }
                }
                .disabled(model.isUpdating)
                Button("编辑", systemImage: "pencil") { edit(subscription, url) }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("删除订阅", systemImage: "trash", role: .destructive) {
                model.delete(subscription)
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 详情栏默认不显示完整订阅地址：它等价于账号密码，而这个界面随时可能被人看到。
    private var maskedURL: String {
        guard let host = URL(string: url)?.host else { return "已安全存储" }
        return "https://\(host)/••••••"
    }
}
