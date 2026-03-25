// Sources/Sessylph/ChatUI/ChatView.swift
import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "ChatView")

// MARK: - Chat Display Model

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var streamingText: String = ""
    var streamingThinking: String = ""
    var isStreaming: Bool = false
    var isConnected: Bool = false
    var pendingPermission: PendingPermission?
    var sessionInfo: SessionInfo?

    struct SessionInfo {
        let model: String?
        let cwd: String?
        let tools: [ToolInfo]
        let slashCommands: [SlashCommandInfo]
    }

    struct PendingPermission {
        let requestId: String
        let toolName: String
        let input: JSONValue?
        let description: String?
        let displayName: String?
        let suggestions: [PermissionSuggestion]
    }

    // Accumulate streaming deltas
    func appendStreamDelta(text: String) {
        streamingText += text
        isStreaming = true
    }

    func appendThinkingDelta(text: String) {
        streamingThinking += text
        isStreaming = true
    }

    // Finalize an assistant message from accumulated stream + content blocks
    func finalizeAssistantMessage(_ msg: AssistantMessage) {
        let chatMsg = ChatMessage(
            id: UUID().uuidString,
            role: .assistant,
            contentBlocks: msg.message.content,
            parentToolUseId: msg.parentToolUseId,
            timestamp: Date()
        )
        messages.append(chatMsg)
        streamingText = ""
        streamingThinking = ""
        isStreaming = false
    }

    func addUserMessage(_ text: String) {
        let chatMsg = ChatMessage(
            id: UUID().uuidString,
            role: .user,
            contentBlocks: [.text(TextBlock(type: "text", text: text))],
            parentToolUseId: nil,
            timestamp: Date()
        )
        messages.append(chatMsg)
    }

    func addSystemEvent(_ text: String) {
        let chatMsg = ChatMessage(
            id: UUID().uuidString,
            role: .system,
            contentBlocks: [.text(TextBlock(type: "text", text: text))],
            parentToolUseId: nil,
            timestamp: Date()
        )
        messages.append(chatMsg)
    }

    func addUserImageMessage(thumbnailData: Data) {
        // Display a placeholder message showing the user sent an image
        let chatMsg = ChatMessage(
            id: UUID().uuidString,
            role: .user,
            contentBlocks: [.text(TextBlock(type: "text", text: "[Image attached]"))],
            parentToolUseId: nil,
            timestamp: Date(),
            imageData: thumbnailData
        )
        messages.append(chatMsg)
    }
}

struct ChatMessage: Identifiable {
    let id: String
    let role: Role
    let contentBlocks: [ContentBlock]
    let parentToolUseId: String?
    let timestamp: Date
    let imageData: Data?

    init(id: String, role: Role, contentBlocks: [ContentBlock], parentToolUseId: String?, timestamp: Date, imageData: Data? = nil) {
        self.id = id
        self.role = role
        self.contentBlocks = contentBlocks
        self.parentToolUseId = parentToolUseId
        self.timestamp = timestamp
        self.imageData = imageData
    }

    enum Role {
        case user
        case assistant
        case system
    }
}

// MARK: - Chat View

struct ChatView: View {
    let viewModel: ChatViewModel
    let onSend: (String) -> Void
    let onImageDrop: ((Data, String) -> Void)?
    let onAllow: (String, [PermissionSuggestion]?) -> Void
    let onDeny: (String, String?) -> Void
    let onInterrupt: () -> Void

    init(
        viewModel: ChatViewModel,
        onSend: @escaping (String) -> Void,
        onImageDrop: ((Data, String) -> Void)? = nil,
        onAllow: @escaping (String, [PermissionSuggestion]?) -> Void,
        onDeny: @escaping (String, String?) -> Void,
        onInterrupt: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onSend = onSend
        self.onImageDrop = onImageDrop
        self.onAllow = onAllow
        self.onDeny = onDeny
        self.onInterrupt = onInterrupt
    }

    var body: some View {
        VStack(spacing: 0) {
            // Message feed
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        // Streaming text (in-progress)
                        if viewModel.isStreaming {
                            StreamingTextView(
                                text: viewModel.streamingText,
                                thinking: viewModel.streamingThinking
                            )
                            .id("streaming")
                        }

                        // Permission banner
                        if let perm = viewModel.pendingPermission {
                            PermissionBanner(
                                permission: perm,
                                onAllow: { onAllow(perm.requestId, perm.suggestions) },
                                onDeny: { onDeny(perm.requestId, nil) }
                            )
                            .id("permission")
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) {
                    withAnimation {
                        proxy.scrollTo(viewModel.messages.last?.id, anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.streamingText) {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }

            Divider()

            // Input area
            ChatInputView(
                onSend: onSend,
                onImageDrop: onImageDrop,
                onInterrupt: onInterrupt,
                isStreaming: viewModel.isStreaming,
                isConnected: viewModel.isConnected,
                slashCommands: viewModel.sessionInfo?.slashCommands ?? []
            )
        }
    }
}
