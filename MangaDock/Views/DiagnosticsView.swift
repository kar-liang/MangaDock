import SwiftUI
import UIKit

/// Shows the on-device diagnostic log so a bug can be reported with facts
/// instead of a screenshot and a guess.
struct DiagnosticsView: View {
    @ObservedObject private var log = DiagLog.shared
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Toggle("记录诊断日志", isOn: $log.isEnabled)
            } header: {
                Text("开关")
            } footer: {
                Text(log.isEnabled
                     ? "正在记录。去复现一次问题，然后回这里点右上角复制。"
                     : "已关闭，不会产生新记录。需要抓问题时先打开，再去复现。")
            }

            if log.entries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(log.isEnabled ? "还没有记录" : "日志已关闭")
                        .font(.headline)
                    Text(log.isEnabled
                         ? "去阅读器里把出问题的章节再点一次，然后回到这里。"
                         : "把上面的开关打开，再去复现一次问题，记录就会出现在这里。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                Section {
                    ForEach(log.entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.category.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.secondary)
                            Text(entry.text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text("新记录在最上面。点右上角复制，整段贴出来就行。")
                }
            }
        }
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = log.exportText
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(log.entries.isEmpty)
                .accessibilityLabel("复制全部日志")

                Button(role: .destructive) {
                    log.clear()
                    copied = false
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(log.entries.isEmpty)
                .accessibilityLabel("清空日志")
            }
        }
    }
}
