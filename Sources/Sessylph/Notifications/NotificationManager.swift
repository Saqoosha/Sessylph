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
                .requestAuthorization(options: [.alert, .sound, .badge])
            logger.info("Notification permission: \(granted ? "granted" : "denied")")
        } catch {
            logger.error("Notification permission request failed: \(error.localizedDescription)")
        }
    }

    func postTaskCompleted(sessionTitle: String, sessionId: String) {
        guard UserDefaults.standard.bool(forKey: Defaults.notifyOnStop) else { return }
        guard !NSApp.isActive else { return }

        let content = UNMutableNotificationContent()
        content.title = "Task Completed"
        content.body = sessionTitle
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

    func postNeedsAttention(sessionTitle: String, sessionId: String, message: String) {
        guard UserDefaults.standard.bool(forKey: Defaults.notifyOnPermission) else { return }
        guard !NSApp.isActive else { return }

        let content = UNMutableNotificationContent()
        content.title = "Needs Attention"
        content.body = "\(sessionTitle): \(message)"
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
                NSApp.activate(ignoringOtherApps: true)
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
