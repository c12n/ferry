import Foundation

/// One sharing session, as a saved record: when it started, when it was last seen
/// alive, what each device used, and how it ended. Updated on every usage flush
/// while sharing runs, so if Ferry is killed (jetsam, a crash, the phone dying)
/// the record survives, and the next launch can close it out and still post the
/// summary. Nothing about it depends on a timer firing.
///
/// Devices are keyed by peer UUID, like the usage history. "Devices" in the
/// summary means devices that actually moved data, not ones that only
/// handshaked, and never ones still waiting for approval.
struct SessionRecord: Codable, Equatable {
    var startedAt: Date
    var lastHeartbeatAt: Date
    /// This session's usage per device, peer UUID -> usage.
    var perPeer: [String: DeviceUsage] = [:]
    /// The most devices connected at once.
    var peakConcurrent: Int = 0
    var endedAt: Date?
    var endReason: String?

    var isOpen: Bool { endedAt == nil }

    var devicesWithTraffic: Int { perPeer.values.count { $0.total > 0 } }

    var totalUsage: DeviceUsage { perPeer.values.reduce(DeviceUsage()) { $0 + $1 } }

    /// The session's length: to its end, or to the last heartbeat for one that
    /// never got to close.
    func duration(now: Date) -> TimeInterval {
        (endedAt ?? lastHeartbeatAt).timeIntervalSince(startedAt)
    }

    /// A record for a session that was never closed and hasn't beaten in a day
    /// is dropped quietly: the summary for it would arrive far too late to mean
    /// anything.
    func isStale(now: Date) -> Bool {
        isOpen && now.timeIntervalSince(lastHeartbeatAt) > 24 * 3600
    }

    /// The same record, closed at its last heartbeat: how an unexpectedly ended
    /// session is settled at the next launch.
    func closedUnexpectedly() -> SessionRecord {
        var closed = self
        closed.endedAt = lastHeartbeatAt
        closed.endReason = "unexpected"
        return closed
    }
}

/// What the session summary says, and whether there is one at all. Pure, so
/// `swift test` covers it.
enum SessionSummary {
    /// Sessions under a minute with no data aren't worth a notification.
    static func shouldPost(_ record: SessionRecord, now: Date) -> Bool {
        record.duration(now: now) >= 60 && record.totalUsage.total > 0
    }

    static func title(_ record: SessionRecord) -> String {
        record.endReason == "unexpected" ? "Ferry stopped unexpectedly" : "Ferry session summary"
    }

    /// "Shared for 2 h 5 min with 3 devices. 1.24 GB used." The unexpected form
    /// says when it stopped, since that's the part the person doesn't know.
    static func body(_ record: SessionRecord, now: Date) -> String {
        let devices = record.devicesWithTraffic
        let deviceText = devices == 1 ? "1 device" : "\(devices) devices"
        var text = "Shared for \(durationText(record.duration(now: now))) with \(deviceText). "
            + "\(Format.bytes(record.totalUsage.total)) used."
        if record.endReason == "unexpected" {
            text += " It stopped at \(timeText(record.lastHeartbeatAt))."
        }
        return text
    }

    /// A duration the way a person says it: "45 min", "2 h 5 min", "1 d 3 h".
    static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        let hours = minutes / 60, mins = minutes % 60
        if hours < 24 { return mins > 0 ? "\(hours) h \(mins) min" : "\(hours) h" }
        let days = hours / 24, h = hours % 24
        return h > 0 ? "\(days) d \(h) h" : "\(days) d"
    }

    private static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static func timeText(_ date: Date) -> String { timeOnly.string(from: date) }
}
