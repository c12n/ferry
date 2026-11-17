import SwiftUI
import WatchConnectivity

/// Ferry on the watch: the sharing state, the speeds while the app is open, and a
/// Stop button. Status arrives as an application context from the phone (the
/// latest one wins), and while this app is in the foreground it subscribes to live
/// updates. Stop is a message with a reply, never a queued transfer: a Stop
/// delivered late would stop a different session. There is no Start: the watch
/// can't turn on the hotspot or keep Ferry alive, so a Start here would promise
/// what it can't do.
@main
struct FerryWatchApp: App {
    @StateObject private var link = WatchLink()

    var body: some Scene {
        WindowGroup {
            WatchStatusView(link: link)
        }
    }
}

@MainActor
final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published var sharing = false
    @Published var devices = 0
    @Published var downSpeed = 0.0
    @Published var upSpeed = 0.0
    @Published var usageToday: UInt64 = 0
    @Published var waiting = 0
    @Published var stopping = false

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        let context = session.receivedApplicationContext
        if !context.isEmpty { apply(context) }
    }

    func subscribeLive() {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["cmd": "subscribe"], replyHandler: nil, errorHandler: nil)
    }

    func unsubscribeLive() {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["cmd": "unsubscribe"], replyHandler: nil, errorHandler: nil)
    }

    func stop() {
        guard WCSession.default.isReachable, !stopping else { return }
        stopping = true
        WCSession.default.sendMessage(["cmd": "stop"], replyHandler: { [weak self] reply in
            Task { @MainActor in
                self?.stopping = false
                if let sharing = reply["sharing"] as? Bool { self?.sharing = sharing }
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in self?.stopping = false }
        })
    }

    private func apply(_ context: [String: Any]) {
        sharing = context["sharing"] as? Bool ?? sharing
        devices = context["devices"] as? Int ?? devices
        downSpeed = context["down"] as? Double ?? downSpeed
        upSpeed = context["up"] as? Double ?? upSpeed
        usageToday = (context["usageToday"] as? NSNumber)?.uint64Value ?? usageToday
        waiting = context["waiting"] as? Int ?? waiting
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.apply(message) }
    }
}
