import SwiftUI

/// 节点详情栏。
struct NodeInspectorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let node = model.selectedNode {
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(spacing: 14) {
                        InfoCard("节点") {
                            InfoRow("名称", node.name)
                            Divider()
                            InfoRow("来源", model.sourceNames(for: node).joined(separator: "、"))
                            Divider()
                            InfoRow("状态") {
                                Text(node.isEnabled ? "已启用" : "已禁用")
                                    .foregroundStyle(node.isEnabled ? .green : .secondary)
                            }
                            if let port = localPort(for: node) {
                                Divider()
                                InfoRow("本地端口", "127.0.0.1:\(port)")
                            }
                        }

                        InfoCard("服务器") {
                            InfoRow("地址", node.server)
                            Divider()
                            InfoRow("端口", "\(node.serverPort)")
                            Divider()
                            InfoRow("协议", node.protocolLabel)
                        }

                        InfoCard("Reality") {
                            InfoRow("流控", node.flow)
                            Divider()
                            InfoRow("SNI", node.serverName)
                            Divider()
                            InfoRow("uTLS 指纹", node.fingerprint)
                            Divider()
                            InfoRow("Short ID", node.shortID.isEmpty ? "—" : node.shortID)
                        }

                        InfoCard("延迟") {
                            InfoRow("结果") {
                                if model.testingNodeIDs.contains(node.id) {
                                    Text("测试中…")
                                } else {
                                    Text(node.latencyText).foregroundStyle(node.latencyTint)
                                }
                            }
                            if let measuredAt = node.latency?.measuredAt {
                                Divider()
                                InfoRow("测试时间", measuredAt.formatted(date: .abbreviated, time: .shortened))
                            }
                        }

                        actions(node)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        } else {
            ContentUnavailableView("选择一个节点", systemImage: "sidebar.right")
        }
    }

    private var topBar: some View {
        HStack {
            Text("节点详情").font(.title3.bold())
            Spacer()
            Button {
                model.selectedNodeID = nil
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

    private func actions(_ node: ProxyNode) -> some View {
        HStack(spacing: 8) {
            Button("测试延迟", systemImage: "speedometer") {
                Task { await model.testNode(node.id) }
            }
            .disabled(model.testingNodeIDs.contains(node.id) || !node.isEnabled)
            Button(node.isEnabled ? "禁用节点" : "启用节点",
                   systemImage: node.isEnabled ? "pause.circle" : "play.circle") {
                model.setNodeEnabled(!node.isEnabled, id: node.id)
            }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func localPort(for node: ProxyNode) -> Int? {
        model.mappedNodes.first { $0.node.id == node.id }?.localPort
    }
}
