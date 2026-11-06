import ActivityKit
import Foundation
import WidgetKit

/// Keeps the Live Activity and the widget's snapshot in step with the model. Called on the
/// traffic sampler's cadence (every second on screen, slower in the background) and keeps
/// its own throttles, since ActivityKit updates are budgeted by iOS: the widget snapshot is
/// rewritten only when what it shows changes, and a Live Activity update is sent at most
/// every 30 seconds unless the sharing state or the device count changed, which goes at
/// once. Compiled into the app only.
@MainActor
final class SharingActivity {
    private var activity: Activity<TetherActivityAttributes>?
    /// The state the widget snapshot and the last Live Activity update both show.
    private var shown: TetherActivityAttributes.ContentState?
    private var lastActivityPush = Date.distantPast
    private let activityPushInterval: TimeInterval = 30

    /// Called with the model's current state. Starts the Live Activity when sharing starts
    /// and ends it when sharing stops.
    func update(sharing: Bool, connectedDevices: Int, downSpeed: Double, upSpeed: Double,
                usageToday: UInt64, now: Date = Date()) {
        let state = TetherActivityAttributes.ContentState(
            isSharing: sharing, connectedDevices: connectedDevices,
            downSpeed: downSpeed, upSpeed: upSpeed, usageToday: usageToday)
        let changed = state != shown
        if changed {
            shown = state
            WidgetSnapshotStore.save(WidgetSnapshot(
                isSharing: state.isSharing, connectedDevices: state.connectedDevices,
                downSpeed: state.downSpeed, upSpeed: state.upSpeed,
                usageToday: state.usageToday, updatedAt: now))
            WidgetCenter.shared.reloadAllTimelines()
        }
        updateActivity(state: state, changed: changed, now: now)
    }

    private func updateActivity(state: TetherActivityAttributes.ContentState, changed: Bool, now: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if state.isSharing {
            let content = ActivityContent(state: state, staleDate: nil)
            if let activity {
                // A change in who's connected matters at once; a new speed can wait for
                // the throttle.
                guard changed else { return }
                let material = lastPushedState.map {
                    $0.isSharing != state.isSharing || $0.connectedDevices != state.connectedDevices
                } ?? true
                guard material || now.timeIntervalSince(lastActivityPush) >= activityPushInterval else { return }
                lastActivityPush = now
                lastPushedState = state
                Task { await activity.update(content) }
            } else {
                do {
                    activity = try Activity.request(attributes: TetherActivityAttributes(),
                                                    content: content, pushType: nil)
                    lastActivityPush = now
                    lastPushedState = state
                } catch {
                    // Live Activities off for Ferry, or the system's limit reached: the
                    // widget still works, and the next sample tries again only if the
                    // activity is still missing — request failures are cheap to retry
                    // here because `activity` stays nil and state keeps changing hands.
                    activity = nil
                }
            }
        } else if let ending = activity {
            activity = nil
            lastPushedState = nil
            let content = ActivityContent(state: state, staleDate: nil)
            Task { await ending.end(content, dismissalPolicy: .immediate) }
        }
    }

    private var lastPushedState: TetherActivityAttributes.ContentState?
}
