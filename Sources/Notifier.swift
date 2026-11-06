import Foundation
import UserNotifications

/// Local notifications for the things that happen while Ferry is in the background: a
/// device joining or leaving, sharing stopping, a device hitting its data cap, and the
/// battery guard's warning. Nothing here asks for permission on its own — Model asks,
/// contextually, the first time sharing starts and when a notification setting is turned
/// on, never at first launch. Which of these post at all is Model's settings' business.
/// App only; not part of the `swift test` target.
@MainActor
final class Notifier {
    private let center = UNUserNotificationCenter.current()
    private var asked = false

    /// Asks once per launch; iOS itself only shows the prompt once ever.
    func requestAuthorization() {
        guard !asked else { return }
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func deviceJoined(_ name: String) {
        post(id: "join", title: "Device connected", body: "\(name) is now using Ferry.")
    }

    func deviceLeft(_ name: String) {
        post(id: "leave", title: "Device disconnected", body: "\(name) is no longer using Ferry.")
    }

    func sharingStopped(reason: String) {
        post(id: "stopped", title: "Ferry stopped sharing", body: reason)
    }

    func deviceCapped(_ name: String) {
        post(id: "capped", title: "Data cap reached", body: "\(name) used its data for today and is paused until tomorrow.")
    }

    func batteryWarning(percent: Int, threshold: Int) {
        post(id: "battery", title: "Battery at \(percent)%",
             body: "Ferry will stop sharing at \(threshold)% unless you plug in.")
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // The identifier carries the moment, so a repeated event isn't swallowed as a
        // duplicate of the last one.
        let request = UNNotificationRequest(identifier: "\(id)-\(Date().timeIntervalSince1970)",
                                            content: content, trigger: nil)
        center.add(request)
    }
}
