// Sources/Sessylph/ChatUI/ChatInputView.swift
import SwiftUI
import UniformTypeIdentifiers

struct ChatInputView: View {
    let onSend: (String) -> Void
    let onImageDrop: ((Data, String) -> Void)?
    let onInterrupt: () -> Void
    let isStreaming: Bool
    let isConnected: Bool
    let slashCommands: [SlashCommandInfo]

    @State private var inputText = ""
    @State private var showSlashPopover = false
    @State private var slashFilter = ""
    @FocusState private var isFocused: Bool

    init(
        onSend: @escaping (String) -> Void,
        onImageDrop: ((Data, String) -> Void)? = nil,
        onInterrupt: @escaping () -> Void,
        isStreaming: Bool,
        isConnected: Bool = true,
        slashCommands: [SlashCommandInfo] = []
    ) {
        self.onSend = onSend
        self.onImageDrop = onImageDrop
        self.onInterrupt = onInterrupt
        self.isStreaming = isStreaming
        self.isConnected = isConnected
        self.slashCommands = slashCommands
    }

    private var filteredCommands: [SlashCommandInfo] {
        guard !slashFilter.isEmpty else { return slashCommands }
        return slashCommands.filter { $0.name.localizedCaseInsensitiveContains(slashFilter) }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $inputText)
                .font(.body)
                .frame(minHeight: 36, maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .focused($isFocused)
                .onKeyPress(.return) {
                    if NSEvent.modifierFlags.contains(.shift) {
                        return .ignored  // Allow newline
                    }
                    sendMessage()
                    return .handled
                }
                .onChange(of: inputText) { _, newValue in
                    updateSlashPopover(newValue)
                }
                .popover(isPresented: $showSlashPopover, arrowEdge: .top) {
                    slashCommandList
                }
                .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                    handleDrop(providers)
                }
                .onPasteCommand(of: [.png, .tiff]) { providers in
                    handlePaste(providers)
                }

            if isStreaming {
                Button(action: onInterrupt) {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                .help("Stop (Escape)")
            } else {
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.bordered)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isConnected)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(12)
        .overlay(alignment: .center) {
            if !isConnected {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to Claude Code...")
                        .foregroundStyle(.secondary)
                }
                .allowsHitTesting(false)
            }
        }
        .onAppear { isFocused = true }
    }

    // MARK: - Slash Command Popover

    private var slashCommandList: some View {
        List(filteredCommands, id: \.name) { cmd in
            Button {
                inputText = "/\(cmd.name) "
                showSlashPopover = false
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("/\(cmd.name)")
                        .fontWeight(.medium)
                    if let desc = cmd.description {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .frame(width: 250, height: min(CGFloat(filteredCommands.count) * 44, 220))
    }

    private func updateSlashPopover(_ text: String) {
        if text.hasPrefix("/") && !text.contains(" ") && !slashCommands.isEmpty {
            slashFilter = String(text.dropFirst())
            showSlashPopover = true
        } else {
            showSlashPopover = false
        }
    }

    // MARK: - Send

    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
        inputText = ""
    }

    // MARK: - Image Handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let onImageDrop else { return false }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data {
                        Task { @MainActor in
                            onImageDrop(data, "image/png")
                        }
                    }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let urlData = item as? Data,
                          let url = URL(dataRepresentation: urlData, relativeTo: nil),
                          let data = try? Data(contentsOf: url) else { return }
                    let ext = url.pathExtension.lowercased()
                    let mediaType = ext == "png" ? "image/png" : ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/png"
                    Task { @MainActor in
                        onImageDrop(data, mediaType)
                    }
                }
                return true
            }
        }
        return false
    }

    private func handlePaste(_ providers: [NSItemProvider]) {
        guard let onImageDrop else { return }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
                    if let data {
                        Task { @MainActor in
                            onImageDrop(data, "image/png")
                        }
                    }
                }
                return
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.tiff.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.tiff.identifier) { data, _ in
                    if let data, let pngData = convertTIFFtoPNG(data) {
                        Task { @MainActor in
                            onImageDrop(pngData, "image/png")
                        }
                    }
                }
                return
            }
        }
    }

    private func convertTIFFtoPNG(_ tiffData: Data) -> Data? {
        guard let imageRep = NSBitmapImageRep(data: tiffData) else { return nil }
        return imageRep.representation(using: .png, properties: [:])
    }
}
