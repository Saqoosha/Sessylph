import AppKit
import os.log
import UserNotifications

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - App Lifecycle

    nonisolated(unsafe) private var tabSwitchMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Defaults.register()
        setupMenu()
        installTabSwitchMonitor()
        setupDistributedNotificationListener()
        requestNotificationPermission()

        Task {
            await TmuxManager.shared.configureServerOptions()
            await TabManager.shared.reattachOrphanedSessions()
            if TabManager.shared.windowControllers.isEmpty {
                TabManager.shared.newTab()
            }
        }

        ImagePasteHelper.cleanupOldTempImages()
        logger.info("Sessylph launched")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            TabManager.shared.newTab()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Save sessions BEFORE windows close so the store isn't emptied
        // by windowControllerDidClose removing each session individually.
        TabManager.shared.isTerminating = true
        SessionStore.shared.save()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = tabSwitchMonitor {
            NSEvent.removeMonitor(monitor)
            tabSwitchMonitor = nil
        }
        logger.info("Sessylph terminating")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Open Folder via Drag & Drop / Open With

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filename, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        Task {
            await TabManager.shared.newTab(directory: url, in: NSApp.keyWindow)
        }
        return true
    }

    // MARK: - Menu Bar

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Sessylph", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sessylph", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Open Folder...", action: #selector(openFolder(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w")
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Show All Windows", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Actions

    @objc private func newTab(_ sender: Any?) {
        TabManager.shared.newTab(in: NSApp.keyWindow)
    }

    @objc private func openFolder(_ sender: Any?) {
        // Open Folder also opens a new launcher tab — user picks folder there
        TabManager.shared.newTab(in: NSApp.keyWindow)
    }

    @objc private func closeTab(_ sender: Any?) {
        guard let keyWindow = NSApp.keyWindow,
              let controller = TabManager.shared.windowControllers.first(where: { $0.window === keyWindow })
        else { return }
        Task { await TabManager.shared.closeTab(controller) }
    }

    @objc private func showSettings(_ sender: Any?) {
        SettingsWindow.shared.show()
    }

    // MARK: - Tab Switching (Cmd+1~9)

    private func installTabSwitchMonitor() {
        tabSwitchMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command,
                  let chars = event.charactersIgnoringModifiers,
                  let digit = Int(chars),
                  digit >= 1, digit <= 9
            else { return event }

            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let keyWindow = NSApp.keyWindow,
                      let tabGroup = keyWindow.tabGroup
                else { return false }

                let tabWindows = tabGroup.windows
                let index = digit - 1
                guard index < tabWindows.count else { return false }

                tabWindows[index].makeKeyAndOrderFront(nil)
                return true
            }
            return handled ? nil : event
        }
    }

    // MARK: - Distributed Notification Listener (from sessylph-notifier)

    private nonisolated func setupDistributedNotificationListener() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("sh.saqoo.Sessylph.hookEvent"),
            object: nil,
            queue: nil
        ) { [weak self] notification in
            // Extract Sendable values before crossing isolation boundary
            let sessionId = notification.userInfo?["sessionId"] as? String
            let event = notification.userInfo?["event"] as? String
            let message = notification.userInfo?["message"] as? String
            Task { @MainActor in
                self?.handleHookNotification(sessionId: sessionId, event: event, message: message)
            }
        }
    }

    private func handleHookNotification(sessionId: String?, event: String?, message: String?) {
        guard let sessionId, let event else { return }

        let uuid = UUID(uuidString: sessionId)
        let controller = uuid.flatMap { TabManager.shared.findController(for: $0) }
        let sessionTitle = controller?.session.title ?? "Claude Code"

        switch event {
        case "stop":
            NotificationManager.shared.postTaskCompleted(sessionTitle: sessionTitle, sessionId: sessionId)
        case "notification":
            controller?.markNeedsAttention()
            NotificationManager.shared.postNeedsAttention(sessionTitle: sessionTitle, sessionId: sessionId, message: message ?? "Needs your attention")
        default:
            logger.debug("Unknown hook event: \(event)")
        }
    }

    // MARK: - Notification Permission

    private func requestNotificationPermission() {
        Task {
            await NotificationManager.shared.requestPermission()
        }
    }
}

