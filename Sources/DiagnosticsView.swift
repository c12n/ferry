import Network
import SwiftUI
import UIKit

/// The reachability of the phone's own network, from NWPathMonitor: satisfied means some
/// interface (cellular counts) can reach the internet.
@MainActor
final class PathProbe: ObservableObject {
    @Published private(set) var satisfied: Bool?
    private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.satisfied = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "tether.diagnostics.path"))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}

/// One line of the Diagnostics screen: what's checked, how it stands, and the detail.
private struct Check {
    enum Level { case ok, warning, failed }
    var title: String
    var level: Level
    var detail: String

    var symbol: String {
        switch level {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch level {
        case .ok: return .green
        case .warning: return .orange
        case .failed: return .red
        }
    }
}

/// Everything that has to be true for Tether to share, checked live, with a plain-text
/// summary to share when something is wrong. The only network call it makes is the
/// internet probe, to Apple's own connectivity-check page.
struct DiagnosticsView: View {
    @ObservedObject var model: Model
    @StateObject private var path = PathProbe()
    /// The internet probe's result: nil until run, then what Apple's page answered.
    @State private var probe: Bool?
    @State private var probing = false

    private var checks: [Check] {
        var out: [Check] = []
        // The hotspot interface: present only while Personal Hotspot is on.
        if let address = model.boundHost {
            out.append(Check(title: "Personal Hotspot", level: .ok, detail: "On, this iPhone is \(address)"))
        } else if Interfaces.hotspotAddress() != nil {
            out.append(Check(title: "Personal Hotspot", level: .warning, detail: "On, but Tether hasn't bound to it yet"))
        } else {
            out.append(Check(title: "Personal Hotspot", level: .failed, detail: "Off — turn on Personal Hotspot and allow others to join"))
        }
        // The WireGuard server.
        if let problem = model.wireGuardProblem {
            out.append(Check(title: "WireGuard server", level: .failed, detail: problem))
        } else if model.wireGuardRunning {
            out.append(Check(title: "WireGuard server", level: .ok,
                             detail: "Running on port \(WireGuardSetup.port), \(model.wireGuardPeers.count) devices paired"))
        } else {
            out.append(Check(title: "WireGuard server", level: .warning, detail: "Not running — it starts with the hotspot"))
        }
        // Devices.
        let connected = model.wireGuardConnected.count
        out.append(Check(title: "Devices", level: connected > 0 ? .ok : .warning,
                         detail: "\(connected) of \(model.wireGuardPeers.count) paired devices connected"))
        // Internet from the phone itself.
        switch (path.satisfied, probe) {
        case (_, .some(true)):
            out.append(Check(title: "Internet", level: .ok, detail: "Apple's connectivity check answered"))
        case (_, .some(false)):
            out.append(Check(title: "Internet", level: .failed, detail: "Apple's connectivity check didn't answer"))
        case (.some(true), nil):
            out.append(Check(title: "Internet", level: .ok, detail: "Network path is up — run the check to be sure"))
        case (.some(false), nil):
            out.append(Check(title: "Internet", level: .failed, detail: "No network path — the phone itself is offline"))
        default:
            out.append(Check(title: "Internet", level: .warning, detail: "Checking…"))
        }
        // Keep-alive.
        out.append(model.keepAliveActive
            ? Check(title: "Keep-alive", level: .ok, detail: "The silent sound is playing, so iOS keeps Tether running")
            : Check(title: "Keep-alive", level: .warning, detail: "Not playing — Tether may be suspended when the hotspot is idle"))
        // Battery.
        let device = UIDevice.current
        if device.batteryLevel >= 0 {
            let percent = Int((device.batteryLevel * 100).rounded())
            let charging = device.batteryState == .charging || device.batteryState == .full
            var detail = "\(percent)%\(charging ? ", charging" : "")"
            if model.batteryThresholdPercent > 0 {
                detail += " · guard stops sharing at \(model.batteryThresholdPercent)%"
            }
            out.append(Check(title: "Battery", level: percent <= 20 && !charging ? .warning : .ok, detail: detail))
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            out.append(Check(title: "Temperature", level: .warning, detail: "The iPhone is hot — sharing may slow down"))
        default:
            out.append(Check(title: "Temperature", level: .ok, detail: "Normal"))
        }
        // This build's expiry.
        if let expires = model.expires {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                       to: Calendar.current.startOfDay(for: expires)).day ?? 0
            out.append(Check(title: "This build", level: days <= 3 ? .warning : .ok,
                             detail: "Stops opening \(Format.dateTime(expires)) (\(days) days left)"))
        } else {
            out.append(Check(title: "This build", level: .ok, detail: "No profile expiry found"))
        }
        return out
    }

    /// The same checks as plain text, for the share sheet.
    private var summary: String {
        let lines = checks.map { check in
            let mark = switch check.level { case .ok: "OK"; case .warning: "WARNING"; case .failed: "FAILED" }
            return "[\(mark)] \(check.title): \(check.detail)"
        }
        return (["Tether diagnostics — \(Format.dateTime(Date()))",
                 "Sharing: \(model.sharing ? "yes" : "no") · \(model.wireGuardConnected.count) devices connected",
                 "Today: \(Format.bytes(model.usage.todayTotal().total)) · Session: \(Format.bytes(model.usage.sessionTotal().total))"]
            + lines).joined(separator: "\n")
    }

    var body: some View {
        List {
            Section {
                ForEach(checks, id: \.title) { check in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                            Text(check.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: check.symbol).foregroundStyle(check.color)
                    }
                }
            }
            Section {
                Button {
                    Task { await runProbe() }
                } label: {
                    Label(probing ? "Checking…" : "Check internet now", systemImage: "network")
                }
                .disabled(probing)
                ShareLink(item: summary) {
                    Label("Share diagnostics", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("The internet check asks Apple's connectivity page (www.apple.com/library/test/success.html) — nothing is sent but the request itself.")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            path.start()
            UIDevice.current.isBatteryMonitoringEnabled = true // the battery row reads a level
        }
        .onDisappear { path.stop() }
    }

    /// Apple's captive-portal check page answers a page whose body is "Success".
    private func runProbe() async {
        probing = true
        defer { probing = false }
        guard let url = URL(string: "https://www.apple.com/library/test/success.html") else { probe = false; return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            probe = String(data: data, encoding: .utf8)?.contains("Success") ?? false
        } catch {
            probe = false
        }
    }
}
