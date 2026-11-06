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
