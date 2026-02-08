import AppKit
import UserNotifications
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "Notifications")

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge, .provisional])
            logger.info("Notification permission: \(granted ? "granted" : "denied")")
        } catch {
            logger.error("Notification permission request failed: \(error.localizedDescription)")
        }
    }

    func postTaskCompleted(sessionTitle: String, sessionId: String) {
        guard UserDefaults.standard.bool(forKey: Defaults.notifyOnStop) else { return }
        post(title: "✅ Task Completed", body: sessionTitle, sessionId: sessionId)
    }

    func postNeedsAttention(sessionTitle: String, sessionId: String, message: String) {
        guard UserDefaults.standard.bool(forKey: Defaults.notifyOnPermission) else { return }
        post(title: "⚠️ Needs Attention", body: "\(sessionTitle): \(message)", sessionId: sessionId)
    }

    // MARK: - Private

    private func post(title: String, body: String, sessionId: String) {
        guard !isSessionFrontmost(sessionId: sessionId) else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionId": sessionId]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    private func isSessionFrontmost(sessionId: String) -> Bool {
        guard NSApp.isActive,
              let uuid = UUID(uuidString: sessionId),
              let controller = TabManager.shared.findController(for: uuid)
        else { return false }
        return controller.window?.isKeyWindow == true
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let sessionId = userInfo["sessionId"] as? String,
           let uuid = UUID(uuidString: sessionId)
        {
            Task { @MainActor in
                TabManager.shared.bringToFront(sessionId: uuid)
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
