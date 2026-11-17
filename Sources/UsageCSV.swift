import Foundation

/// The usage history as a CSV file, for the share sheet: one row per device per
/// day. Made to survive spreadsheets: ISO dates, plain integer bytes (no locale
/// number formats, whose decimal commas would break the columns), RFC 4180
/// quoting, a UTF-8 BOM so Excel reads it as UTF-8, and a guard against formula
/// injection: a device name is free text, and a cell starting with `=`, `+`, `-`
/// or `@` would run as a formula when the file is opened, so such a cell gets a
/// leading `'`.
///
/// `rx_bytes` is what the device received (down), `tx_bytes` what it sent (up),
/// the network convention. The pre-1.2 totals come first, dated `before-1.2`, so
/// the file still adds up to the all-time totals.
enum UsageCSV {
    static let header = "date,device_id,device_name,rx_bytes,tx_bytes"

    /// One cell, safe: formula-guarded, then quoted when it needs to be.
    static func escape(_ field: String) -> String {
        var out = field
        if let first = out.first, "=+-@".contains(first) { out = "'" + out }
        if out.contains(",") || out.contains("\"") || out.contains("\n") || out.contains("\r") {
            out = "\"" + out.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return out
    }

    static func document(history: UsageHistory) -> String {
        var lines = [header]
        func row(day: String, peer: String, usage: DeviceUsage) {
            let name = history.names[peer] ?? ""
            lines.append([escape(day), escape(peer), escape(name),
                          String(usage.down), String(usage.up)].joined(separator: ","))
        }
        for peer in history.allPeers {
            if let usage = history.legacy[peer], usage.total > 0 { row(day: "before-1.2", peer: peer, usage: usage) }
        }
        for day in history.recordedDays {
            for peer in history.peers(onDay: day) {
                row(day: day, peer: peer, usage: history.usage(onDay: day, peer: peer))
            }
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }
}
