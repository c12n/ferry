import Foundation

/// Byte counts and speeds as text.
enum Format {
    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
    }

    /// Bits per second in the unit a person expects on a speed test.
    static func speed(_ bps: Double) -> String {
        switch bps {
        case 1e6...: return String(format: "%.1f Mbit/s", bps / 1e6)
        case 1e3...: return String(format: "%.0f kbit/s", bps / 1e3)
        default: return String(format: "%.0f bit/s", bps)
        }
    }

    /// How long a guest has left, the way a person says it: "2 h 15 min left". At or past
    /// the date it's "Expired" — Model removes the device then, so it shows only briefly.
    static func remaining(until: Date, now: Date) -> String {
        let seconds = until.timeIntervalSince(now)
        if seconds <= 0 { return "Expired" }
        if seconds < 60 { return "Under a minute left" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min left" }
        let hours = minutes / 60, mins = minutes % 60
        if hours < 24 { return mins > 0 ? "\(hours) h \(mins) min left" : "\(hours) h left" }
        let days = hours / 24, h = hours % 24
        return h > 0 ? "\(days) d \(h) h left" : "\(days) d left"
    }

    private static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// A date and time together, for a last handshake: "Oct 28, 2026 at 9:41 AM".
    static func dateTime(_ date: Date) -> String {
        dateTime.string(from: date)
    }
}
