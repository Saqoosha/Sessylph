import AppKit
import SwiftUI

@MainActor
final class SettingsWindow: NSObject, NSToolbarDelegate, NSWindowDelegate {
    private static let minContentSize = NSSize(width: 592, height: 745)
    static let shared = SettingsWindow()

    private let windowController: NSWindowController
    private let tabSelection: SettingsTabSelection

    enum Tab: String, CaseIterable {
        case general = "General"
        case remoteHosts = "Remote Hosts"

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .remoteHosts: "network"
            }
        }

        var toolbarItemIdentifier: NSToolbarItem.Identifier {
            NSToolbarItem.Identifier(rawValue)
        }
    }

    private override init() {
        let selection = SettingsTabSelection()
        self.tabSelection = selection

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 592, height: 745),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.title = Tab.general.rawValue

        let hostingController = NSHostingController(rootView: SettingsContentView(selection: selection))
        hostingController.sizingOptions = []
        window.contentViewController = hostingController

        let wc = NSWindowController(window: window)
        wc.shouldCascadeWindows = false
        self.windowController = wc

        super.init()

        window.delegate = self
        wc.windowFrameAutosaveName = "SettingsWindow"

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = Tab.general.toolbarItemIdentifier
        window.toolbar = toolbar

        if UserDefaults.standard.string(forKey: "NSWindow Frame SettingsWindow") == nil {
            window.center()
        }
    }

    func show(tab: Tab? = nil) {
        if let tab {
            tabSelection.current = tab
            windowController.window?.title = tab.rawValue
            windowController.window?.toolbar?.selectedItemIdentifier = tab.toolbarItemIdentifier
        }
        if let window = windowController.window {
            // Bring window back to visible screen if it's outside all screens
            let isOnScreen = NSScreen.screens.contains { screen in
                window.frame.intersects(screen.visibleFrame)
            }
            if !isOnScreen {
                window.center()
            }
        }
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let contentSize = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let minContent = Self.minContentSize
        if contentSize.width >= minContent.width && contentSize.height >= minContent.height {
            return frameSize
        }
        let clampedContent = NSSize(
            width: max(contentSize.width, minContent.width),
            height: max(contentSize.height, minContent.height)
        )
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: clampedContent)).size
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map(\.toolbarItemIdentifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map(\.toolbarItemIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map(\.toolbarItemIdentifier)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = Tab.allCases.first(where: { $0.toolbarItemIdentifier == itemIdentifier }) else {
            return nil
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.rawValue
        item.image = NSImage(systemSymbolName: tab.icon, accessibilityDescription: tab.rawValue)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        guard let tab = Tab.allCases.first(where: { $0.toolbarItemIdentifier == sender.itemIdentifier }) else {
            return
        }
        tabSelection.current = tab
        windowController.window?.title = tab.rawValue
    }
}

// MARK: - SwiftUI Bridge

@MainActor
final class SettingsTabSelection: ObservableObject {
    @Published var current: SettingsWindow.Tab = .general
}

private struct SettingsContentView: View {
    @ObservedObject var selection: SettingsTabSelection

    var body: some View {
        Group {
            switch selection.current {
            case .general:
                GeneralSettingsView()
            case .remoteHosts:
                RemoteHostsSettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
