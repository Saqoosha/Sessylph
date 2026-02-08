import AppKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "TabManager")

@MainActor
final class TabManager {

    // MARK: - Singleton

    static let shared = TabManager()

    // MARK: - Properties

    private(set) var windowControllers: [TabWindowController] = []

    private init() {}

    // MARK: - Tab Lifecycle

    /// Creates a new empty launcher tab.
    func newTab(in existingWindow: NSWindow? = nil) {
        let controller = TabWindowController()
        windowControllers.append(controller)

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

        logger.info("New launcher tab opened")
    }

    /// Creates a tab with directory pre-selected (e.g. drag-and-drop).
    func newTab(directory: URL, in existingWindow: NSWindow? = nil) async {
        let controller = TabWindowController()
        windowControllers.append(controller)

        if let existingWindow {
            guard let newWindow = controller.window else {
                logger.error("New tab (directory) has no window")
                return
            }
            existingWindow.addTabbedWindow(newWindow, ordered: .above)
            newWindow.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
        }

        // Auto-launch with the given directory
        await controller.launchClaude(directory: directory, options: ClaudeCodeOptions())
    }

    /// Closes a tab and kills its tmux session.
    func closeTab(_ controller: TabWindowController) async {
        if controller.session.isRunning {
            do {
                try await TmuxManager.shared.killSession(
                    name: controller.session.tmuxSessionName
                )
            } catch {
                logger.warning(
                    "Failed to kill tmux session \(controller.session.tmuxSessionName): \(error.localizedDescription)"
                )
            }
        }

        controller.window?.close()
    }

    // MARK: - Session Reattachment

    func reattachOrphanedSessions() async {
        let existingNames = await TmuxManager.shared.listSessylphSessions()
        let trackedNames = Set(windowControllers.map(\.session.tmuxSessionName))
        let savedSessions = SessionStore.shared.sessions

        for name in existingNames where !trackedNames.contains(name) {
            logger.info("Reattaching orphaned tmux session: \(name)")

            // Try to restore session info from SessionStore
            var session: Session
            if let saved = savedSessions.first(where: { $0.tmuxSessionName == name }) {
                session = saved
            } else {
                session = Session(directory: URL(fileURLWithPath: NSHomeDirectory()))
                session.tmuxSessionName = name
                session.title = name
            }
            session.isRunning = true

            let controller = TabWindowController(session: session)
            windowControllers.append(controller)

            if let first = windowControllers.first, first !== controller,
               let existingWindow = first.window,
               let newWindow = controller.window
            {
                existingWindow.addTabbedWindow(newWindow, ordered: .above)
                newWindow.makeKeyAndOrderFront(nil)
            } else {
                controller.showWindow(nil)
            }
        }

        // Clean up saved sessions whose tmux sessions no longer exist
        let existingSet = Set(existingNames)
        for saved in savedSessions where !existingSet.contains(saved.tmuxSessionName) {
            SessionStore.shared.remove(id: saved.id)
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

        NSApp.activate()
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Finds a controller by session UUID, falling back to tmux session name match
    /// for reattached sessions whose UUID may differ from the hook settings.
    func findController(for sessionId: UUID) -> TabWindowController? {
        // Exact UUID match
        if let controller = windowControllers.first(where: { $0.session.id == sessionId }) {
            return controller
        }
        // Fallback: derive tmux session name from UUID and match
        let tmuxName = TmuxManager.sessionName(for: sessionId)
        return windowControllers.first(where: { $0.session.tmuxSessionName == tmuxName })
    }

    // MARK: - Bookkeeping

    func windowControllerDidClose(_ controller: TabWindowController) {
        windowControllers.removeAll { $0 === controller }
        SessionStore.shared.remove(id: controller.session.id)
        HookSettingsGenerator.cleanup(sessionId: controller.session.id.uuidString)
        logger.info("Tab closed (\(self.windowControllers.count) remaining)")
    }
}
