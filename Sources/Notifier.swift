import Foundation
import UserNotifications

/// Local notifications for the things that happen while Ferry is in the background: a
/// device joining or leaving, sharing stopping, a device hitting its data cap, and the
/// battery guard's warning. Nothing here asks for permission on its own — Model asks,
/// contextually, the first time sharing starts and when a notification setting is turned
/// on, never at first launch. Which of these post at all is Model's settings' business.
///
/// Since 1.2 it is also the notification center's delegate (set in Model's init, before
/// anything can arrive): a device waiting for approval posts with Approve and Deny
/// actions, and the actions come back here. Both actions need the phone unlocked
/// (approving or denying from a lock screen banner without unlocking would let anyone
/// holding the phone decide who uses its internet), and Deny is destructive. The
/// request's userInfo carries the device's id and its key fingerprint; Model checks
/// the fingerprint, so acting on a stale notification for a device whose key has since
/// changed does nothing.
/// App only; not part of the `swift test` target.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var asked = false

    /// What Model does with an approval decision: the device's id, the fingerprint the
    /// notification carried, and whether it was approved.
    var approvalHandler: ((UUID, String, Bool) -> Void)?

    static let approvalCategory = "ferry.approval"
    static let approveAction = "ferry.approve"
    static let denyAction = "ferry.deny"

    /// The categories, registered at launch (in Model's init): an action only exists
    /// if its category was registered before the notification arrives.
    func registerCategories() {
        let approve = UNNotificationAction(identifier: Self.approveAction, title: "Approve",
                                           options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny",
                                        options: [.authenticationRequired, .destructive])
        let category = UNNotificationCategory(identifier: Self.approvalCategory,
                                              actions: [approve, deny],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard response.notification.request.content.categoryIdentifier == Self.approvalCategory,
              let idText = info["peerID"] as? String, let id = UUID(uuidString: idText),
              let fingerprint = info["fingerprint"] as? String else { return }
        let approved: Bool
        switch response.actionIdentifier {
        case Self.approveAction: approved = true
        case Self.denyAction: approved = false
        default: return // a tap on the notification itself just opens Ferry
        }
        await MainActor.run { self.approvalHandler?(id, fingerprint, approved) }
    }

    /// Ferry's own notifications show while the app is open too: an approval request
    /// arriving while the owner is looking at the phone shouldn't be silent.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

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

    /// A device is waiting for approval, with Approve and Deny on the notification.
    /// Time-sensitive, so it arrives through Focus modes: someone is standing there
    /// with a device that doesn't work until it is answered.
    func approvalRequested(id: UUID, fingerprint: String, name: String) {
        let content = UNMutableNotificationContent()
        content.title = "A device is waiting for approval"
        content.body = "\(name) connected and is waiting. It can't pass traffic until you approve it."
        content.sound = .default
        content.categoryIdentifier = Self.approvalCategory
        content.userInfo = ["peerID": id.uuidString, "fingerprint": fingerprint]
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "approval.\(id.uuidString)", content: content, trigger: nil)
        center.add(request)
    }

    /// The monthly cap is close, or reached. `percent` is 80 or 100.
    func billingAlert(percent: Int, used: UInt64, cap: UInt64) {
        if percent >= 100 {
            post(id: "billing", title: "Monthly data cap reached",
                 body: "Ferry usage this cycle is \(Format.bytes(used)) of \(Format.bytes(cap)). Devices are paused until the next cycle.")
        } else {
            post(id: "billing", title: "Monthly data cap at \(percent)%",
                 body: "Ferry usage this cycle is \(Format.bytes(used)) of \(Format.bytes(cap)).")
        }
    }

    /// Sharing was asked to start but there is no hotspot to share.
    func hotspotNeeded() {
        post(id: "hotspot", title: "Turn on Personal Hotspot",
             body: "Ferry shares your Personal Hotspot. Turn it on in Settings, then start Ferry again.")
    }

    /// The session summary, when sharing stopped while Ferry wasn't on screen.
    func sessionSummary(title: String, body: String) {
        post(id: "summary", title: title, body: body)
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
