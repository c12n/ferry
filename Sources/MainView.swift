import Charts
import SwiftUI

struct MainView: View {
    @ObservedObject private var model = Model.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusCard(model: model)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if let warning = model.expiryWarning {
                    Section {
                        Label {
                            Text(warning)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("app.expiry")
                    }
                }

                // Above the QR code, so a reason it doesn't work and the way out are both here.
                WireGuardProblemSection(model: model)

                if model.batteryBlocked {
                    Section {
                        Label {
                            Text("Sharing stopped to save battery. Plug in, or resume — the guard stays off until the battery recovers.")
                        } icon: {
                            Image(systemName: "battery.25").foregroundStyle(.orange)
                        }
                        Button("Resume sharing") { model.resumeAfterBatteryGuard() }
                            .accessibilityIdentifier("battery.resume")
                    } header: {
                        Text("Battery guard")
                    }
                }

                if model.sharing {
                    Section {
                        SpeedRow(down: model.downSpeed, up: model.upSpeed)
                    }
                }

                if !model.wireGuardPeers.isEmpty {
                    Section("Devices") {
                        ForEach(model.wireGuardPeers) { peer in
                            NavigationLink { DeviceView(model: model, peer: peer) } label: {
                                // A plain row: LabeledContent with a Label on its right grows several
                                // rows tall inside a NavigationLink on iOS 27.
                                HStack(spacing: 12) {
                                    Image(systemName: peer.kind.symbol)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(peer.name)
                                        let caption = deviceCaption(peer, model: model)
                                        if !caption.isEmpty {
                                            if peer.paused {
                                                Text(caption)
                                                    .font(.caption)
                                                    .foregroundStyle(.orange)
                                            } else {
                                                Text(caption)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    Spacer()
                                    if peer.paused {
                                        Label("Paused", systemImage: "pause.circle.fill")
                                            .font(.subheadline)
                                            .foregroundStyle(.orange)
                                    } else {
                                        ConnectedLabel(connected: model.wireGuardConnected.contains(peer.address))
                                            .font(.subheadline)
                                    }
                                }
                            }
                            .accessibilityIdentifier("device.\(peer.name)")
                        }
                    }

                    Section("Usage") {
                        LabeledContent("Today", value: Format.bytes(model.usage.todayTotal().total))
                        LabeledContent("This session", value: Format.bytes(model.usage.sessionTotal().total))
                    }
                }

                if model.speedHistory.count > 1 {
                    Section("Speed history") {
                        SpeedHistoryChart(samples: model.speedHistory)
                    }
                }

                AddDeviceSection(model: model, first: model.wireGuardPeers.isEmpty)

                Section {
                    Picker("Idle timeout", selection: $model.idleTimeoutMinutes) {
                        Text("5 minutes").tag(5)
                        Text("10 minutes").tag(10)
                        Text("30 minutes").tag(30)
                        Text("Never").tag(0)
                    }
                    .accessibilityIdentifier("settings.idleTimeout")
                    Picker("Battery guard", selection: $model.batteryThresholdPercent) {
                        Text("Off").tag(0)
                        ForEach(BatteryGuard.levels, id: \.self) { level in
                            Text("Stop at \(level)%").tag(level)
                        }
                    }
                    .accessibilityIdentifier("settings.batteryGuard")
                    Toggle("A device connects", isOn: $model.notifyJoins)
                    Toggle("A device disconnects", isOn: $model.notifyLeaves)
                    Toggle("Sharing stops", isOn: $model.notifyStopped)
                    NavigationLink {
                        DiagnosticsView(model: model)
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                    .accessibilityIdentifier("settings.diagnostics")
                } header: {
                    Text("Settings")
                } footer: {
                    Text("Idle timeout: how long Tether keeps waiting after the hotspot goes before iOS suspends it. Battery guard stops sharing at the chosen level while on battery.")
                }
            }
            // The status card says what this screen is, so the root drops the big title. It's still set,
            // because the screens pushed from here use it for their back button.
            .navigationTitle("Tether")
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// The small line under a device's name: its state, its guest time, what it used today
/// and its speed, as much of that as applies.
private func deviceCaption(_ peer: WireGuardSetup.Peer, model: Model) -> String {
    if peer.paused {
        return peer.pauseReason == .cap ? "Paused · data cap reached" : "Paused"
    }
    var parts: [String] = []
    if let expires = peer.expiresAt {
        parts.append("Guest · \(Format.remaining(until: expires, now: Date()))")
    }
    let today = model.usageToday(for: peer).total
    if today > 0 { parts.append("\(Format.bytes(today)) today") }
    let speed = model.speed(for: peer)
    if speed.down + speed.up > 0 {
        parts.append("↓ \(Format.speed(speed.down)) ↑ \(Format.speed(speed.up))")
    }
    return parts.joined(separator: " · ")
}

/// The session's speeds as a graph, down in the accent colour and up in the upload
/// colour — the same colours as everywhere else speeds show.
struct SpeedHistoryChart: View {
    let samples: [Model.SpeedSample]

    /// At most 300 points, so a second of samples an hour long stays cheap to draw.
    private var points: [Model.SpeedSample] {
        let step = max(1, samples.count / 300)
        return samples.enumerated().filter { $0.offset % step == 0 }.map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(points) { sample in
                    LineMark(x: .value("Time", sample.date),
                             y: .value("Speed", sample.down / 1e6),
                             series: .value("Direction", "Down"))
                        .foregroundStyle(Direction.download)
                    LineMark(x: .value("Time", sample.date),
                             y: .value("Speed", sample.up / 1e6),
                             series: .value("Direction", "Up"))
                        .foregroundStyle(Direction.upload)
                }
            }
            .chartYAxisLabel("Mbit/s")
            .frame(height: 120)
            .accessibilityLabel("Speed history graph for this session")
            HStack(spacing: 16) {
                Label("Down", systemImage: "arrow.down").foregroundStyle(Direction.download)
                Label("Up", systemImage: "arrow.up").foregroundStyle(Direction.upload)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

/// How fast data moves right now, down and up.
struct SpeedRow: View {
    let down: Double
    let up: Double

    var body: some View {
        HStack(spacing: 16) {
            Text("\(Image(systemName: "arrow.down")) \(Format.speed(down))")
                .foregroundStyle(Direction.download)
            Text("\(Image(systemName: "arrow.up")) \(Format.speed(up))")
                .foregroundStyle(Direction.upload)
        }
        .font(.headline.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Download \(Format.speed(down)), upload \(Format.speed(up))")
        .accessibilityIdentifier("traffic.speeds")
    }
}

/// Download and upload colours, the same in every speed and card. Orange and red stay for warnings.
enum Direction {
    static let download = Color.accentColor
    /// Darker than the system teal in light mode and lighter in dark mode, so the upload speed
    /// keeps a 4.5:1 contrast on the card in both.
    static let upload = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.35, green: 0.85, blue: 0.80, alpha: 1)
            : UIColor(red: 0.0, green: 0.47, blue: 0.48, alpha: 1)
    })
}

/// The one-second answer: is this phone sharing right now, and is anyone using it. Turning off
/// Personal Hotspot is how sharing stops, so it says that instead of having a switch.
struct StatusCard: View {
    @ObservedObject var model: Model

    private var tint: Color { model.sharing ? .green : .orange }
    private var sharing: Bool { model.sharing }
    /// Grows with the text size, like the title under it.
    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 44

    /// Sharing gets the brand's two colours, softly. Waiting stays orange, the warning colour.
    private var background: some ShapeStyle {
        sharing
            ? AnyShapeStyle(LinearGradient(colors: [Direction.download.opacity(0.22), Direction.upload.opacity(0.18)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
            : AnyShapeStyle(tint.opacity(0.15))
    }

    /// Opens Settings at its main screen, where Personal Hotspot is near the top. Nothing goes
    /// straight to the Personal Hotspot page any more: on iOS 27, App-prefs:INTERNET_TETHERING and
    /// every App-prefs spelling of it open Settings > Apps, and iOS refuses prefs:root= links from apps.
    static func openHotspotSettings() {
        UIApplication.shared.open(URL(string: "App-prefs:")!)
    }

    private var headline: String {
        switch model.wireGuardConnected.count {
        case 0: return "Hotspot is on, no device is using Tether yet"
        case 1: return "Sharing with 1 device"
        case let n: return "Sharing with \(n) devices"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.tint)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(tint)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
                        .offset(x: 6, y: 4)
                }
                .accessibilityHidden(true)
            Text(sharing ? "Sharing" : model.running ? "Tether can't share yet" : "Turn on Personal Hotspot")
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("status.title")
            if sharing {
                Text(headline)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("status.headline")
                Text("To stop, turn off Personal Hotspot.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("status.stopHint")
            } else if model.running {
                // The WireGuard section under the card says why, and what to do.
                Text("Personal Hotspot is on, but WireGuard isn't running.")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("status.headline")
            } else {
                Button(action: Self.openHotspotSettings) {
                    // The tint fails contrast on the orange card, so the text is the label colour and the underline
                    // says "tap". Color.primary, because inside a button `.primary` is the button's tint.
                    Text("Settings > Personal Hotspot > Allow Others to Join")
                        .font(.subheadline)
                        .underline()
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.primary)
                }
                .accessibilityIdentifier("status.hotspotPath")
                .accessibilityHint("Opens Settings")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal)
        .background(background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.smooth, value: sharing)
    }
}

#Preview("Sharing") {
    let model = Model()
    model.running = true
    model.wireGuardConnected = ["10.7.0.2"]
    return StatusCard(model: model).padding()
}

#Preview("Hotspot on, no device") {
    let model = Model()
    model.running = true
    return StatusCard(model: model).padding()
}

#Preview("Waiting") {
    StatusCard(model: Model()).padding()
}

#Preview("Main screen") {
    MainView()
}
