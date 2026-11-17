import SwiftUI

/// The watch's one screen: is Ferry sharing, with how many devices, how fast, and
/// a Stop button while it is. Speeds are live only while this is on screen (the
/// phone is asked to send them, at most once a second).
struct WatchStatusView: View {
    @ObservedObject var link: WatchLink
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .foregroundStyle(link.sharing ? .green : .orange)
                    Text(link.sharing ? "Sharing" : "Not sharing")
                        .font(.headline)
                }
                if link.waiting > 0 {
                    Text(link.waiting == 1 ? "1 device waiting" : "\(link.waiting) devices waiting")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Text(link.devices == 1 ? "1 device connected" : "\(link.devices) devices connected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if link.sharing {
                    Text("↓ \(speedText(link.downSpeed))  ↑ \(speedText(link.upSpeed))")
                        .font(.footnote.monospacedDigit())
                    Text("\(bytesText(link.usageToday)) today")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(link.stopping ? "Stopping..." : "Stop sharing") { link.stop() }
                        .tint(.red)
                        .disabled(link.stopping)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .onAppear { link.subscribeLive() }
        .onDisappear { link.unsubscribeLive() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { link.subscribeLive() } else { link.unsubscribeLive() }
        }
    }

    // Small local formatters: the watch app doesn't link the phone's Format.swift.
    private func speedText(_ bps: Double) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f Mbit/s", bps / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0f kbit/s", bps / 1_000) }
        return "0 kbit/s"
    }

    private func bytesText(_ bytes: UInt64) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.0f MB", Double(bytes) / 1_000_000) }
        return "\(bytes) B"
    }
}
