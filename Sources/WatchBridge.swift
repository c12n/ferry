import Foundation
import WatchConnectivity

/// The phone side of the watch app (see Watch/). Status goes to the watch as an
/// application context (the latest one wins, delivered when the watch app next
/// looks), and while the watch app is open it can ask for live speeds, which are
/// sent at most once a second and only while the watch is reachable. The watch's
/// one command is Stop, sent as a message with a reply: commands are never queued
/// for later (a Stop delivered an hour late would stop a new session), so there is
/// deliberately no transferUserInfo here. Starting from the watch isn't offered:
/// the watch can't turn on the hotspot or keep Ferry alive, so a Start there would
/// promise what it can't do.
@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    private weak var model: Model?
    private var lastContext: [String: Any] = [:]
    private var subscribed = false
    private var lastLiveSend = ContinuousClock.now - .seconds(1)

    init(model: Model) {
        self.model = model
        super.init()
    }

    /// Called from the app delegate at launch: a session activated late misses the
    /// watch's first messages.
    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Pushes the current status to the watch, when it changed and a watch is paired.
    func publish(sharing: Bool, connectedDevices: Int, downSpeed: Double, upSpeed: Double,
                 usageToday: UInt64, waitingCount: Int) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isWatchAppInstalled else { return }
        let context: [String: Any] = [
            "sharing": sharing,
            "devices": connectedDevices,
            "down": downSpeed,
            "up": upSpeed,
            "usageToday": usageToday,
            "waiting": waitingCount,
            "at": Date().timeIntervalSince1970,
        ]
        // Application contexts are compared as a whole; the timestamp would make
        // every publish look new, so compare without it.
        var comparable = context
        comparable.removeValue(forKey: "at")
        var lastComparable = lastContext
        lastComparable.removeValue(forKey: "at")
        if comparable as NSDictionary != lastComparable as NSDictionary {
            lastContext = context
            try? session.updateApplicationContext(context)
        }
        if subscribed, session.isReachable {
            let now = ContinuousClock.now
            if now - lastLiveSend >= .seconds(1) {
                lastLiveSend = now
                session.sendMessage(context, replyHandler: nil, errorHandler: nil)
            }
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// iOS requires re-activation here, or the session stays dead after the watch changes.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        switch message["cmd"] as? String {
        case "stop":
            Task { @MainActor in
                await self.model?.controller.requestStop()
                let sharing = self.model?.sharing ?? false
                replyHandler(["sharing": sharing])
            }
        case "subscribe":
            Task { @MainActor in
                self.subscribed = true
                replyHandler(["ok": true])
            }
        case "unsubscribe":
            Task { @MainActor in
                self.subscribed = false
                replyHandler(["ok": true])
            }
        default:
            replyHandler(["ok": false])
        }
    }
}
