// Sources/Sessylph/ChatUI/ToolResultView.swift
import SwiftUI

struct ToolResultView: View {
    let result: ToolResultBlock

    var body: some View {
        if let content = result.content {
            VStack(alignment: .leading, spacing: 4) {
                if result.isError == true {
                    Label("Error", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                if content.count > 500 {
                    DisclosureGroup("Output (\(content.count) chars)") {
                        ScrollView {
                            Text(content)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxHeight: 300)
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Text(content)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(.quaternary.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}
