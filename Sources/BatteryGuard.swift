import Foundation

/// The battery guard's decisions: stop sharing when the battery falls to a level the
/// person chose, unless the iPhone is charging. Foundation only, so `swift test` covers
/// it. Levels are fractions (0...1, as UIDevice reports); thresholds are whole percents,
/// with 0 meaning the guard is off.
enum BatteryGuard {
    /// The levels the Settings picker offers besides Off.
    static let levels = [20, 30, 40, 50]

    /// Sharing stops at or below the threshold while running on battery. A negative level
    /// (iOS doesn't know it) never stops anything.
    static func shouldStop(level: Float, isCharging: Bool, thresholdPercent: Int) -> Bool {
        guard thresholdPercent > 0, !isCharging, level >= 0 else { return false }
        return level * 100 <= Float(thresholdPercent)
    }

    /// The warning comes one step (10 points) above the stop level, while there's still
    /// time to plug in: at or below `threshold + 10` but above the threshold itself.
    static func shouldWarn(level: Float, isCharging: Bool, thresholdPercent: Int) -> Bool {
        guard thresholdPercent > 0, !isCharging, level >= 0 else { return false }
        let percent = level * 100
        return percent <= Float(thresholdPercent + 10) && percent > Float(thresholdPercent)
    }

    /// After a stop, the guard stays out of the way until the battery is clearly past the
    /// threshold (charging, or 5 points above it), so a level hovering at the line doesn't
    /// stop sharing again at once — and a manual Resume means something.
    static func recovered(level: Float, isCharging: Bool, thresholdPercent: Int) -> Bool {
        if isCharging { return true }
        guard level >= 0 else { return false }
        return level * 100 > Float(thresholdPercent + 5)
    }
}
