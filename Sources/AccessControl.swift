import Foundation

/// Why a device may not pass traffic right now. The reasons stay separate on purpose:
/// with one shared "paused" flag, the midnight cap reset used to unpause a device the
/// person had paused by hand, and resuming by hand used to override a cap. Each reason
/// here lifts by its own rule and no other.
enum AccessBlock: Equatable {
    /// Approval mode is on and the device hasn't been approved yet.
    case notApproved
    /// Paused by hand, until this date (`.distantFuture` is until resumed by hand).
    case paused(until: Date)
    /// The device reached its data cap for today. Lifts when the day turns.
    case dailyCap
    /// Every device together reached the monthly cap. Lifts when the cycle turns.
    case monthlyCap
    /// A one-time guest pass whose access date has passed (it is removed right after;
    /// this reason covers the moment between the date passing and the removal).
    case guestAccessEnded
}

/// The one check every part of Ferry uses to decide whether a device may pass
/// traffic: the screens, the policies pushed to the server, the caps. Pure and
/// table-tested, Foundation only, so `swift test` covers it.
///
/// Nothing here depends on code running at a set time. A timed pause ends because
/// `now` passes its date, a daily cap lifts because today's usage is a new day's,
/// a monthly cap lifts because the cycle's dates move: all of it is worked out from
/// saved timestamps and counters each time the check runs.
enum AccessControl {
    /// The first reason that applies, in this order, or nil when the device may pass
    /// traffic. `guestAccessExpiresAt` is a one-time guest pass's access date; a
    /// classic guest's own expiry removes the device instead (see Model).
    static func block(approval: WireGuardSetup.Approval, pausedUntil: Date?,
                      guestAccessExpiresAt: Date?, capBytes: UInt64?,
                      usedToday: UInt64, monthlyCapReached: Bool, now: Date) -> AccessBlock? {
        if approval == .pending { return .notApproved }
        if let pausedUntil, pausedUntil > now { return .paused(until: pausedUntil) }
        if UsageTracker.capReached(usedToday: usedToday, capBytes: capBytes) { return .dailyCap }
        if monthlyCapReached { return .monthlyCap }
        if let guestAccessExpiresAt, guestAccessExpiresAt <= now { return .guestAccessEnded }
        return nil
    }

    static func isBlocked(approval: WireGuardSetup.Approval, pausedUntil: Date?,
                          guestAccessExpiresAt: Date?, capBytes: UInt64?,
                          usedToday: UInt64, monthlyCapReached: Bool, now: Date) -> Bool {
        block(approval: approval, pausedUntil: pausedUntil,
              guestAccessExpiresAt: guestAccessExpiresAt, capBytes: capBytes,
              usedToday: usedToday, monthlyCapReached: monthlyCapReached, now: now) != nil
    }

    /// The end of "pause until tomorrow": the start of the next local day, stored as
    /// an exact date and shown as a time.
    static func startOfNextDay(after date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date.addingTimeInterval(86_400)
    }
}
