import SwiftUI

/// 添加 / 编辑订阅的表单上下文。
struct SubscriptionEditorContext: Identifiable {
    let id = UUID()
    var subscriptionID: UUID?
    var name = ""
    var url = ""
    var note = ""
    var interval = 6

    init(subscription: SubscriptionRecord? = nil, url: String = "") {
        subscriptionID = subscription?.id
        name = subscription?.name ?? ""
        self.url = url
        note = subscription?.note ?? ""
        interval = subscription?.updateIntervalHours ?? 6
    }
}

struct SubscriptionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var context: SubscriptionEditorContext
    @State private var revealURL = false
    let save: (UUID?, String, String, String, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(context.subscriptionID == nil ? "添加订阅" : "编辑订阅")
                .font(.title2.bold())

            Form {
                TextField("名称", text: $context.name)
                // 默认遮蔽，但给一个显形开关：粘贴出错时不给看就没法排查。
                HStack {
                    if revealURL {
                        TextField("订阅 URL", text: $context.url)
                    } else {
                        SecureField("订阅 URL", text: $context.url)
                    }
                    Button {
                        revealURL.toggle()
                    } label: {
                        Image(systemName: revealURL ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revealURL ? "隐藏地址" : "显示地址")
                }
                TextField("备注", text: $context.note)
                Picker("更新间隔", selection: $context.interval) {
                    Text("1 小时").tag(1)
                    Text("6 小时").tag(6)
                    Text("12 小时").tag(12)
                    Text("24 小时").tag(24)
                }
            }
            .formStyle(.grouped)

            Text("地址存入钥匙串，不写进 state.json。自动更新只在 RouteBar 运行时生效。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    save(context.subscriptionID, context.name, context.url, context.note, context.interval)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var isValid: Bool {
        guard !context.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let url = URL(string: context.url), url.scheme != nil, url.host != nil else { return false }
        return true
    }
}
