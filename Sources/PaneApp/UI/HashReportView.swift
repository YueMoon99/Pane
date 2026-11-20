import SwiftUI
import AppKit

/// 哈希计算结果面板：等宽字体、可选中、一键拷贝全部
struct HashReportView: View {
    let report: FileActionService.HashReport
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var plainText: String {
        report.rows.map { "\($0.digest)  \($0.name)" }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.tr("%@ 校验值", report.algorithm))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(L10n.tr("%@ 项", report.rows.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(report.rows) { row in
                        HStack(alignment: .top, spacing: 12) {
                            Text(row.digest)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(width: 300, alignment: .leading)
                            Text(row.name)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 5)
                    }

                    if !report.failed.isEmpty {
                        Divider().padding(.vertical, 6)
                        Text(L10n.tr("未能计算"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 4)
                        ForEach(report.failed, id: \.self) { name in
                            Text(name)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 2)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 320)

            Divider()

            HStack {
                Button(copied ? L10n.tr("已拷贝") : L10n.tr("拷贝全部")) {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(plainText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .disabled(report.rows.isEmpty)
                Spacer()
                Button(L10n.tr("完成")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 600, height: 420)
    }
}
