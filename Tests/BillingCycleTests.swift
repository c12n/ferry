import XCTest
@testable import TetherCore

/// Billing cycle date math (BillingCycle): short months, leap years, daylight
/// saving, and what happens when the billing day changes mid-cycle (nothing is
/// stored, so a new day simply gives a new range).
final class BillingCycleTests: XCTestCase {
    private var utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func ymd(_ calendar: Calendar, _ date: Date) -> [Int] {
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return [parts.year!, parts.month!, parts.day!, parts.hour!]
    }

    func testAnOrdinaryCycle() {
        let range = BillingCycle.range(billingDay: 15, containing: date(utc, 2026, 6, 20), calendar: utc)
        XCTAssertEqual(ymd(utc, range.start), [2026, 6, 15, 0])
        XCTAssertEqual(ymd(utc, range.end), [2026, 7, 15, 0])
    }

    func testBeforeTheBillingDayTheCycleStartedLastMonth() {
        let range = BillingCycle.range(billingDay: 15, containing: date(utc, 2026, 6, 10), calendar: utc)
        XCTAssertEqual(ymd(utc, range.start), [2026, 5, 15, 0])
        XCTAssertEqual(ymd(utc, range.end), [2026, 6, 15, 0])
    }

    func testOnTheBillingDayANewCycleStarts() {
        let start = BillingCycle.start(billingDay: 15, containing: date(utc, 2026, 6, 15, hour: 0), calendar: utc)
        XCTAssertEqual(ymd(utc, start), [2026, 6, 15, 0])
    }

    func testDay31ClampsToApril30() {
        let range = BillingCycle.range(billingDay: 31, containing: date(utc, 2026, 4, 15), calendar: utc)
        XCTAssertEqual(ymd(utc, range.start), [2026, 3, 31, 0])
        XCTAssertEqual(ymd(utc, range.end), [2026, 4, 30, 0], "April has no 31st")
        let next = BillingCycle.range(billingDay: 31, containing: date(utc, 2026, 5, 1), calendar: utc)
        XCTAssertEqual(ymd(utc, next.start), [2026, 4, 30, 0])
        XCTAssertEqual(ymd(utc, next.end), [2026, 5, 31, 0], "and May's cycle starts on the 31st again, not the 30th")
    }

    func testFebruaryInALeapYear() {
        let range = BillingCycle.range(billingDay: 29, containing: date(utc, 2028, 3, 5), calendar: utc)
        XCTAssertEqual(ymd(utc, range.start), [2028, 2, 29, 0], "2028 is a leap year")
        XCTAssertEqual(ymd(utc, range.end), [2028, 3, 29, 0])
        let clamped = BillingCycle.range(billingDay: 31, containing: date(utc, 2028, 3, 5), calendar: utc)
        XCTAssertEqual(ymd(utc, clamped.start), [2028, 2, 29, 0], "day 31 clamps to Feb 29 in a leap year")
    }

    func testFebruaryInAPlainYear() {
        let range = BillingCycle.range(billingDay: 29, containing: date(utc, 2026, 3, 5), calendar: utc)
        XCTAssertEqual(ymd(utc, range.start), [2026, 2, 28, 0], "2026 is not a leap year: day 29 clamps to Feb 28")
        let clamped = BillingCycle.range(billingDay: 31, containing: date(utc, 2026, 3, 5), calendar: utc)
        XCTAssertEqual(ymd(utc, clamped.start), [2026, 2, 28, 0])
        XCTAssertEqual(ymd(utc, clamped.end), [2026, 3, 31, 0])
    }

    func testTheYearTurns() {
        let range = BillingCycle.range(billingDay: 15, containing: date(utc, 2027, 1, 10), calendar: utc)
        XCTAssertEqual(ymd(utc, range.start), [2026, 12, 15, 0])
        XCTAssertEqual(ymd(utc, range.end), [2027, 1, 15, 0])
    }

    func testDaylightSavingDays() {
        // Spring forward: March 8, 2026 in New York. The cycle containing it starts
        // Feb 15 at local midnight and the next starts March 15 at local midnight,
        // even though the days between aren't all 24 hours.
        let range = BillingCycle.range(billingDay: 15, containing: date(newYork, 2026, 3, 8, hour: 15), calendar: newYork)
        XCTAssertEqual(ymd(newYork, range.start), [2026, 2, 15, 0])
        XCTAssertEqual(ymd(newYork, range.end), [2026, 3, 15, 0])
        // Fall back: November 1, 2026.
        let fall = BillingCycle.range(billingDay: 1, containing: date(newYork, 2026, 11, 1, hour: 15), calendar: newYork)
        XCTAssertEqual(ymd(newYork, fall.start), [2026, 11, 1, 0])
        XCTAssertEqual(ymd(newYork, fall.end), [2026, 12, 1, 0])
    }

    func testChangingTheBillingDayMidCycleJustMovesTheRange() {
        let day = date(utc, 2026, 6, 20)
        let before = BillingCycle.range(billingDay: 10, containing: day, calendar: utc)
        XCTAssertEqual(ymd(utc, before.start), [2026, 6, 10, 0])
        let after = BillingCycle.range(billingDay: 25, containing: day, calendar: utc)
        XCTAssertEqual(ymd(utc, after.start), [2026, 5, 25, 0], "the new day applies to the current cycle at once")
        XCTAssertEqual(ymd(utc, after.end), [2026, 6, 25, 0])
    }

    func testClampedDay() {
        XCTAssertEqual(BillingCycle.clampedDay(31, year: 2026, month: 4, calendar: utc), 30)
        XCTAssertEqual(BillingCycle.clampedDay(29, year: 2028, month: 2, calendar: utc), 29)
        XCTAssertEqual(BillingCycle.clampedDay(29, year: 2026, month: 2, calendar: utc), 28)
        XCTAssertEqual(BillingCycle.clampedDay(15, year: 2026, month: 2, calendar: utc), 15)
        XCTAssertEqual(BillingCycle.clampedDay(0, year: 2026, month: 2, calendar: utc), 1, "clamped into the month")
        XCTAssertEqual(BillingCycle.clampedDay(45, year: 2026, month: 1, calendar: utc), 31)
    }

    func testThresholds() {
        XCTAssertNil(BillingCycle.crossedThreshold(used: 79, cap: 100, alreadySent: []))
        XCTAssertEqual(BillingCycle.crossedThreshold(used: 80, cap: 100, alreadySent: []), 80)
        XCTAssertEqual(BillingCycle.crossedThreshold(used: 100, cap: 100, alreadySent: [80]), 100)
        XCTAssertEqual(BillingCycle.crossedThreshold(used: 100, cap: 100, alreadySent: []), 100,
                       "both crossed at once (the cap was lowered): only the 100 alert is due")
        XCTAssertNil(BillingCycle.crossedThreshold(used: 100, cap: 100, alreadySent: [80, 100]), "nothing twice")
        XCTAssertNil(BillingCycle.crossedThreshold(used: 100, cap: 0, alreadySent: []), "no cap, no alerts")
        XCTAssertEqual(BillingCycle.crossedThreshold(used: 8_000_000_000, cap: 10_000_000_000, alreadySent: []), 80)
    }

    func testTheCycleKeyIsTheStartDay() {
        XCTAssertEqual(BillingCycle.key(forCycleStart: date(utc, 2026, 6, 15, hour: 0), calendar: utc), "2026-06-15")
    }
}
