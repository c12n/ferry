import CoreImage.CIFilterBuiltins
import SwiftUI

/// The QR code for the next device, always on the main screen. It's the ready device's config: the
/// first time something connects with it, that device is listed and a new code takes its place.
struct AddDeviceSection: View {
    @ObservedObject var model: Model
    let first: Bool

    var body: some View {
        if let ready = model.wireGuardReady {
            let code = ReadyCode.for(ready) { model.wireGuardConfig(for: ready) }
            Section {
                if let qr = code.qr {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .accessibilityLabel("QR code for the next device")
                        .accessibilityIdentifier("add.qr")
                }
                if let file = code.file {
                    ShareLink(item: file) {
                        Label("Share as a file, for a Mac or a router", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("add.share")
                }
            } header: {
                Text(first ? "Add a device" : "Add another device")
            } footer: {
                Text("Install WireGuard on it, tap + > Create from QR code and scan this. Then edit the tunnel and turn On-Demand on for this iPhone's hotspot only. A travel router imports the file and turns its VPN on.")
                    .accessibilityIdentifier("add.steps")
            }
        }
    }
}

/// Why WireGuard isn't running, with the way out when the saved keys can't be read.
struct WireGuardProblemSection: View {
    @ObservedObject var model: Model

    var body: some View {
        if let problem = model.wireGuardProblem {
            Section {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("wireguard.problem")
                if model.wireGuardNeedsReset {
                    Button("Start over with new keys", role: .destructive) { model.resetWireGuard() }
                        .accessibilityIdentifier("wireguard.reset")
                }
            } header: {
                Text("WireGuard isn't running")
            }
        }
    }
}

/// One device: whether it's connected, what it has used, its cap, its access (permanent,
/// guest, paused), and removing it. Tapping the title renames it.
struct DeviceView: View {
    @ObservedObject var model: Model
    let peer: WireGuardSetup.Peer
    @State private var confirmRemove = false
    @Environment(\.dismiss) private var dismiss

    /// The saved device, so a new name shows at once.
    private var current: WireGuardSetup.Peer { model.wireGuardPeers.first { $0.id == peer.id } ?? peer }
    private var connected: Bool { model.wireGuardConnected.contains(peer.address) }

    private static let capOptions: [(label: String, bytes: UInt64?)] = [
        ("Off", nil), ("500 MB", 500_000_000), ("1 GB", 1_000_000_000),
        ("2 GB", 2_000_000_000), ("5 GB", 5_000_000_000), ("10 GB", 10_000_000_000),
    ]

    private var capBinding: Binding<UInt64?> {
        Binding(get: { current.capBytes }, set: { model.setWireGuardDeviceCap(current, to: $0) })
    }

    private var kindBinding: Binding<WireGuardSetup.Kind> {
        Binding(get: { current.kind }, set: { model.setWireGuardDeviceKind(current, to: $0) })
    }

    /// The Access picker speaks in hours from now (0 is permanent), while the record
    /// keeps a date: the getter finds the closest choice to the time actually left.
    private var accessBinding: Binding<Int> {
        Binding(get: {
            guard let expires = current.expiresAt else { return 0 }
            let left = expires.timeIntervalSinceNow
            return [1, 4, 24].min(by: { abs(Double($0) * 3600 - left) < abs(Double($1) * 3600 - left) }) ?? 24
        }, set: { hours in
            model.setWireGuardDeviceExpiry(current, to: hours == 0 ? nil : Date().addingTimeInterval(Double(hours) * 3600))
        })
    }

    var body: some View {
        List {
            Section {
                if current.paused {
                    Label(current.pauseReason == .cap ? "Paused — data cap reached" : "Paused",
                          systemImage: "pause.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("device.status")
                } else {
                    ConnectedLabel(connected: connected)
                        .accessibilityIdentifier("device.status")
                }
                if let handshake = model.lastHandshake(for: current) {
                    LabeledContent("Last handshake", value: Format.dateTime(handshake))
                }
                if let seen = model.lastSeen(for: current) {
                    LabeledContent("Last seen", value: Format.dateTime(seen))
                }
            }

            Section {
                let today = model.usageToday(for: current)
                LabeledContent("Downloaded today", value: Format.bytes(today.down))
                LabeledContent("Uploaded today", value: Format.bytes(today.up))
                LabeledContent("This session", value: Format.bytes(model.usageSession(for: current).total))
                LabeledContent("All time", value: Format.bytes(model.usageAllTime(for: current).total))
                let speed = model.speed(for: current)
                if speed.down + speed.up > 0 {
                    LabeledContent("Now", value: "↓ \(Format.speed(speed.down))  ↑ \(Format.speed(speed.up))")
                }
            } header: {
                Text("Usage")
            }

            Section {
                Picker("Data cap for today", selection: capBinding) {
                    ForEach(Self.capOptions, id: \.label) { option in
                        Text(option.label).tag(option.bytes)
                    }
                }
                .accessibilityIdentifier("device.cap")
                if let cap = current.capBytes {
                    let used = model.usageToday(for: current).total
                    ProgressView(value: min(1, Double(used) / Double(max(cap, 1)))) {
                        Text("\(Format.bytes(used)) of \(Format.bytes(cap))")
                    }
                    if current.paused, current.pauseReason == .cap {
                        Text("Cap reached — paused until tomorrow, or raise the cap.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Data cap")
            } footer: {
                Text("Counts everything the device uses today, up and down together. At the cap the device pauses until tomorrow.")
            }

            Section {
                Picker("Device type", selection: kindBinding) {
                    ForEach(WireGuardSetup.Kind.allCases, id: \.self) { kind in
                        Label(kind.label, systemImage: kind.symbol).tag(kind)
                    }
                }
                .accessibilityIdentifier("device.kind")
                Picker("Access", selection: accessBinding) {
                    Text("Permanent").tag(0)
                    Text("Guest · 1 hour").tag(1)
                    Text("Guest · 4 hours").tag(4)
                    Text("Guest · 24 hours").tag(24)
                }
                .accessibilityIdentifier("device.access")
                if let expires = current.expiresAt {
                    LabeledContent("Guest until", value: Format.dateTime(expires))
                    Text(Format.remaining(until: expires, now: Date()))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button(current.paused ? "Resume device" : "Pause device") {
                    model.setWireGuardDevicePaused(current, !current.paused)
                }
                .accessibilityIdentifier("device.pause")
            } header: {
                Text("Access")
            } footer: {
                Text("A guest is removed for good when its time is up. A paused device keeps its key and settings but can't pass traffic. Pausing by hand stays until you resume; a data-cap pause lifts tomorrow.")
            }

            Section {
                Button("Remove device", role: .destructive) { confirmRemove = true }
                    .accessibilityIdentifier("device.remove")
            } footer: {
                Text("It can't connect any more. Delete its tunnel in its WireGuard app too.")
            }
        }
        .navigationTitle(Binding(get: { current.name }, set: { model.renameWireGuardDevice(peer.id, to: $0) }))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .confirmationDialog("Remove \(current.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                model.removeWireGuardDevice(peer.id)
                dismiss()
            }
        }
    }
}

/// "Connected" or "Not connected". The text keeps the normal colours, since green text on the
/// grouped background fails the contrast audit. The icon carries the green.
struct ConnectedLabel: View {
    let connected: Bool

    var body: some View {
        Label {
            Text(connected ? "Connected" : "Not connected")
                .foregroundStyle(connected ? .primary : .secondary)
        } icon: {
            Image(systemName: connected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(connected ? .green : .secondary)
        }
    }
}

/// The ready device's QR code and file, made once for each ready device. The main screen redraws
/// every second with the speeds, and making them on each redraw cost a CIContext and a file write
/// every second.
@MainActor
enum ReadyCode {
    private static var made: (id: WireGuardSetup.Peer.ID, qr: UIImage?, file: URL?)?

    static func `for`(_ peer: WireGuardSetup.Peer, config: () -> String) -> (qr: UIImage?, file: URL?) {
        // The system may clear the temporary directory, so a missing file is written again.
        if let made, made.id == peer.id, made.file.map({ FileManager.default.fileExists(atPath: $0.path) }) ?? false {
            return (made.qr, made.file)
        }
        let text = config()
        let code = (id: peer.id, qr: QRCode.image(text), file: ConfigFile.write(text, named: "Tether"))
        made = code
        return (code.qr, code.file)
    }
}

/// The config as a .conf file to share. WireGuard names the tunnel after the file. It holds a
/// private key, so it lives in the temporary directory.
enum ConfigFile {
    static func write(_ config: String, named name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(WireGuardSetup.fileName(for: name))
        return (try? config.write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
    }
}

enum QRCode {
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
