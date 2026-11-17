import Foundation

/// The billing cycle the monthly cap and the monthly totals are measured over: a
/// cycle starts on the person's billing day each month and runs to the next one.
///
/// There is deliberately no monthly counter anywhere that something has to reset.
/// Monthly usage is the sum of the daily buckets (see UsageHistory) whose dates fall
/// in the current cycle's range, so a reset can never be missed while Ferry wasn't
/// running. All of this is pure calendar arithmetic, table-tested in `swift test`:
/// the billing day is clamped for short months (31 means April 30, and February 28
/// or 29), and days are added with the calendar, never as 86,400 seconds, so
/// daylight-saving days come out right.
enum BillingCycle {
    /// The day of the month a cycle may start on in the given month: the billing day
    /// itself, or the month's last day when the month is shorter.
    static func clampedDay(_ billingDay: Int, year: Int, month: Int, calendar: Calendar = .current) -> Int {
        let day = max(1, min(billingDay, 31))
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first) else { return day }
        return min(day, days.count)
    }

    /// The start of the cycle containing `date`: this month's clamped billing day,
    /// or last month's when that day is still ahead.
    static func start(billingDay: Int, containing date: Date, calendar: Calendar = .current) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let parts = calendar.dateComponents([.year, .month], from: dayStart)
        guard let year = parts.year, let month = parts.month else { return dayStart }
        var candidate = cycleStart(billingDay: billingDay, year: year, month: month, calendar: calendar)
        if candidate > dayStart {
            guard let previous = calendar.date(byAdding: .month, value: -1,
                                               to: calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? dayStart) else {
                return candidate
            }
            let prevParts = calendar.dateComponents([.year, .month], from: previous)
            candidate = cycleStart(billingDay: billingDay, year: prevParts.year ?? year,
                                   month: prevParts.month ?? month, calendar: calendar)
        }
        return candidate
    }

    /// The start of the cycle after the one beginning at `cycleStart`. The billing
    /// day is clamped afresh in the new month: a cycle that started on April 30
    /// (billing day 31) is followed by one starting May 31, not May 30.
    static func nextStart(billingDay: Int, after start: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: start)
        guard let year = parts.year, let month = parts.month,
              let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let next = calendar.date(byAdding: .month, value: 1, to: first) else { return start }
        let nextParts = calendar.dateComponents([.year, .month], from: next)
        return cycleStart(billingDay: billingDay, year: nextParts.year ?? year,
                          month: nextParts.month ?? month, calendar: calendar)
    }

    /// The current cycle as a half-open range of dates.
    static func range(billingDay: Int, containing date: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let cycleStartDate = start(billingDay: billingDay, containing: date, calendar: calendar)
        return (cycleStartDate, nextStart(billingDay: billingDay, after: cycleStartDate, calendar: calendar))
    }

    private static func cycleStart(billingDay: Int, year: Int, month: Int, calendar: Calendar) -> Date {
        let day = clampedDay(billingDay, year: year, month: month, calendar: calendar)
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
    }

    /// A cycle's identity, for remembering which alerts were already sent for it.
    static func key(forCycleStart start: Date, calendar: Calendar = .current) -> String {
        UsageTracker.stamp(for: start, calendar: calendar)
    }

    /// The alert thresholds, in percent of the monthly cap.
    static let thresholds = [80, 100]

    /// The highest threshold `used` has crossed that hasn't been sent yet, or nil.
    /// When the cap is lowered below what's already used, 80 and 100 cross at once
    /// and only the 100 alert is due: the caller sends this one and marks both sent.
    static func crossedThreshold(used: UInt64, cap: UInt64, alreadySent: Set<Int>) -> Int? {
        guard cap > 0 else { return nil }
        let usedDouble = Double(used), capDouble = Double(cap)
        return thresholds.filter { percent in
            !alreadySent.contains(percent) && usedDouble >= capDouble * Double(percent) / 100
        }.max()
    }
}
