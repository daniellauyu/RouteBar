import SwiftUI

/// 订阅页：左列表 + 右详情。
///
/// 详情栏内嵌在页面里而不是占用窗口第三栏——只有这一页和节点页需要详情，
/// 为它们把整个窗口改成三栏，会让另外六个页面白白损失一栏宽度。
struct SubscriptionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editor: SubscriptionEditorContext?

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                listPane
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                if model.selectedSubscription != nil {
                    Divider()
                    SubscriptionInspectorView(edit: { subscription, url in
                        editor = SubscriptionEditorContext(subscription: subscription, url: url)
                    })
                    .frame(width: inspectorWidth(available: proxy.size.width))
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .sheet(item: $editor) { context in
            SubscriptionEditorView(context: context) { id, name, url, note, interval in
                model.saveSubscription(id: id, name: name, url: url, note: note, interval: interval)
            }
        }
    }

    /// 详情栏用明确宽度，多余空间始终由列表吸收。
    private func inspectorWidth(available: CGFloat) -> CGFloat {
        min(420, max(300, available * 0.34))
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            PageBar("管理订阅源；更新后自动重新生成出口并同步到 Surge。") {
                Button {
                    editor = SubscriptionEditorContext()
                } label: {
                    Label("添加订阅", systemImage: "plus")
                }
                Button {
                    Task { await model.updateAll() }
                } label: {
                    Label("更新全部", systemImage: "arrow.clockwise")
                }
                .disabled(model.isUpdating)
            }

            if model.isUpdating {
                ProgressView(value: model.updateProgress)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            Divider()

            if model.subscriptions.isEmpty {
                ContentUnavailableView {
                    Label("还没有订阅", systemImage: "square.3.layers.3d")
                } description: {
                    Text("添加一个订阅地址，RouteBar 会解析节点并生成本地出口。")
                } actions: {
                    Button("添加订阅") { editor = SubscriptionEditorContext() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedSubscriptionID) {
                    ForEach(model.filteredSubscriptions) { subscription in
                        SubscriptionRow(subscription: subscription)
                            .tag(Optional(subscription.id))
                    }
                }
                .searchable(text: $model.subscriptionSearchText, placement: .toolbar, prompt: "搜索订阅名称或备注")
                .overlay {
                    if model.filteredSubscriptions.isEmpty {
                        ContentUnavailableView.search(text: model.subscriptionSearchText)
                    }
                }
            }
        }
    }
}

/// 订阅列表行。
private struct SubscriptionRow: View {
    @EnvironmentObject private var model: AppModel
    let subscription: SubscriptionRecord

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { subscription.isEnabled },
                set: { model.setSubscriptionEnabled($0, for: subscription.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 3) {
                Text(subscription.name).font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if subscription.status == .updating {
                ProgressView().controlSize(.small)
            } else {
                StatusPill(text: subscription.status.label, color: subscription.status.tint)
            }
        }
        .padding(.vertical, 5)
    }

    /// 副标题一行讲清「多少节点 · 多久前更新 · 备注」——列表不再需要五列表头对齐。
    private var subtitle: String {
        var parts = ["\(subscription.nodes.count) 个节点", relativeTime(subscription.updatedAt)]
        if !subscription.note.isEmpty { parts.append(subscription.note) }
        return parts.joined(separator: " · ")
    }
}
