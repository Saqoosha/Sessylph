// Sources/Sessylph/ChatUI/StreamingTextView.swift
import SwiftUI

struct StreamingTextView: View {
    let text: String
    let thinking: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkle")
                Text("Claude")
                    .fontWeight(.semibold)
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !thinking.isEmpty {
                DisclosureGroup("Thinking...") {
                    Text(thinking)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if !text.isEmpty {
                MarkdownText(source: text)
            }
        }
        .padding(.vertical, 4)
    }
}
