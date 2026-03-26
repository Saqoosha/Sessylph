// Sources/Sessylph/ChatUI/ChatInputView.swift
import SwiftUI
import UniformTypeIdentifiers

struct ChatInputView: View {
    let onSend: (String) -> Void
    let onImageDrop: ((Data, String) -> Void)?
    let onInterrupt: () -> Void
    let isStreaming: Bool
    let isConnected: Bool
    let slashCommands: [String]

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
        slashCommands: [String] = []
    ) {
        self.onSend = onSend
        self.onImageDrop = onImageDrop
        self.onInterrupt = onInterrupt
        self.isStreaming = isStreaming
        self.isConnected = isConnected
        self.slashCommands = slashCommands
    }

    private var filteredCommands: [String] {
        guard !slashFilter.isEmpty else { return slashCommands }
        return slashCommands.filter { $0.localizedCaseInsensitiveContains(slashFilter) }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $inputText)
                .font(.body)
                .frame(minHeight: 36, maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .focused($isFocused)
                .disabled(isStreaming)
                .opacity(isStreaming ? 0.5 : 1.0)
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
        .onAppear { isFocused = true }
    }

    // MARK: - Slash Command Popover

    private var slashCommandList: some View {
        let builtIn = filteredCommands.filter { !$0.contains(":") }
        let plugins = filteredCommands.filter { $0.contains(":") }

        return List {
            if !builtIn.isEmpty {
                Section("Commands") {
                    ForEach(builtIn, id: \.self) { cmd in
                        Button {
                            inputText = "/\(cmd) "
                            showSlashPopover = false
                        } label: {
                            Text("/\(cmd)").fontWeight(.medium)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !plugins.isEmpty {
                Section("Skills") {
                    ForEach(plugins, id: \.self) { cmd in
                        Button {
                            inputText = "/\(cmd) "
                            showSlashPopover = false
                        } label: {
                            Text("/\(cmd)")
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(width: 300, height: min(max(CGFloat(filteredCommands.count) * 28 + 40, 60), 300))
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
        guard !isStreaming else { return }
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
