import AppKit
import os.log
@preconcurrency import GhosttyKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sessylph", category: "GhosttyApp")

@MainActor
final class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?

    private init() {}

    // MARK: - Lifecycle

    func initialize() {
        guard app == nil else { return }

        // Initialize ghostty library
        let result = ghostty_init(0, nil)
        guard result == GHOSTTY_SUCCESS else {
            logger.error("ghostty_init failed with code \(result)")
            return
        }

        guard let config = GhosttyConfig.makeConfig() else {
            logger.error("Failed to create ghostty config")
            return
        }

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = false
        runtimeConfig.wakeup_cb = { userdata in
            guard let userdata else { return }
            let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                app.tick()
            }
        }
        runtimeConfig.action_cb = { ghosttyApp, target, action in
            guard let ghosttyApp else { return false }
            let userdata = ghostty_app_userdata(ghosttyApp)
            guard let userdata else { return false }
            let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
            return app.handleAction(target: target, action: action)
        }
        runtimeConfig.read_clipboard_cb = { userdata, clipboard, state in
            guard let state else { return }
            let content = NSPasteboard.general.string(forType: .string) ?? ""
            content.withCString { cStr in
                ghostty_surface_complete_clipboard_request(state, cStr, state, true)
            }
        }
        runtimeConfig.confirm_read_clipboard_cb = nil
        runtimeConfig.write_clipboard_cb = { userdata, clipboard, content, count, confirm in
            guard let content, count > 0 else { return }
            // content is a ghostty_clipboard_content_s* array
            // For text content, just set the first item's text to pasteboard
            let firstContent = content.pointee
            if let textPtr = firstContent.data {
                let text = String(cString: textPtr)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        runtimeConfig.close_surface_cb = { userdata, processAlive in
            // Surface close requested — the surface view will handle cleanup
        }

        app = ghostty_app_new(&runtimeConfig, config)
        ghostty_config_free(config)

        guard app != nil else {
            logger.error("ghostty_app_new returned nil")
            return
        }

        logger.info("GhosttyApp initialized successfully")
    }

    func shutdown() {
        if let app {
            ghostty_app_free(app)
            self.app = nil
        }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Action Handling

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            return handleSetTitle(target: target, action: action.action.set_title)
        case GHOSTTY_ACTION_OPEN_URL:
            return handleOpenURL(action: action.action.open_url)
        case GHOSTTY_ACTION_CLOSE_WINDOW:
            return handleCloseWindow(target: target)
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            return handleChildExited(target: target, action: action.action.child_exited)
        case GHOSTTY_ACTION_SCROLLBAR:
            return handleScrollbar(target: target, action: action.action.scrollbar)
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            return handleMouseShape(action: action.action.mouse_shape)
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            return true
        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true
        default:
            return false
        }
    }

    private func handleSetTitle(target: ghostty_target_s, action: ghostty_action_set_title_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else { return false }
        let userdata = ghostty_surface_userdata(surface)
        guard let userdata else { return false }
        guard let titlePtr = action.title else { return false }
        let title = String(cString: titlePtr)
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
        view.onTitleChange?(title)
        return true
    }

    private func handleOpenURL(action: ghostty_action_open_url_s) -> Bool {
        guard let urlPtr = action.url else { return false }
        let urlStr = String(cString: urlPtr)
        guard let url = URL(string: urlStr),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    private func handleCloseWindow(target: ghostty_target_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else { return false }
        let userdata = ghostty_surface_userdata(surface)
        guard let userdata else { return false }
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
        view.onProcessExit?()
        return true
    }

    private func handleChildExited(target: ghostty_target_s, action: ghostty_surface_message_childexited_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else { return false }
        let userdata = ghostty_surface_userdata(surface)
        guard let userdata else { return false }
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
        view.onProcessExit?()
        return true
    }

    private func handleScrollbar(target: ghostty_target_s, action: ghostty_action_scrollbar_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else { return false }
        let userdata = ghostty_surface_userdata(surface)
        guard let userdata else { return false }
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
        view.updateScrollbar(total: action.total, offset: action.offset, len: action.len)
        return true
    }

    private func handleMouseShape(action: ghostty_action_mouse_shape_e) -> Bool {
        switch action {
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            NSCursor.iBeam.set()
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            NSCursor.pointingHand.set()
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:
            NSCursor.arrow.set()
        default:
            NSCursor.arrow.set()
        }
        return true
    }
}
