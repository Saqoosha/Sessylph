// Sources/Sessylph/ChatUI/MessageBubble.swift
import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Role header
            HStack {
                switch message.role {
                case .user:
                    Image(systemName: "person.fill")
                    Text("You")
                        .fontWeight(.semibold)
                case .assistant:
                    Image(systemName: "sparkle")
                    Text("Claude")
                        .fontWeight(.semibold)
                case .system:
                    Image(systemName: "info.circle")
                    Text("System")
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(message.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Image thumbnail (if present)
            if let imageData = message.imageData, let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 200, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Content blocks
            ForEach(Array(message.contentBlocks.enumerated()), id: \.offset) { _, block in
                contentView(for: block)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func contentView(for block: ContentBlock) -> some View {
        switch block {
        case .text(let textBlock):
            MarkdownText(source: textBlock.text)

        case .thinking(let thinkingBlock):
            DisclosureGroup("Thinking") {
                Text(thinkingBlock.thinking)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .toolUse(let toolUse):
            ToolCallCard(toolUse: toolUse)

        case .toolResult(let toolResult):
            ToolResultView(result: toolResult)
        }
    }
}
