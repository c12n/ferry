import Foundation
import WidgetKit

/// The widget extension's side of SharingControl (see SharingIntents.swift): the
/// extension can't run the server or the model, so Start and Stop leave a request
/// in the App Group (see ControlRequestStore in WidgetSnapshot.swift) for the app
/// to act on the next time it wakes. While Ferry is alive in the background
/// (sharing, or inside its idle window) its watcher picks the request up within
/// seconds. The Control Center control's intents run in the app instead, where
/// SharingControl does the real thing at once.
enum SharingControl {
    static func start() async -> Bool {
        ControlRequestStore.save(.start)
        WidgetCenter.shared.reloadAllTimelines()
        return false // starting is the app's to confirm; the widget shows the snapshot
    }

    static func stop() async {
        ControlRequestStore.save(.stop)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Whether Ferry is sharing, from the snapshot, and only while its heartbeat
    /// is fresh: a snapshot from a suspended app must not claim Ferry is sharing.
    static func isSharing(now: Date = Date()) -> Bool {
        guard let snapshot = WidgetSnapshotStore.load() else { return false }
        return snapshot.isSharing && now.timeIntervalSince(snapshot.heartbeatAt) < 20
    }
}
