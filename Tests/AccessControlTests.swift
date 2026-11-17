import XCTest
@testable import TetherCore

/// The blocked-check truth table (AccessControl): each reason on its own, the
/// order when several apply, and the ways each one lifts.
final class AccessControlTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func block(approval: WireGuardSetup.Approval = .approved, pausedUntil: Date? = nil,
                       guestAccessExpiresAt: Date? = nil, capBytes: UInt64? = nil,
                       usedToday: UInt64 = 0, monthlyCapReached: Bool = false) -> AccessBlock? {
        AccessControl.block(approval: approval, pausedUntil: pausedUntil,
                            guestAccessExpiresAt: guestAccessExpiresAt, capBytes: capBytes,
                            usedToday: usedToday, monthlyCapReached: monthlyCapReached, now: now)
    }

    func testAnOrdinaryDevicePasses() {
        XCTAssertNil(block())
    }

    func testPendingIsBlockedUntilApproved() {
        XCTAssertEqual(block(approval: .pending), .notApproved)
        XCTAssertNil(block(approval: .approved))
    }

    func testAPauseBlocksUntilItsDateAndThenLiftsByItself() {
        let until = now.addingTimeInterval(900)
        XCTAssertEqual(block(pausedUntil: until), .paused(until: until))
        XCTAssertEqual(block(pausedUntil: .distantFuture), .paused(until: .distantFuture), "indefinite is a date too")
        XCTAssertNil(block(pausedUntil: now), "a pause ending exactly now is over")
        XCTAssertNil(block(pausedUntil: now.addingTimeInterval(-1)), "a lapsed pause is no pause")
    }

    func testTheDailyCapBlocksAtTheCap() {
        XCTAssertNil(block(capBytes: 1_000, usedToday: 999))
        XCTAssertEqual(block(capBytes: 1_000, usedToday: 1_000), .dailyCap)
        XCTAssertNil(block(capBytes: nil, usedToday: 1_000_000), "no cap never blocks")
        XCTAssertNil(block(capBytes: 0, usedToday: 1_000_000), "a zero cap is off")
    }

    func testTheMonthlyCapBlocksEveryDevice() {
        XCTAssertEqual(block(monthlyCapReached: true), .monthlyCap)
        XCTAssertNil(block(monthlyCapReached: false))
    }

    func testAGuestPassEndsAtItsAccessDate() {
        XCTAssertNil(block(guestAccessExpiresAt: now.addingTimeInterval(60)))
        XCTAssertEqual(block(guestAccessExpiresAt: now), .guestAccessEnded)
        XCTAssertEqual(block(guestAccessExpiresAt: now.addingTimeInterval(-60)), .guestAccessEnded)
    }

    func testTheReasonsKeepTheirOrder() {
        // Approval first: a pending device isn't told apart by its pause or cap.
        XCTAssertEqual(block(approval: .pending, pausedUntil: .distantFuture, capBytes: 1, usedToday: 1,
                             monthlyCapReached: true), .notApproved)
        // A hand pause beats the caps: resuming by hand must not be the way around a
        // cap, and the cap must not be the reason shown for a hand pause.
        XCTAssertEqual(block(pausedUntil: .distantFuture, capBytes: 1, usedToday: 1,
                             monthlyCapReached: true), .paused(until: .distantFuture))
        XCTAssertEqual(block(capBytes: 1, usedToday: 1, monthlyCapReached: true), .dailyCap)
        XCTAssertEqual(block(monthlyCapReached: true, guestAccessExpiresAt: now), .monthlyCap)
    }

    func testStartOfNextDayIsTheNextLocalMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let afternoon = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 15))!
        let next = AccessControl.startOfNextDay(after: afternoon, calendar: calendar)
        let parts = calendar.dateComponents([.month, .day, .hour], from: next)
        XCTAssertEqual(parts.month, 3)
        XCTAssertEqual(parts.day, 9, "the spring-forward day still ends at the next midnight")
        XCTAssertEqual(parts.hour, 0)
    }
}
