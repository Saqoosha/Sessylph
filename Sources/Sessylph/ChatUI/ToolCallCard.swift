// Sources/Sessylph/ChatUI/ToolCallCard.swift
import SwiftUI

struct ToolCallCard: View {
    let toolUse: ToolUseBlock
    let toolResult: ToolResultBlock?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: iconName(for: toolUse.name))
                        .foregroundStyle(.orange)
                    Text(toolUse.name)
                        .fontWeight(.medium)
                    Text(toolUse.input.displaySummary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .padding(8)
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                Divider()
                toolInputView(toolUse.name, input: toolUse.input)
                    .padding(8)
                if let toolResult, let content = toolResult.content, !content.isEmpty {
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        Text("OUT")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.tertiary)
                            .frame(width: 28, alignment: .leading)
                        ScrollView {
                            Text(content)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                    }
                    .padding(8)
                }
            }
        }
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    private func iconName(for tool: String) -> String {
        switch tool {
        case "Bash": return "terminal"
        case "Edit": return "pencil"
        case "Read": return "doc.text"
        case "Write": return "doc.badge.plus"
        case "Glob": return "magnifyingglass"
        case "Grep": return "text.magnifyingglass"
        case "Agent": return "person.2"
        default: return "wrench"
        }
    }

    @ViewBuilder
    private func toolInputView(_ name: String, input: JSONValue) -> some View {
        switch name {
        case "Bash":
            if let command = input["command"]?.displaySummary {
                CodeBlockView(language: "bash", code: command)
            }
        case "Edit":
            VStack(alignment: .leading, spacing: 4) {
                if let path = input["file_path"]?.displaySummary {
                    Text(path).font(.caption).foregroundStyle(.secondary)
                }
                if let oldStr = input["old_string"]?.displaySummary,
                   let newStr = input["new_string"]?.displaySummary {
                    HStack(alignment: .top) {
                        CodeBlockView(language: "diff", code: "- \(oldStr)")
                        CodeBlockView(language: "diff", code: "+ \(newStr)")
                    }
                }
            }
        case "Read":
            if let path = input["file_path"]?.displaySummary {
                Text(path)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        case "Write":
            VStack(alignment: .leading, spacing: 4) {
                if let path = input["file_path"]?.displaySummary {
                    Text(path).font(.caption).foregroundStyle(.secondary)
                }
                if let content = input["content"]?.displaySummary {
                    CodeBlockView(language: nil, code: String(content.prefix(500)))
                }
            }
        default:
            // Generic JSON display
            Text(input.displaySummary)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
