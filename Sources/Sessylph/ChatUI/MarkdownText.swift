// Sources/Sessylph/ChatUI/MarkdownText.swift
import SwiftUI
import Markdown

/// Renders Markdown content as a styled SwiftUI Text view.
struct MarkdownText: View {
    let source: String
    @AppStorage(Defaults.nativeUIFontSize) private var fontSize = 13.0

    var body: some View {
        Text(parseMarkdown(source))
            .font(.system(size: fontSize))
            .textSelection(.enabled)
    }

    private func parseMarkdown(_ text: String) -> AttributedString {
        do {
            // Use Apple's AttributedString Markdown parser for basic formatting
            let result = try AttributedString(markdown: text, options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            ))
            return result
        } catch {
            return AttributedString(text)
        }
    }
}

/// A code block with syntax highlighting placeholder and copy button.
struct CodeBlockView: View {
    let language: String?
    let code: String
    @AppStorage(Defaults.nativeUIFontName) private var fontName = ""
    @AppStorage(Defaults.nativeUIFontSize) private var fontSize = 13.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                HStack {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.quaternary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(fontName.isEmpty ? .system(size: fontSize, design: .monospaced) : .custom(fontName, size: fontSize))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
