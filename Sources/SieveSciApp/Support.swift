import AppKit
import Foundation
import SieveSciCore
import UserNotifications

/// macOS notifications for job events, finished turns and permission prompts. Only posted while
/// SieveSci is not the active app (in the foreground the transcript already shows them).
@MainActor
final class Notifier {
    private var authorized = false

    /// UNUserNotificationCenter needs a bundled app; a bare `swift run` binary has no bundle id.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            Task { @MainActor in self.authorized = ok }
        }
    }

    func post(title: String, body: String, id: String) {
        guard !NSApp.isActive else { return }
        guard available, authorized else {
            NSApp.requestUserAttention(.informationalRequest)
            return
        }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}
