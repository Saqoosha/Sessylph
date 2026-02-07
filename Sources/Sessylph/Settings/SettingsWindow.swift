import AppKit
import SwiftUI

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    private var windowController: NSWindowController?

    private init() {}

    func show() {
        if let wc = windowController {
            wc.window?.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = GeneralSettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 500, height: 400))
        window.center()

        let wc = NSWindowController(window: window)
        wc.showWindow(nil)
        self.windowController = wc

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowController = nil
            }
        }
    }
}
