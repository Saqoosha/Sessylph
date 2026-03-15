import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(Defaults.defaultModel) private var defaultModel = ""
    @AppStorage(Defaults.defaultPermissionMode) private var defaultPermissionMode = ""
    @AppStorage(Defaults.defaultEffortLevel) private var defaultEffortLevel = ""
    @AppStorage(Defaults.notificationsEnabled) private var notificationsEnabled = true
    @AppStorage(Defaults.notifyOnStop) private var notifyOnStop = true
    @AppStorage(Defaults.notifyOnPermission) private var notifyOnPermission = true
    @AppStorage(Defaults.activateOnStop) private var activateOnStop = false
    @AppStorage(Defaults.terminalFontName) private var terminalFontName = "Comic Code"
    @AppStorage(Defaults.terminalFontSize) private var terminalFontSize = 13.0
    @AppStorage(Defaults.suppressCloseTabAlert) private var suppressCloseTabAlert = false
    @AppStorage(Defaults.suppressQuitAlert) private var suppressQuitAlert = false

    @State private var cliOptions = ClaudeCLI.CLIOptions(modelAliases: [], permissionModes: [])
    @State private var monospacedFonts: [String] = []
    var body: some View {
        Form {
            Section("Claude Code Defaults") {
                Picker("Default Model", selection: $defaultModel) {
                    Text("Auto").tag("")
                    ForEach(cliOptions.modelAliases, id: \.self) { alias in
                        Text(alias.prefix(1).uppercased() + alias.dropFirst()).tag(alias)
                    }
                }

                Picker("Effort Level", selection: $defaultEffortLevel) {
                    Text("Auto").tag("")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }

                Picker("Permission Mode", selection: $defaultPermissionMode) {
                    ForEach(cliOptions.permissionModes, id: \.self) { mode in
                        Text(PermissionMode.label(for: mode)).tag(mode)
                    }
                }
            }

            Section("Notifications") {
                Toggle("Enable Notifications", isOn: $notificationsEnabled)
                Toggle("Notify on Task Completion", isOn: $notifyOnStop)
                    .disabled(!notificationsEnabled)
                Toggle("Notify on Permission Request", isOn: $notifyOnPermission)
                    .disabled(!notificationsEnabled)
                Toggle("Bring to Front on Task Completion", isOn: $activateOnStop)
            }

            Section("Terminal") {
                LabeledContent("Font") {
                    FontPopUpButton(
                        selection: $terminalFontName,
                        fonts: monospacedFonts,
                        onSelect: { GhosttyApp.shared.reloadConfig() }
                    )
                }

                HStack {
                    Text("Font Size")
                    Slider(value: $terminalFontSize, in: 10...24, step: 1) {
                        Text("Font Size")
                    }
                    Text("\(Int(terminalFontSize))pt")
                        .monospacedDigit()
                        .frame(width: 40)
                }

                Text("The quick brown fox jumps over the lazy dog. 0O 1lI")
                    .font(.custom(terminalFontName, size: terminalFontSize))
                    .foregroundStyle(.secondary)
            }
            .onChange(of: terminalFontSize) {
                GhosttyApp.shared.reloadConfig()
            }

            Section("Confirmations") {
                Toggle("Confirm before closing a running tab", isOn: Binding(
                    get: { !suppressCloseTabAlert },
                    set: { suppressCloseTabAlert = !$0 }
                ))
                Toggle("Confirm before quitting with active sessions", isOn: Binding(
                    get: { !suppressQuitAlert },
                    set: { suppressQuitAlert = !$0 }
                ))
            }

            Section("Info") {
                if let version = ClaudeCLI.claudeVersion() {
                    LabeledContent("Claude Code", value: version)
                } else {
                    LabeledContent("Claude Code", value: "Not found")
                        .foregroundStyle(.red)
                }
                if let version = CodexCLI.codexVersion() {
                    LabeledContent("Codex CLI", value: version)
                } else {
                    LabeledContent("Codex CLI", value: "Not found")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 450)
        .onAppear {
            cliOptions = ClaudeCLI.discoverCLIOptions()
            monospacedFonts = Self.loadMonospacedFonts()
            if !terminalFontName.isEmpty && !monospacedFonts.contains(terminalFontName) {
                monospacedFonts.insert(terminalFontName, at: 0)
            }
        }
    }

    private static func loadMonospacedFonts() -> [String] {
        let fm = NSFontManager.shared
        return fm.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 13) else { return false }
            if font.isFixedPitch || fm.traits(of: font).contains(.fixedPitchFontMask) {
                return true
            }
            let ctFont = font as CTFont
            var iGlyph = CGGlyph(0)
            var mGlyph = CGGlyph(0)
            var iChar: UniChar = 0x69 // 'i'
            var mChar: UniChar = 0x4D // 'M'
            guard CTFontGetGlyphsForCharacters(ctFont, &iChar, &iGlyph, 1),
                  CTFontGetGlyphsForCharacters(ctFont, &mChar, &mGlyph, 1) else { return false }
            var iAdvance = CGSize.zero
            var mAdvance = CGSize.zero
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &iGlyph, &iAdvance, 1)
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &mGlyph, &mAdvance, 1)
            return abs(iAdvance.width - mAdvance.width) < 0.1
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - NSPopUpButton wrapper (bypasses SwiftUI Picker checkmark bug on macOS)

struct FontPopUpButton: NSViewRepresentable {
    @Binding var selection: String
    let fonts: [String]
    var onSelect: (() -> Void)?

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.bezelStyle = .push
        button.controlSize = .regular
        button.lineBreakMode = .byTruncatingTail
        rebuildMenu(button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if button.itemTitles != fonts {
            rebuildMenu(button)
        }
        if button.titleOfSelectedItem != selection {
            button.selectItem(withTitle: selection)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func rebuildMenu(_ button: NSPopUpButton) {
        button.removeAllItems()
        for name in fonts {
            button.addItem(withTitle: name)
        }
        button.selectItem(withTitle: selection)
        button.sizeToFit()
    }

    class Coordinator: NSObject {
        var parent: FontPopUpButton
        init(_ parent: FontPopUpButton) { self.parent = parent }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let title = sender.titleOfSelectedItem else { return }
            parent.selection = title
            parent.onSelect?()
        }
    }
}
