import XCTest
@testable import TetherCore

final class UsageTests: XCTestCase {
    private let day1 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!
    private let day2 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 1))!

    func testTheFirstReadingIsABaselineOnly() {
        var tracker = UsageTracker(now: day1)
        tracker.record(["a": DeviceUsage(up: 100, down: 900)], now: day1)
        XCTAssertEqual(tracker.todayUsage(for: "a"), DeviceUsage())
        XCTAssertEqual(tracker.sessionUsage(for: "a"), DeviceUsage())
        XCTAssertEqual(tracker.allTimeUsage(for: "a"), DeviceUsage())
    }

    func testDeltasAccumulateIntoSessionTodayAndAllTime() {
        var tracker = UsageTracker(now: day1)
        tracker.record(["a": DeviceUsage(up: 100, down: 900)], now: day1)
        tracker.record(["a": DeviceUsage(up: 150, down: 1_400)], now: day1)
        tracker.record(["b": DeviceUsage(up: 10, down: 10)], now: day1)
        tracker.record(["b": DeviceUsage(up: 30, down: 60)], now: day1)
        let expected = DeviceUsage(up: 50, down: 500)
        XCTAssertEqual(tracker.todayUsage(for: "a"), expected)
        XCTAssertEqual(tracker.sessionUsage(for: "a"), expected)
        XCTAssertEqual(tracker.allTimeUsage(for: "a"), expected)
        XCTAssertEqual(tracker.todayTotal(), DeviceUsage(up: 70, down: 550))
        XCTAssertEqual(tracker.sessionTotal(), DeviceUsage(up: 70, down: 550))
    }

    func testAReadingThatGoesBackwardsCountsInFull() {
        // The counter restarted (a device's Go counters reset when it leaves the server),
        // so what the new counter shows is all new traffic.
        var tracker = UsageTracker(now: day1)
        tracker.record(["a": DeviceUsage(up: 1_000, down: 1_000)], now: day1)
        tracker.record(["a": DeviceUsage(up: 25, down: 30)], now: day1)
        XCTAssertEqual(tracker.todayUsage(for: "a"), DeviceUsage(up: 25, down: 30))
    }

    func testTodayRestartsOnANewDayButAllTimeDoesNot() {
        var tracker = UsageTracker(now: day1)
        tracker.record(["a": DeviceUsage(up: 0, down: 0)], now: day1)
        tracker.record(["a": DeviceUsage(up: 100, down: 100)], now: day1)
        let rolled = tracker.record(["a": DeviceUsage(up: 150, down: 150)], now: day2)
        XCTAssertTrue(rolled, "the caller lifts cap pauses on a rollover")
        XCTAssertEqual(tracker.todayUsage(for: "a"), DeviceUsage(up: 50, down: 50), "only the new day's delta")
        XCTAssertEqual(tracker.allTimeUsage(for: "a"), DeviceUsage(up: 150, down: 150))
        XCTAssertEqual(tracker.sessionUsage(for: "a"), DeviceUsage(up: 150, down: 150), "a session can span midnight")
        XCTAssertFalse(tracker.record(["a": DeviceUsage(up: 150, down: 150)], now: day2), "no second rollover the same day")
    }

    func testASessionRestartZeroesOnlyTheSession() {
        var tracker = UsageTracker(now: day1)
        tracker.record(["a": DeviceUsage(up: 100, down: 100)], now: day1)
        tracker.record(["a": DeviceUsage(up: 200, down: 200)], now: day1)
        tracker.startSession()
        XCTAssertEqual(tracker.sessionUsage(for: "a"), DeviceUsage())
        XCTAssertEqual(tracker.todayUsage(for: "a"), DeviceUsage(up: 100, down: 100))
        // The first reading of the new session is a baseline again, so the gap between
        // sessions is never counted.
        tracker.record(["a": DeviceUsage(up: 900, down: 900)], now: day1)
        XCTAssertEqual(tracker.sessionUsage(for: "a"), DeviceUsage())
        tracker.record(["a": DeviceUsage(up: 950, down: 950)], now: day1)
        XCTAssertEqual(tracker.sessionUsage(for: "a"), DeviceUsage(up: 50, down: 50))
    }

    func testForgetRemovesADeviceEverywhere() {
        var tracker = UsageTracker(now: day1)
        tracker.record(["a": DeviceUsage(up: 100, down: 100)], now: day1)
        tracker.record(["a": DeviceUsage(up: 200, down: 200)], now: day1)
        tracker.forget("a")
        XCTAssertEqual(tracker.todayUsage(for: "a"), DeviceUsage())
        XCTAssertEqual(tracker.allTimeUsage(for: "a"), DeviceUsage())
        XCTAssertEqual(tracker.todayTotal(), DeviceUsage())
    }

    func testTheStoreRoundTrips() {
        let defaults = UserDefaults(suiteName: "tether.tests.usage")!
        defaults.removePersistentDomain(forName: "tether.tests.usage")
        var tracker = UsageStore.load(from: defaults)
        tracker.record(["a": DeviceUsage(up: 1, down: 2)], now: day1)
        tracker.record(["a": DeviceUsage(up: 4, down: 8)], now: day1)
        UsageStore.save(tracker, to: defaults)
        let loaded = UsageStore.load(from: defaults)
        XCTAssertEqual(loaded.todayUsage(for: "a"), DeviceUsage(up: 3, down: 6))
        XCTAssertEqual(loaded.allTimeUsage(for: "a"), DeviceUsage(up: 3, down: 6))
    }

    func testCaps() {
        XCTAssertFalse(UsageTracker.capReached(usedToday: 1_000_000, capBytes: nil), "no cap never trips")
        XCTAssertFalse(UsageTracker.capReached(usedToday: 1_000_000, capBytes: 0), "a zero cap is off")
        XCTAssertFalse(UsageTracker.capReached(usedToday: 999, capBytes: 1_000))
        XCTAssertTrue(UsageTracker.capReached(usedToday: 1_000, capBytes: 1_000), "reaching it exactly trips it")
        XCTAssertTrue(UsageTracker.capReached(usedToday: 1_001, capBytes: 1_000))
    }

    func testDelta() {
        XCTAssertEqual(UsageTracker.delta(new: 10, old: 4), 6)
        XCTAssertEqual(UsageTracker.delta(new: 4, old: 4), 0)
        XCTAssertEqual(UsageTracker.delta(new: 4, old: 10), 4)
    }
}

