import XCTest
@testable import TetherCore

final class FormatTests: XCTestCase {
    func testSpeedUsesTheUnitOfASpeedTest() {
        XCTAssertEqual(Format.speed(0), "0 bit/s")
        XCTAssertEqual(Format.speed(999), "999 bit/s")
        XCTAssertEqual(Format.speed(400_000), "400 kbit/s")
        XCTAssertEqual(Format.speed(3_200_000), "3.2 Mbit/s")
    }

    func testBytesAreReadable() {
        XCTAssertEqual(Format.bytes(2_000_000), "2 MB")
        XCTAssertEqual(Format.bytes(UInt64.max), Format.bytes(UInt64(Int64.max)), "a huge count doesn't trap")
    }

    func testGuestTimeLeft() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Format.remaining(until: now.addingTimeInterval(30), now: now), "Under a minute left")
        XCTAssertEqual(Format.remaining(until: now.addingTimeInterval(5 * 60), now: now), "5 min left")
        XCTAssertEqual(Format.remaining(until: now.addingTimeInterval(2 * 3600), now: now), "2 h left")
        XCTAssertEqual(Format.remaining(until: now.addingTimeInterval(2 * 3600 + 15 * 60), now: now), "2 h 15 min left")
        XCTAssertEqual(Format.remaining(until: now.addingTimeInterval(26 * 3600), now: now), "1 d 2 h left")
        XCTAssertEqual(Format.remaining(until: now.addingTimeInterval(48 * 3600), now: now), "2 d left")
        XCTAssertEqual(Format.remaining(until: now, now: now), "Expired")
        XCTAssertEqual(Format.remaining(until: now.addingTimeInterval(-60), now: now), "Expired")
    }
}
