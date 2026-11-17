import Foundation

/// The app's sharing state as the widget shows it, written by the app and read by the
/// widget extension. Foundation only, so `swift test` covers the coding.
///
/// The two processes share it through an App Group's UserDefaults. After a third-party
/// re-sign (SideStore, AltStore) the group may not resolve at all; then the app writes to
/// its own defaults (the widget just shows its placeholder) and nothing crashes.
struct WidgetSnapshot: Codable, Equatable {
    var isSharing: Bool
    var connectedDevices: Int
    var downSpeed: Double
    var upSpeed: Double
    /// Every device's usage today, up and down together, in bytes.
    var usageToday: UInt64
    var updatedAt: Date
    /// When the app last wrote a snapshot, sharing or not. The Control Center control
    /// calls sharing "on" only while this is fresh (under 20 seconds): a snapshot from
    /// a suspended or killed app must not claim Ferry is sharing. Written by the app
    /// only; snapshots saved before 1.2 have none and read as the distant past.
    var heartbeatAt: Date = .distantPast
    /// Devices waiting for approval. Zero before 1.2.
    var waitingCount: Int = 0

    private enum CodingKeys: String, CodingKey {
        case isSharing, connectedDevices, downSpeed, upSpeed, usageToday, updatedAt, heartbeatAt, waitingCount
    }

    init(isSharing: Bool, connectedDevices: Int, downSpeed: Double, upSpeed: Double,
         usageToday: UInt64, updatedAt: Date, heartbeatAt: Date = .distantPast, waitingCount: Int = 0) {
        self.isSharing = isSharing
        self.connectedDevices = connectedDevices
        self.downSpeed = downSpeed
        self.upSpeed = upSpeed
        self.usageToday = usageToday
        self.updatedAt = updatedAt
        self.heartbeatAt = heartbeatAt
        self.waitingCount = waitingCount
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        isSharing = try box.decode(Bool.self, forKey: .isSharing)
        connectedDevices = try box.decode(Int.self, forKey: .connectedDevices)
        downSpeed = try box.decode(Double.self, forKey: .downSpeed)
        upSpeed = try box.decode(Double.self, forKey: .upSpeed)
        usageToday = try box.decode(UInt64.self, forKey: .usageToday)
        updatedAt = try box.decode(Date.self, forKey: .updatedAt)
        heartbeatAt = try box.decodeIfPresent(Date.self, forKey: .heartbeatAt) ?? .distantPast
        waitingCount = try box.decodeIfPresent(Int.self, forKey: .waitingCount) ?? 0
    }
}

/// A Start or Stop asked for outside the app: the Control Center control and the
/// widget's buttons in the widget extension, which can't run the server. The request
/// is a note in the App Group; the app acts on it the next time it wakes (a control
/// press wakes it, through the intent's app side). Requests are moments, not state:
/// one older than a minute is stale and dropped, and acting consumes it, so a
/// request can never fire twice.
enum ControlRequestStore {
    private static let key = "tether.controlRequest.v1"

    enum Request: String, Codable {
        case start, stop
    }

    private struct Stored: Codable {
        var request: Request
        var at: Date
    }

    static func save(_ request: Request, at date: Date = Date(), to defaults: UserDefaults? = WidgetSnapshotStore.defaults()) {
        guard let defaults, let data = try? JSONEncoder().encode(Stored(request: request, at: date)) else { return }
        defaults.set(data, forKey: key)
    }

    /// The pending request, if any, clearing it either way.
    static func consume(from defaults: UserDefaults? = WidgetSnapshotStore.defaults(), now: Date = Date()) -> Request? {
        guard let defaults, let data = defaults.data(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              now.timeIntervalSince(stored.at) < 60 else { return nil }
        return stored.request
    }
}

enum WidgetSnapshotStore {
    /// The App Group both targets declare in their entitlements.
    static let appGroup = "group.com.c12n.tether"
    private static let key = "tether.widgetSnapshot.v1"

    /// The group's defaults when the group resolves, else the process's own — see the note
    /// on `WidgetSnapshot`. The widget reads only the group's; a snapshot it can't find is
    /// its "Open Ferry" state.
    static func defaults(forWidget: Bool = false) -> UserDefaults? {
        if let shared = UserDefaults(suiteName: appGroup) { return shared }
        return forWidget ? nil : .standard
    }

    static func save(_ snapshot: WidgetSnapshot, to defaults: UserDefaults? = defaults()) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    static func load(from defaults: UserDefaults? = defaults(forWidget: true)) -> WidgetSnapshot? {
        guard let defaults, let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