final class WidgetSnapshotTests: XCTestCase {
    func testTheSnapshotRoundTripsThroughDefaults() {
        let defaults = UserDefaults(suiteName: "tether.tests.widget")!
        defaults.removePersistentDomain(forName: "tether.tests.widget")
        XCTAssertNil(WidgetSnapshotStore.load(from: defaults), "nothing saved is the widget's placeholder state")
        let snapshot = WidgetSnapshot(isSharing: true, connectedDevices: 2, downSpeed: 1_000_000,
                                      upSpeed: 250_000, usageToday: 42, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        WidgetSnapshotStore.save(snapshot, to: defaults)
        XCTAssertEqual(WidgetSnapshotStore.load(from: defaults), snapshot)
    }
}

final class BatteryGuardTests: XCTestCase {
    func testOffNeverStopsOrWarns() {
        XCTAssertFalse(BatteryGuard.shouldStop(level: 0.05, isCharging: false, thresholdPercent: 0))
        XCTAssertFalse(BatteryGuard.shouldWarn(level: 0.05, isCharging: false, thresholdPercent: 0))
    }

    func testChargingNeverStopsOrWarns() {
        XCTAssertFalse(BatteryGuard.shouldStop(level: 0.10, isCharging: true, thresholdPercent: 30))
        XCTAssertFalse(BatteryGuard.shouldWarn(level: 0.35, isCharging: true, thresholdPercent: 30))
    }

    func testItStopsAtAndBelowTheThreshold() {
        XCTAssertFalse(BatteryGuard.shouldStop(level: 0.31, isCharging: false, thresholdPercent: 30))
        XCTAssertTrue(BatteryGuard.shouldStop(level: 0.30, isCharging: false, thresholdPercent: 30))
        XCTAssertTrue(BatteryGuard.shouldStop(level: 0.12, isCharging: false, thresholdPercent: 30))
    }

    func testTheWarningBandIsTenPointsAboveTheStop() {
        XCTAssertFalse(BatteryGuard.shouldWarn(level: 0.41, isCharging: false, thresholdPercent: 30))
        XCTAssertTrue(BatteryGuard.shouldWarn(level: 0.40, isCharging: false, thresholdPercent: 30))
        XCTAssertTrue(BatteryGuard.shouldWarn(level: 0.31, isCharging: false, thresholdPercent: 30))
        XCTAssertFalse(BatteryGuard.shouldWarn(level: 0.30, isCharging: false, thresholdPercent: 30), "at the stop level it stops instead")
    }

    func testAnUnknownLevelNeverStopsAnything() {
        XCTAssertFalse(BatteryGuard.shouldStop(level: -1, isCharging: false, thresholdPercent: 50))
        XCTAssertFalse(BatteryGuard.shouldWarn(level: -1, isCharging: false, thresholdPercent: 50))
    }

    func testRecoveryNeedsChargingOrClearWaterAboveTheThreshold() {
        XCTAssertTrue(BatteryGuard.recovered(level: 0.10, isCharging: true, thresholdPercent: 30))
        XCTAssertFalse(BatteryGuard.recovered(level: 0.34, isCharging: false, thresholdPercent: 30))
        XCTAssertTrue(BatteryGuard.recovered(level: 0.36, isCharging: false, thresholdPercent: 30))
        XCTAssertFalse(BatteryGuard.recovered(level: -1, isCharging: false, thresholdPercent: 30))
    }
}
