import ActivityKit
import Foundation

/// The Live Activity for a sharing session: started when sharing starts, updated as the
/// traffic sampling runs, ended when sharing stops. Compiled into the app (which drives
/// it) and into the widget extension (which draws it), and into nothing else — ActivityKit
/// isn't part of the `swift test` target.
struct TetherActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isSharing: Bool
        var connectedDevices: Int
        /// Bits per second, like Model's speeds.
        var downSpeed: Double
        var upSpeed: Double
        /// Every device's usage today, up and down together, in bytes.
        var usageToday: UInt64
    }

    /// Fixed for every activity: there is only the one session.
    var title: String = "Ferry"
}
