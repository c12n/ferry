import XCTest
@testable import TetherCore

final class KeepAlivePolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testPlaysWhileTheHotspotIsOn() {
        XCTAssertTrue(KeepAlivePolicy.plays(waitingSince: nil, now: start))
    }

    func testKeepsPlayingForTenMinutesAfterTheHotspotGoes() {
        XCTAssertTrue(KeepAlivePolicy.plays(waitingSince: start, now: start.addingTimeInterval(9 * 60)))
    }

    func testStopsTenMinutesAfterTheHotspotGoes() {
        XCTAssertFalse(KeepAlivePolicy.plays(waitingSince: start, now: start.addingTimeInterval(10 * 60)))
        XCTAssertFalse(KeepAlivePolicy.plays(waitingSince: start, now: start.addingTimeInterval(8 * 3600)), "a night in airplane mode")
    }

    func testACustomIdleTimeoutIsWhatStopsIt() {
        XCTAssertTrue(KeepAlivePolicy.plays(waitingSince: start, now: start.addingTimeInterval(4 * 60), idleLimit: 5 * 60))
        XCTAssertFalse(KeepAlivePolicy.plays(waitingSince: start, now: start.addingTimeInterval(5 * 60), idleLimit: 5 * 60))
        XCTAssertFalse(KeepAlivePolicy.plays(waitingSince: start, now: start.addingTimeInterval(11 * 60), idleLimit: 5 * 60),
                       "a shorter setting than the old ten minutes wins")
    }

    func testNeverKeepsPlaying() {
        XCTAssertTrue(KeepAlivePolicy.plays(waitingSince: start, now: start.addingTimeInterval(30 * 86_400), idleLimit: nil),
                      "the Never setting plays until the hotspot comes back")
        XCTAssertTrue(KeepAlivePolicy.plays(waitingSince: nil, now: start, idleLimit: nil))
    }

    func testABackgroundWakeIsRarerThanOnScreen() {
        XCTAssertEqual(KeepAlivePolicy.watchInterval(sceneActive: true).every, .seconds(5))
        XCTAssertEqual(KeepAlivePolicy.watchInterval(sceneActive: false).every, .seconds(15))
    }
}
