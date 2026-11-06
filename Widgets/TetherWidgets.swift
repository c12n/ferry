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
        TetherLiveActivityWidget()
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

struct TetherLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TetherActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.title2)
                    .foregroundStyle(context.state.isSharing ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.isSharing ? "Ferry is sharing" : "Ferry isn't sharing")
                        .font(.headline)
                    Text("\(context.state.connectedDevices == 1 ? "1 device" : "\(context.state.connectedDevices) devices") · ↓ \(Format.speed(context.state.downSpeed)) ↑ \(Format.speed(context.state.upSpeed))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(Format.bytes(context.state.usageToday)) today")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
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
