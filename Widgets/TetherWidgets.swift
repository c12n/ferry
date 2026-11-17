import ActivityKit
import SwiftUI
import WidgetKit

/// Ferry's widgets: a home/lock screen widget with the sharing state, and the Live
/// Activity. Both draw from state the app publishes — the widget reads the shared
/// snapshot (WidgetSnapshot.swift, compiled into both targets), the Live Activity gets
/// its content state from the app directly. Nothing here runs the server or the model.
@main
struct TetherWidgets: WidgetBundle {
    var body: some Widget {
        TetherStatusWidget()
        if #available(iOS 18.0, *) {
            TetherLiveActivityWidgetSmall()
            FerryControl()
        } else {
            TetherLiveActivityWidget()
        }
    }
}

// MARK: - Status widget

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: WidgetSnapshot(isSharing: true, connectedDevices: 1,
                                                             downSpeed: 3_200_000, upSpeed: 400_000,
                                                             usageToday: 1_500_000_000, updatedAt: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // The app reloads the timeline on every state change; this half-hour fallback
        // only keeps a stale snapshot from sitting there forever.
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

struct TetherStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TetherStatus", provider: SnapshotProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Ferry")
        .description("Sharing status, connected devices and speeds.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .foregroundStyle(snapshot.isSharing ? .green : .orange)
                    Text(snapshot.isSharing ? "Sharing" : "Not sharing")
                        .font(.headline)
                }
                if snapshot.waitingCount > 0 {
                    Text(snapshot.waitingCount == 1 ? "1 device waiting for approval"
                         : "\(snapshot.waitingCount) devices waiting for approval")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                Text(snapshot.connectedDevices == 1 ? "1 device connected"
                     : "\(snapshot.connectedDevices) devices connected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if snapshot.isSharing {
                    HStack(spacing: 12) {
                        Text("↓ \(Format.speed(snapshot.downSpeed))")
                        Text("↑ \(Format.speed(snapshot.upSpeed))")
                    }
                    .font(.subheadline.monospacedDigit())
                    if family == .systemMedium {
                        Text("\(Format.bytes(snapshot.usageToday)) today")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                // Interactive since 1.2: in the extension these leave a request for
                // the app (see SharingControlWidget.swift); the state shown here is
                // the snapshot's, so a tap is confirmed by the next reload.
                if snapshot.isSharing {
                    Button(intent: StopSharingIntent()) {
                        Label("Stop", systemImage: "stop.circle")
                            .font(.subheadline)
                    }
                    .tint(.red)
                } else {
                    Button(intent: StartSharingIntent()) {
                        Label("Start", systemImage: "play.circle")
                            .font(.subheadline)
                    }
                    .tint(.green)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding()
        } else {
            // No snapshot: the App Group didn't resolve (a re-signed install can lose
            // it) or the app hasn't run yet. Say what to do, nothing more.
            VStack(spacing: 6) {
                Image(systemName: "link").font(.title2)
                Text("Open Ferry")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }
}

// MARK: - Live Activity

/// The Live Activity's Lock Screen content, shared by both variants below. When
/// the session has ended with a summary, the summary is what shows.
struct LiveActivityContent: View {
    let state: TetherActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .font(.title2)
                .foregroundStyle(state.isSharing ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                if let summary = state.summary {
                    Text("Ferry session")
                        .font(.headline)
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(state.isSharing ? "Ferry is sharing" : "Ferry isn't sharing")
                        .font(.headline)
                    Text("\(state.connectedDevices == 1 ? "1 device" : "\(state.connectedDevices) devices") · ↓ \(Format.speed(state.downSpeed)) ↑ \(Format.speed(state.upSpeed))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(Format.bytes(state.usageToday)) today")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding()
    }
}

struct TetherLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TetherActivityAttributes.self) { context in
            LiveActivityContent(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "link").foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.connectedDevices)")
                        .font(.title3.bold())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("↓ \(Format.speed(context.state.downSpeed))  ↑ \(Format.speed(context.state.upSpeed))  ·  \(Format.bytes(context.state.usageToday)) today")
                        .font(.subheadline)
                }
            } compactLeading: {
                Image(systemName: "link").foregroundStyle(.green)
            } compactTrailing: {
                Text("\(context.state.connectedDevices)")
            } minimal: {
                Image(systemName: "link")
            }
        }
    }
}

/// The iOS 18 variant, which also puts the Live Activity in the Apple Watch's
/// Smart Stack (the small supplemental family is the watch's).
@available(iOS 18.0, *)
struct TetherLiveActivityWidgetSmall: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TetherActivityAttributes.self) { context in
            LiveActivityContent(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "link").foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.connectedDevices)")
                        .font(.title3.bold())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("↓ \(Format.speed(context.state.downSpeed))  ↑ \(Format.speed(context.state.upSpeed))  ·  \(Format.bytes(context.state.usageToday)) today")
                        .font(.subheadline)
                }
            } compactLeading: {
                Image(systemName: "link").foregroundStyle(.green)
            } compactTrailing: {
                Text("\(context.state.connectedDevices)")
            } minimal: {
                Image(systemName: "link")
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

// MARK: - Control Center control (iOS 18)

/// Ferry in Control Center and on the Lock Screen: a toggle whose shown state is
/// the App Group snapshot's heartbeat (see FerryControlProvider), and whose action
/// is the sharing intent, which runs in the app and does the real start or stop.
@available(iOS 18.0, *)
struct FerryControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "FerrySharingControl", provider: FerryControlProvider()) { value in
            ControlWidgetToggle(isOn: value, intent: SetSharingIntent()) { isOn in
                Label(isOn ? "Sharing" : "Ferry", systemImage: "link")
            }
        }
        .displayName("Ferry")
        .description("Start or stop Ferry sharing.")
    }
}

@available(iOS 18.0, *)
struct FerryControlProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        SharingControl.isSharing()
    }
}
