import AppKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "TabManager")

@MainActor
final class TabManager {

    // MARK: - Singleton

    static let shared = TabManager()

    // MARK: - Properties

    private(set) var windowControllers: [TabWindowController] = []

    /// Set to `true` during app termination so that closing windows
    /// does not remove sessions from the store (they should persist
    /// for reattachment on next launch).
    var isTerminating = false

    private init() {}

    // MARK: - Tab Lifecycle

    /// Creates a new empty launcher tab.
    func newTab(in existingWindow: NSWindow? = nil) {
        let controller = TabWindowController()
        windowControllers.append(controller)
        addToTabGroup(controller, in: existingWindow)

        logger.info("New launcher tab opened")
    }

    /// Creates a tab with directory pre-selected (e.g. drag-and-drop).
    func newTab(directory: URL, in existingWindow: NSWindow? = nil) async {
        let controller = TabWindowController()
        windowControllers.append(controller)
        addToTabGroup(controller, in: existingWindow)

        // Auto-launch with the given directory
        await controller.launchClaude(directory: directory, options: ClaudeCodeOptions())
    }

    private func addToTabGroup(_ controller: TabWindowController, in existingWindow: NSWindow?) {
        if let existingWindow {
            guard let newWindow = controller.window else {
                logger.error("New tab has no window")
                return
            }
            existingWindow.addTabbedWindow(newWindow, ordered: .above)
            newWindow.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
        }
    }

    /// Closes a tab, showing a confirmation alert if a session is running.
    func closeTab(_ controller: TabWindowController) {
        controller.window?.performClose(nil)
    }

    // MARK: - Session Reattachment

    func reattachOrphanedSessions() async {
        let existingNames = await TmuxManager.shared.listSessylphSessions()
        let existingSet = Set(existingNames)
        let trackedNames = Set(windowControllers.map(\.session.tmuxSessionName))
        let savedSessions = SessionStore.shared.sessions

        // Build ordered list: saved sessions first (preserves tab order),
        // then any unknown tmux sessions not in the store.
        var orphans: [Session] = []
        var reattachedNames = Set<String>()

        for saved in savedSessions where !trackedNames.contains(saved.tmuxSessionName) {
            guard existingSet.contains(saved.tmuxSessionName) else { continue }
            var session = saved
            session.isRunning = true
            orphans.append(session)
            reattachedNames.insert(saved.tmuxSessionName)
        }

        for name in existingNames where !trackedNames.contains(name) && !reattachedNames.contains(name) {
            // Resolve actual working directory from tmux pane
            let dir: URL
            if let path = await TmuxManager.shared.getPaneCurrentPath(sessionName: name) {
                dir = URL(fileURLWithPath: path)
            } else {
                dir = URL(fileURLWithPath: NSHomeDirectory())
            }
            var session = Session(directory: dir)
            session.tmuxSessionName = name
            session.isRunning = true
            orphans.append(session)
        }

        // Configure all sessions in one batch (best-effort)
        for session in orphans {
            await TmuxManager.shared.configureSession(name: session.tmuxSessionName)
        }

        // Phase 1: Create all windows and position them in the tab group.
        // tmux is NOT attached yet so the pty won't see the intermediate
        // default window size before the tab group layout settles.
        var reattachedControllers: [TabWindowController] = []
        for session in orphans {
            logger.info("Reattaching orphaned tmux session: \(session.tmuxSessionName)")

            let controller = TabWindowController(session: session)
            windowControllers.append(controller)
            reattachedControllers.append(controller)

            let previousControllers = windowControllers.dropLast()
            if let last = previousControllers.last,
               let existingWindow = last.window,
               let newWindow = controller.window
            {
                existingWindow.addTabbedWindow(newWindow, ordered: .above)
                newWindow.makeKeyAndOrderFront(nil)
            } else {
                controller.showWindow(nil)
            }
        }

        // Clean up saved sessions whose tmux sessions no longer exist
        for saved in savedSessions where !existingSet.contains(saved.tmuxSessionName) {
            SessionStore.shared.remove(id: saved.id)
        }

        restoreActiveTab()

        // Phase 2: Now that all windows are at their final size, start
        // tmux attachment. This avoids the visible buffer jump caused by
        // tmux seeing the default window size first, then the real size.
        for controller in reattachedControllers {
            controller.attachToTmux()
        }
    }

    // MARK: - Navigation

    func bringToFront(sessionId: UUID) {
        guard let controller = findController(for: sessionId),
              let window = controller.window
        else {
            logger.warning("No tab found for session \(sessionId)")
            return
        }

        let activate = {
            window.tabGroup?.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
            NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
        }
        if NSApp.isHidden {
            NSApp.unhide(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                activate()
            }
        } else {
            activate()
        }
    }

    /// Finds a controller by session UUID, falling back to tmux session name match
    /// for reattached sessions whose UUID may differ from the hook settings.
    ///
    /// Note: The tmux name fallback uses an 8-character UUID prefix, which has
    /// a theoretical collision risk (~1 in 4 billion). Acceptable for typical
    /// tab counts; reconsider if session volume grows significantly.
    func findController(for sessionId: UUID) -> TabWindowController? {
        // Exact UUID match
        if let controller = windowControllers.first(where: { $0.session.id == sessionId }) {
            return controller
        }
        // Fallback: match by stable sessylph-UUID suffix (handles renamed sessions)
        let suffix = TmuxManager.sessionNameSuffix(for: sessionId)
        return windowControllers.first(where: { $0.session.tmuxSessionName.contains(suffix) })
    }

    // MARK: - Active Tab Persistence

    /// Saves the currently active tab's tmux session name so it can be restored on next launch.
    func saveActiveSessionId() {
        guard let keyWindow = NSApp.keyWindow,
              let controller = windowControllers.first(where: { $0.window === keyWindow })
        else { return }
        UserDefaults.standard.set(controller.session.tmuxSessionName, forKey: Defaults.activeSessionId)
    }

    /// Restores the previously active tab after session reattachment.
    func restoreActiveTab() {
        guard let savedName = UserDefaults.standard.string(forKey: Defaults.activeSessionId),
              let controller = windowControllers.first(where: { $0.session.tmuxSessionName == savedName }),
              let window = controller.window
        else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Bookkeeping

    func windowControllerDidClose(_ controller: TabWindowController) {
        windowControllers.removeAll { $0 === controller }
        if !isTerminating {
            SessionStore.shared.remove(id: controller.session.id)
            HookSettingsGenerator.cleanup(sessionId: controller.session.id.uuidString)

        }
        logger.info("Tab closed (\(self.windowControllers.count) remaining)")
    }
}
