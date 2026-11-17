import Charts
import SwiftUI

/// Per-day usage history: a chart of the last 30 days and the days themselves,
/// from the per-day history (see UsageHistory.swift). Days are plotted at local
/// noon, so a daylight-saving change can't push a bar onto the wrong day.
struct UsageHistoryView: View {
    @ObservedObject var model: Model
    @State private var csvFile: URL?

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The last 30 recorded days, oldest first.
    private var days: [String] {
        Array(model.history.recordedDays.suffix(30))
    }

    private func name(for peerID: String) -> String {
        if let peer = model.wireGuardPeers.first(where: { $0.id.uuidString == peerID }) { return peer.name }
        return model.history.names[peerID] ?? "Device"
    }

    /// The five devices with the most usage in the window; the rest are "Other".
    private var topPeers: [String] {
        let totals = model.history.allPeers.map { (id: $0, total: model.history.allTime(peer: $0).total) }
        return totals.sorted { $0.total > $1.total }.prefix(5).map(\.id)
    }

    private struct Bar: Identifiable {
        let day: Date
        let device: String
        let bytes: UInt64
        var id: String { "\(day.timeIntervalSince1970)-\(device)" }
    }

    private var bars: [Bar] {
        let top = topPeers
        var out: [Bar] = []
        for day in days {
            guard let date = Self.dayFormatter.date(from: day) else { continue }
            let noon = date.addingTimeInterval(12 * 3600)
            var other: UInt64 = 0
            for peer in model.history.peers(onDay: day) {
                let used = model.history.usage(onDay: day, peer: peer).total
                guard used > 0 else { continue }
                if top.contains(peer) {
                    out.append(Bar(day: noon, device: name(for: peer), bytes: used))
                } else {
                    other += used
                }
            }
            if other > 0 { out.append(Bar(day: noon, device: "Other", bytes: other)) }
        }
        return out
    }

    var body: some View {
        List {
            if model.history.isEmpty {
                Section {
                    Text("No usage recorded yet. Per-day history starts with Ferry 1.2; earlier usage is on each device's screen as all-time totals.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Chart(bars) { bar in
                        BarMark(x: .value("Day", bar.day, unit: .day),
                                y: .value("Usage", bar.bytes))
                            .foregroundStyle(by: .value("Device", bar.device))
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let bytes = value.as(UInt64.self) {
                                    Text(Format.bytes(bytes))
                                }
                            }
                        }
                    }
                    .frame(height: 180)
                    .accessibilityLabel("Usage per day for the last 30 days")
                } header: {
                    Text("Last 30 days")
                }

                if let csvFile {
                    Section {
                        ShareLink(item: csvFile) {
                            Label("Export as CSV", systemImage: "tablecells")
                        }
                        .accessibilityIdentifier("history.csv")
                    } footer: {
                        Text("One row per device per day: date, device, bytes received and sent. Opens in any spreadsheet.")
                    }
                }

                ForEach(days.reversed(), id: \.self) { day in
                    Section {
                        ForEach(model.history.peers(onDay: day), id: \.self) { peer in
                            let used = model.history.usage(onDay: day, peer: peer)
                            if used.total > 0 {
                                LabeledContent(name(for: peer), value: Format.bytes(used.total))
                            }
                        }
                    } header: {
                        Text(dayTitle(day))
                    }
                }
            }
        }
        .navigationTitle("Usage history")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            csvFile = Self.writeCSV(history: model.history)
        }
    }

    private func dayTitle(_ stamp: String) -> String {
        guard let date = Self.dayFormatter.date(from: stamp) else { return stamp }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    /// The CSV is written off the main thread's way once, when the screen opens:
    /// it can cover over a year of days.
    private static func writeCSV(history: UsageHistory) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ferry-usage.csv")
        do {
            try UsageCSV.document(history: history).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
