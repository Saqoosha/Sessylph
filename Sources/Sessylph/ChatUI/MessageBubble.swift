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

            // Content blocks (tool_use paired with following tool_result)
            let pairedBlocks = pairToolBlocks(message.contentBlocks)
            ForEach(Array(pairedBlocks.enumerated()), id: \.offset) { _, paired in
                contentView(for: paired)
            }
        }
        .padding(.vertical, 4)
    }

    private struct PairedBlock {
        let block: ContentBlock
        let result: ToolResultBlock?
    }

    private func pairToolBlocks(_ blocks: [ContentBlock]) -> [PairedBlock] {
        var paired: [PairedBlock] = []
        var i = 0
        while i < blocks.count {
            let block = blocks[i]
            if case .toolUse(let toolUse) = block {
                // Check if next block is a matching tool_result
                var result: ToolResultBlock? = nil
                if i + 1 < blocks.count, case .toolResult(let tr) = blocks[i + 1], tr.toolUseId == toolUse.id {
                    result = tr
                    i += 1  // Skip the result block
                }
                paired.append(PairedBlock(block: block, result: result))
            } else if case .toolResult = block {
                // Standalone result (no matching tool_use) — show as-is
                paired.append(PairedBlock(block: block, result: nil))
            } else {
                paired.append(PairedBlock(block: block, result: nil))
            }
            i += 1
        }
        return paired
    }

    @ViewBuilder
    private func contentView(for paired: PairedBlock) -> some View {
        switch paired.block {
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
            ToolCallCard(toolUse: toolUse, toolResult: paired.result)

        case .toolResult(let toolResult):
            ToolResultView(result: toolResult)
        }
    }
}
