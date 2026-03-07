import AppKit
import SwiftUI

struct SettingsTabView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            RemoteHostsSettingsView()
                .tabItem {
                    Label("Remote Hosts", systemImage: "network")
                }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

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

        let settingsView = SettingsTabView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 580, height: 520))
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
