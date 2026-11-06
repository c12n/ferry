import Foundation

/// How much one device has sent and received, in bytes. Up is what left the iPhone through
/// it, down what came back to it — the server's directions, see Stats in WireGuard/server.go.
struct DeviceUsage: Codable, Equatable {
    var up: UInt64 = 0
    var down: UInt64 = 0
    var total: UInt64 { up + down }
}

/// Per-device data usage: this sharing session, today, and all time, fed from the server's
/// per-device counters. Foundation only, so `swift test` covers it.
///
/// Devices are keyed by an opaque string the caller chooses (Model uses the device's public
/// key, so usage follows the device even if its tunnel address is ever reused by another).
///
/// The readings fed in are cumulative counters that only grow while the app runs (the
/// server's carried totals, see WireGuardServer). The tracker keeps the last reading per
/// device and adds the difference, so what a device used while the screen was off still
/// counts when the next reading arrives. `last` is not saved: after a relaunch the first
/// reading is the new baseline and adds nothing, so a restart never double-counts — it can
/// only miss what the previous run counted after its last save.
struct UsageTracker: Codable, Equatable {
    private(set) var session: [String: DeviceUsage] = [:]
    private(set) var today: [String: DeviceUsage] = [:]
    private(set) var allTime: [String: DeviceUsage] = [:]
    /// The local day `today` belongs to, as yyyy-MM-dd. When a reading arrives on a later
    /// day, `today` starts over.
    private(set) var dayStamp: String
    /// The last cumulative reading per device. Session state, not saved (see above), so it
    /// is not in the coding keys.
    private var last: [String: DeviceUsage] = [:]

    private enum CodingKeys: String, CodingKey { case session, today, allTime, dayStamp }

    init(now: Date = Date(), calendar: Calendar = .current) {
        dayStamp = Self.stamp(for: now, calendar: calendar)
    }

    static func stamp(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The difference between two cumulative readings. A reading that went backwards (the
    /// counter restarted) counts in full: the new run's traffic is real usage.
    static func delta(new: UInt64, old: UInt64) -> UInt64 {
        new >= old ? new - old : new
    }

    /// Whether `usedToday` has reached a cap of `capBytes`. No cap (nil or 0) never trips.
    static func capReached(usedToday: UInt64, capBytes: UInt64?) -> Bool {
        guard let capBytes, capBytes > 0 else { return false }
        return usedToday >= capBytes
    }

    /// Starts a new sharing session: the session totals go back to zero, and the next
    /// reading is the baseline, so a session never inherits the gap since the last one.
    mutating func startSession() {
        session = [:]
        last = [:]
    }

    /// Feeds the latest cumulative counters, one entry per device key. Returns true when a
    /// new day started with this reading (today's totals were reset) — Model uses it to
    /// lift cap pauses, which are per-day.
    @discardableResult
    mutating func record(_ readings: [String: DeviceUsage], now: Date = Date(), calendar: Calendar = .current) -> Bool {
        var rolledOver = false
        let stamp = Self.stamp(for: now, calendar: calendar)
        if stamp != dayStamp {
            dayStamp = stamp
            today = [:]
            rolledOver = true
        }
        for (key, reading) in readings {
            guard let before = last[key] else {
                last[key] = reading // first sight of this device this launch: a baseline only
                continue
            }
            let moved = DeviceUsage(up: Self.delta(new: reading.up, old: before.up),
                                    down: Self.delta(new: reading.down, old: before.down))
            last[key] = reading
            guard moved.total > 0 else { continue }
            session[key, default: DeviceUsage()] += moved
            today[key, default: DeviceUsage()] += moved
            allTime[key, default: DeviceUsage()] += moved
        }
        return rolledOver
    }

    func sessionUsage(for key: String) -> DeviceUsage { session[key] ?? DeviceUsage() }
    func todayUsage(for key: String) -> DeviceUsage { today[key] ?? DeviceUsage() }
    func allTimeUsage(for key: String) -> DeviceUsage { allTime[key] ?? DeviceUsage() }

    /// Every device's usage added together, for the main screen's totals.
    func sessionTotal() -> DeviceUsage { session.values.reduce(DeviceUsage()) { $0 + $1 } }
    func todayTotal() -> DeviceUsage { today.values.reduce(DeviceUsage()) { $0 + $1 } }

    /// A device that was removed for good takes its usage history with it.
    mutating func forget(_ key: String) {
        session[key] = nil
        today[key] = nil
        allTime[key] = nil
        last[key] = nil
    }
}

extension DeviceUsage {
    static func + (a: DeviceUsage, b: DeviceUsage) -> DeviceUsage {
        DeviceUsage(up: a.up + b.up, down: a.down + b.down)
    }

    static func += (a: inout DeviceUsage, b: DeviceUsage) {
        a = a + b
    }
}

/// Where the usage is kept. It holds no keys or secrets, so UserDefaults is fine. A save
/// that fails (a store that can't encode, which shouldn't happen) is ignored: the next
/// change saves again, and usage is a record, not the thing itself.
enum UsageStore {
    private static let key = "tether.usage.v1"

    static func load(from defaults: UserDefaults = .standard) -> UsageTracker {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(UsageTracker.self, from: data) else {
            return UsageTracker()
        }
        return saved
    }

    static func save(_ tracker: UsageTracker, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(tracker) {
            defaults.set(data, forKey: key)
        }
    }
}
