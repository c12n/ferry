import Foundation

/// Per-device usage by day: the record the history screen, the billing cycle and
/// the CSV export all read. Devices are keyed by their permanent peer UUID (see
/// Model), never by name, key or tunnel address, which all change or get reused.
///
/// Rows for a removed device are kept, with its last known name, so the days still
/// add up to the billing total and an export still explains itself. Rows older
/// than the pruning window (about 400 days) are folded into `legacy`, so all-time
/// totals never shrink when old days go.
///
/// Foundation only, so `swift test` covers it. Where it is kept is
/// `UsageHistoryStore` below: a JSON file written atomically in the app's private
/// container. Never the App Group: an app suspended while holding a shared file
/// open is killed by iOS (0xdead10cc), and Ferry is suspended within seconds of
/// sharing stopping, which is exactly when the final save happens. Widgets and
/// the control read the small snapshot (WidgetSnapshot) instead, never this.
struct UsageHistory: Codable, Equatable {
    /// Day (`yyyy-MM-dd`, local) -> peer UUID -> that day's usage.
    var days: [String: [String: DeviceUsage]] = [:]
    /// Usage from before per-day records: the pre-1.2 totals a migration brings
    /// over, and old days the pruning folded in. Counted in all-time, in no day.
    var legacy: [String: DeviceUsage] = [:]
    /// Each device's last known name, so a removed device's rows still read well.
    var names: [String: String] = [:]

    var isEmpty: Bool { days.isEmpty && legacy.isEmpty }

    /// Adds a delta to a day, by key: a day key can be written again after time
    /// zone travel moves the local date backwards, so writes never assume the
    /// days only grow.
    mutating func add(_ delta: DeviceUsage, peer: String, name: String?, day: String) {
        guard delta.total > 0 else { return }
        days[day, default: [:]][peer, default: DeviceUsage()] += delta
        if let name { names[peer] = name }
    }

    func usage(onDay day: String, peer: String) -> DeviceUsage {
        days[day]?[peer] ?? DeviceUsage()
    }

    func total(onDay day: String) -> DeviceUsage {
        days[day]?.values.reduce(DeviceUsage()) { $0 + $1 } ?? DeviceUsage()
    }

    /// The usage in a range of days, half-open like the billing cycle's range:
    /// day keys are `yyyy-MM-dd`, so text order is date order.
    func usage(fromDay start: String, toDayExclusive end: String, peer: String) -> DeviceUsage {
        var out = DeviceUsage()
        for (day, perPeer) in days where day >= start && day < end {
            if let usage = perPeer[peer] { out += usage }
        }
        return out
    }

    func total(fromDay start: String, toDayExclusive end: String) -> DeviceUsage {
        var out = DeviceUsage()
        for (day, perPeer) in days where day >= start && day < end {
            for usage in perPeer.values { out += usage }
        }
        return out
    }

    func allTime(peer: String) -> DeviceUsage {
        var out = legacy[peer] ?? DeviceUsage()
        for perPeer in days.values { if let usage = perPeer[peer] { out += usage } }
        return out
    }

    func allTimeTotal() -> DeviceUsage {
        var out = legacy.values.reduce(DeviceUsage()) { $0 + $1 }
        for perPeer in days.values { for usage in perPeer.values { out += usage } }
        return out
    }

    /// Every recorded day, oldest first.
    var recordedDays: [String] { days.keys.sorted() }

    /// The devices with usage on a day, by name then id, for the history screen.
    func peers(onDay day: String) -> [String] {
        (days[day] ?? [:]).keys.sorted { (names[$0] ?? $0) < (names[$1] ?? $1) }
    }

    /// Every device that has any record, by name then id.
    var allPeers: [String] {
        var ids = Set(legacy.keys)
        for perPeer in days.values { ids.formUnion(perPeer.keys) }
        return ids.sorted { (names[$0] ?? $0) < (names[$1] ?? $1) }
    }

    /// Folds days older than the window into `legacy` and drops them, so all-time
    /// totals are unchanged and only the per-day detail goes.
    mutating func prune(keepingDays: Int, now: Date, calendar: Calendar = .current) {
        guard keepingDays > 0,
              let cutoff = calendar.date(byAdding: .day, value: -(keepingDays - 1), to: calendar.startOfDay(for: now)) else { return }
        let cutoffDay = UsageTracker.stamp(for: cutoff, calendar: calendar)
        for day in days.keys.filter({ $0 < cutoffDay }) {
            for (peer, usage) in days[day] ?? [:] { legacy[peer, default: DeviceUsage()] += usage }
            days[day] = nil
        }
    }

    /// The 1.1.x usage (session/today/all-time totals in UserDefaults, keyed by
    /// public key) as a history: today's counts go into today's bucket, and what's
    /// left of all-time goes to `legacy`, marked as before per-day records existed.
    /// `keyToPeer` maps the old keys to peer UUIDs; an unmapped key keeps its old
    /// key as its id, so nothing is lost even for a device that's already gone.
    static func migrating(from tracker: UsageTracker, keyToPeer: [String: String],
                          now: Date, calendar: Calendar = .current) -> UsageHistory {
        var history = UsageHistory()
        let today = UsageTracker.stamp(for: now, calendar: calendar)
        for key in tracker.recordedKeys {
            let peer = keyToPeer[key] ?? key
            let todayUsage = tracker.todayUsage(for: key)
            let before = tracker.allTimeUsage(for: key).saturatingSubtract(todayUsage)
            if todayUsage.total > 0 { history.days[today, default: [:]][peer] = todayUsage }
            if before.total > 0 { history.legacy[peer] = before }
        }
        return history
    }
}

extension DeviceUsage {
    /// Component-wise subtraction that never goes below zero: a migrated all-time
    /// that somehow reads less than today must not wrap a UInt64.
    func saturatingSubtract(_ other: DeviceUsage) -> DeviceUsage {
        DeviceUsage(up: up >= other.up ? up - other.up : 0,
                    down: down >= other.down ? down - other.down : 0)
    }
}

/// Where the history is kept: one JSON file in the app's private container,
/// written atomically with first-unlock file protection (sharing runs with the
/// phone locked, so anything stricter would fail exactly when it matters).
enum UsageHistoryStore {
    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("usage-history.json")
    }

    static func load(from url: URL = defaultURL()) -> UsageHistory {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(UsageHistory.self, from: data) else {
            return UsageHistory()
        }
        return saved
    }

    static func save(_ history: UsageHistory, to url: URL = defaultURL()) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
