import SwiftUI

/// 节点命名试跑：按输入框里的模板逐个列出「原名 → 输出名」。
///
/// 存在的理由是命名模板改完即时生效——存下去就等于把 Surge 里的名字全换了一遍。
/// 先在这里看清楚每个节点会变成什么，再决定要不要落盘。
struct NodeNamePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let template: String
    /// 这份模板是不是已经是生效中的那一条。是的话「应用」没有意义。
    let isApplied: Bool
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("命名试跑").font(.title2.bold())
                Text(NodeNaming.normalized(template))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(result.isSample ? .orange : .secondary)
            }

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(result.rows.enumerated()), id: \.element.id) { offset, row in
                        if offset > 0 { Divider() }
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(offset + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 28, alignment: .trailing)
                            Text(row.originalName)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(row.outputName)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(verbatim: "\(row.localPort)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 7)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                Text(placeholderHelp)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Spacer(minLength: 16)
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isApplied ? "已生效" : "应用这份模板") {
                    apply()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isApplied)
            }
        }
        .padding(22)
        .frame(width: 640, height: 460)
    }

    private var result: (rows: [NodeNaming.PreviewRow], isSample: Bool) {
        NodeNaming.previewRows(template: template,
                               subscriptions: model.subscriptions,
                               mapped: model.mappedNodes)
    }

    private var caption: String {
        result.isSample
            ? "当前没有启用节点，下面是造出来的示例——真实节点名会替换掉「香港 01」这些。"
            : "共 \(result.rows.count) 个启用节点。禁用的节点不输出到 Surge，因此不在这里。"
    }

    private var placeholderHelp: String {
        NodeNaming.placeholders.map { "\($0.token) \($0.summary)" }.joined(separator: "、")
    }
}
