import Foundation

/// The app side of SharingControl (see SharingIntents.swift): the real thing, going
/// through the sharing controller. Compiled into the app only; the widget extension
/// has its own SharingControl that leaves a request instead.
@MainActor
enum SharingControl {
    /// Starts sharing if it isn't already, and says whether it is sharing when the
    /// dust settles. Starting takes a moment: the hotspot has to be there and the
    /// server has to bind. With no hotspot, the just-started keep-alive is stopped
    /// again (a Start that leaves Ferry running with nothing to share would drain
    /// the battery for nothing) and the person is told to turn the hotspot on.
    static func start() async -> Bool {
        let model = Model.shared
        if model.sharing { return true }
        let controller = model.controller
        let started = await controller.requestStart()
        if started { return true }
        model.stopKeepAliveAfterFailedStart()
        if !model.running {
            model.notifyHotspotNeeded()
        }
        return false
    }

    static func stop() async {
        await Model.shared.controller.requestStop()
    }

    /// Whether Ferry is sharing, for the control's shown state. Only as fresh as
    /// the snapshot's heartbeat: an app that stopped writing isn't sharing.
    static func isSharing(now: Date = Date()) -> Bool {
        guard let snapshot = WidgetSnapshotStore.load() else { return false }
        return snapshot.isSharing && now.timeIntervalSince(snapshot.heartbeatAt) < 20
    }
}
