import XCTest
@testable import TetherCore

final class UsageHistoryTests: XCTestCase {
    private var utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testAddingAndReadingBack() {
        var history = UsageHistory()
        history.add(DeviceUsage(up: 10, down: 90), peer: "a", name: "iPad", day: "2026-11-14")
        history.add(DeviceUsage(up: 5, down: 5), peer: "a", name: "iPad", day: "2026-11-14")
        history.add(DeviceUsage(up: 1, down: 2), peer: "b", name: "Mac", day: "2026-11-14")
        history.add(DeviceUsage(up: 7, down: 7), peer: "a", name: "iPad", day: "2026-11-13")
        XCTAssertEqual(history.usage(onDay: "2026-11-14", peer: "a"), DeviceUsage(up: 15, down: 95),
                       "writes to the same day add up, by key")
        XCTAssertEqual(history.total(onDay: "2026-11-14"), DeviceUsage(up: 16, down: 97))
        XCTAssertEqual(history.allTime(peer: "a"), DeviceUsage(up: 22, down: 102))
        XCTAssertEqual(history.recordedDays, ["2026-11-13", "2026-11-14"])
        XCTAssertEqual(history.names["a"], "iPad")
        XCTAssertTrue(history.usage(onDay: "2026-11-12", peer: "a") == DeviceUsage(), "an unrecorded day is zero")
    }

    func testZeroDeltasRecordNothing() {
        var history = UsageHistory()
        history.add(DeviceUsage(), peer: "a", name: "iPad", day: "2026-11-14")
        XCTAssertTrue(history.isEmpty)
    }

    func testRangeSumsAreHalfOpen() {
        var history = UsageHistory()
        for (day, down) in [("2026-06-14", 1), ("2026-06-15", 10), ("2026-07-14", 100), ("2026-07-15", 1000)] {
            history.add(DeviceUsage(up: 0, down: UInt64(down)), peer: "a", name: nil, day: day)
        }
        // The June 15 to July 15 cycle: the 14th before and the 15th after are out.
        XCTAssertEqual(history.total(fromDay: "2026-06-15", toDayExclusive: "2026-07-15"),
                       DeviceUsage(up: 0, down: 110))
        XCTAssertEqual(history.usage(fromDay: "2026-06-15", toDayExclusive: "2026-07-15", peer: "a"),
                       DeviceUsage(up: 0, down: 110))
        XCTAssertEqual(history.usage(fromDay: "2026-06-15", toDayExclusive: "2026-07-15", peer: "b"),
                       DeviceUsage(), "a device with no rows in the range reads zero")
    }

    func testPruningFoldsOldDaysIntoLegacy() {
        var history = UsageHistory()
        history.add(DeviceUsage(up: 1, down: 2), peer: "a", name: "iPad", day: "2026-01-01")
        history.add(DeviceUsage(up: 3, down: 4), peer: "a", name: "iPad", day: "2026-11-14")
        let before = history.allTime(peer: "a")
        history.prune(keepingDays: 30, now: date(2026, 11, 14), calendar: utc)
        XCTAssertEqual(history.recordedDays, ["2026-11-14"], "the January day is outside a 30-day window")
        XCTAssertEqual(history.legacy["a"], DeviceUsage(up: 1, down: 2), "folded, not lost")
        XCTAssertEqual(history.allTime(peer: "a"), before, "all-time never shrinks when days are pruned")
    }

    func testMigrationFromTheOldTotals() {
        let day1 = date(2026, 11, 13)
        let day2 = date(2026, 11, 14)
        var tracker = UsageTracker(now: day1, calendar: utc)
        tracker.record(["keyA": DeviceUsage(up: 0, down: 0)], now: day1, calendar: utc)
        tracker.record(["keyA": DeviceUsage(up: 100, down: 100)], now: day1, calendar: utc)
        tracker.record(["keyB": DeviceUsage(up: 0, down: 0)], now: day1, calendar: utc)
        tracker.record(["keyB": DeviceUsage(up: 50, down: 50)], now: day1, calendar: utc)
        // A new day: keyA uses 10 more, which is all of day 2's usage for it.
        _ = tracker.record(["keyA": DeviceUsage(up: 110, down: 110)], now: day2, calendar: utc)

        let history = UsageHistory.migrating(from: tracker, keyToPeer: ["keyA": "uuid-a"], now: day2, calendar: utc)
        XCTAssertEqual(history.usage(onDay: "2026-11-14", peer: "uuid-a"), DeviceUsage(up: 10, down: 10),
                       "today's counts land in today's bucket")
        XCTAssertEqual(history.legacy["uuid-a"], DeviceUsage(up: 100, down: 100),
                       "the rest of all-time is marked as before per-day records")
        XCTAssertEqual(history.allTime(peer: "uuid-a"), DeviceUsage(up: 110, down: 110), "nothing lost, nothing doubled")
        XCTAssertEqual(history.legacy["keyB"], DeviceUsage(up: 50, down: 50),
                       "an unmapped key keeps its old key as its id, so its usage survives too")
        XCTAssertEqual(history.usage(onDay: "2026-11-14", peer: "keyB"), DeviceUsage(),
                       "keyB's usage was all yesterday: none of it lands in today's bucket")
    }

    func testTheStoreRoundTripsThroughAFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-history-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(UsageHistoryStore.load(from: url).isEmpty, "no file yet is an empty history")
        var history = UsageHistory()
        history.add(DeviceUsage(up: 1, down: 2), peer: "a", name: "iPad", day: "2026-11-14")
        UsageHistoryStore.save(history, to: url)
        XCTAssertEqual(UsageHistoryStore.load(from: url), history)
    }
}

final class UsageCSVTests: XCTestCase {
    func testEscaping() {
        XCTAssertEqual(UsageCSV.escape("plain"), "plain")
        XCTAssertEqual(UsageCSV.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(UsageCSV.escape("say \"hi\""), "\"say \"\"hi\"\"\"", "quotes double, per RFC 4180")
        XCTAssertEqual(UsageCSV.escape("two\nlines"), "\"two\nlines\"", "a newline means quoting")
        XCTAssertEqual(UsageCSV.escape("=2+5"), "'=2+5", "a formula cell is defused")
        XCTAssertEqual(UsageCSV.escape("+SUM(A1:A2)"), "'+SUM(A1:A2)")
        XCTAssertEqual(UsageCSV.escape("-1"), "'-1")
        XCTAssertEqual(UsageCSV.escape("@handle"), "'@handle")
        XCTAssertEqual(UsageCSV.escape("a=b"), "a=b", "only a leading character is a formula")
    }

    func testTheDocument() {
        var history = UsageHistory()
        history.legacy["a"] = DeviceUsage(up: 3, down: 4)
        history.names["a"] = "iPad, the big one"
        history.add(DeviceUsage(up: 10, down: 90), peer: "a", name: "iPad, the big one", day: "2026-11-14")
        history.add(DeviceUsage(up: 1, down: 2), peer: "b", name: "=EVIL()", day: "2026-11-14")
        let csv = UsageCSV.document(history: history)
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}date,device_id,device_name,rx_bytes,tx_bytes\r\n"), "BOM, then the header")
        XCTAssertTrue(csv.contains("before-1.2,a,\"iPad, the big one\",4,3\r\n"),
                      "the pre-1.2 totals come first; rx is down, tx is up")
        XCTAssertTrue(csv.contains("2026-11-14,a,\"iPad, the big one\",90,10\r\n"))
        XCTAssertTrue(csv.contains("2026-11-14,b,'=EVIL(),2,1\r\n"), "a hostile device name can't run as a formula")
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }
}
