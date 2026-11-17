import XCTest
@testable import TetherCore

final class BackupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var settings: FerryBackup.SettingsEntry {
        FerryBackup.SettingsEntry(idleTimeoutMinutes: 10, batteryThresholdPercent: 0,
                                  notifyJoins: true, notifyLeaves: true, notifyStopped: true,
                                  approvalMode: false, billingDay: 15, monthlyCapBytes: nil)
    }

    private func peerEntry(name: String = "iPad", address: String = "10.7.0.2",
                           publicKey: Data = Data(repeating: 7, count: 32)) -> FerryBackup.PeerEntry {
        FerryBackup.PeerEntry(id: UUID(), name: name, publicKey: publicKey,
                              privateKey: Data(repeating: 9, count: 32), address: address,
                              kind: "ipad", approval: "approved", capBytes: nil,
                              downLimitBps: nil, upLimitBps: nil, expiresAt: nil,
                              pausedUntil: nil, guestConsumed: false)
    }

    private func backup(peers: [FerryBackup.PeerEntry], serverKey: Data? = Data(repeating: 3, count: 32),
                        version: Int = 1, denied: [Data] = []) -> FerryBackup {
        FerryBackup(formatVersion: version, appVersion: "1.2.0", createdAt: now, includesKeys: serverKey != nil,
                    serverPrivateKey: serverKey, peers: peers, deniedKeys: denied, settings: settings)
    }

    func testAValidBackupRestores() throws {
        let doc = try backup(peers: [peerEntry()]).validated()
        let setup = try doc.makeSetup(currentDeniedKeys: [], now: now)
        XCTAssertEqual(setup.serverPrivateKey, Data(repeating: 3, count: 32))
        XCTAssertEqual(setup.peers.count, 1)
        XCTAssertEqual(setup.peers[0].name, "iPad")
        XCTAssertEqual(setup.peers[0].address, "10.7.0.2")
        XCTAssertNotNil(setup.ready, "a restored setup makes a fresh ready device")
    }

    func testMakingABackupFromASetup() throws {
        var setup = WireGuardSetup.new()
        let peer = setup.addPeer(name: "iPad")!
        setup.prepareReady()
        let doc = FerryBackup.make(from: setup, settings: settings, includesKeys: true, appVersion: "1.2.0", now: now)
        XCTAssertEqual(doc.peers.map(\.id), [peer.id], "the ready device is not exported")
        XCTAssertEqual(doc.peers[0].privateKey, peer.privateKey)
        let plain = FerryBackup.make(from: setup, settings: settings, includesKeys: false, appVersion: "1.2.0", now: now)
        XCTAssertNil(plain.serverPrivateKey, "the plain export holds no keys")
        XCTAssertNil(plain.peers[0].privateKey)
        XCTAssertEqual(plain.peers[0].publicKey, peer.publicKey, "public keys aren't secret")
    }

    func testAnUnknownVersionIsRejected() {
        XCTAssertThrowsError(try backup(peers: [], version: 2).validated()) { error in
            XCTAssertEqual(error as? BackupError, .unsupportedVersion(2))
        }
    }

    func testBadKeysAreRejected() {
        XCTAssertThrowsError(try backup(peers: [peerEntry(publicKey: Data(repeating: 1, count: 16))]).validated()) {
            XCTAssertEqual($0 as? BackupError, .badPeerKey(name: "iPad"))
        }
        XCTAssertThrowsError(try backup(peers: [], serverKey: Data(repeating: 1, count: 8)).validated()) {
            XCTAssertEqual($0 as? BackupError, .badServerKey)
        }
        var shortPrivate = peerEntry()
        shortPrivate.privateKey = Data(repeating: 1, count: 4)
        XCTAssertThrowsError(try backup(peers: [shortPrivate]).validated()) {
            XCTAssertEqual($0 as? BackupError, .badPeerKey(name: "iPad"))
        }
        XCTAssertThrowsError(try backup(peers: [], denied: [Data(repeating: 1, count: 3)]).validated()) {
            XCTAssertEqual($0 as? BackupError, .badDeniedKey)
        }
    }

    func testAddressesMustBeOneTunnelAddressEach() {
        for bad in ["0.0.0.0", "0.0.0.0/0", "10.7.0.2/32", "10.7.0.1", "10.7.0.255", "10.7.1.2",
                    "192.168.1.5", "10.7.0.300", "10.7.0", "10.7.0.02", "10.7.0.2 ", "a.b.c.d", ""] {
            XCTAssertThrowsError(try backup(peers: [peerEntry(address: bad)]).validated(),
                                 "address \(bad) must be refused") {
                XCTAssertEqual($0 as? BackupError, .badAddress(bad))
            }
        }
        XCTAssertNoThrow(try backup(peers: [peerEntry(address: "10.7.0.254")]).validated())
    }

    func testDuplicateAddressesAreRejected() {
        // wireguard-go gives a shared prefix to the last device added with it, so a
        // duplicate would silently hand one device's traffic to another.
        let a = peerEntry(address: "10.7.0.2")
        var b = peerEntry(name: "Mac", address: "10.7.0.2")
        b.publicKey = Data(repeating: 8, count: 32)
        XCTAssertThrowsError(try backup(peers: [a, b]).validated()) {
            XCTAssertEqual($0 as? BackupError, .duplicateAddress("10.7.0.2"))
        }
    }

    func testNamesAreSanitizedSoAPlantedFileCantInjectLines() throws {
        // A name is free text in the file. A newline in one is how it would try to
        // inject a line into a config; validation strips control characters.
        let doc = try backup(peers: [peerEntry(name: "Evil\nreplace_peers=true")]).validated()
        XCTAssertEqual(doc.peers[0].name, "Evilreplace_peers=true")
        XCTAssertFalse(doc.peers[0].name.contains("\n"))
        XCTAssertEqual(BackupValidation.sanitizedName("  A\r\nB  "), "AB")
        XCTAssertEqual(BackupValidation.sanitizedName(String(repeating: "x", count: 100)).count, 40)
        XCTAssertEqual(BackupValidation.sanitizedName("   "), "Device")
        XCTAssertEqual(BackupValidation.sanitizedName("Kitchen iPad"), "Kitchen iPad")
    }

    func testUnknownKindsAndApprovalsAreRejected() {
        var badKind = peerEntry()
        badKind.kind = "toaster"
        XCTAssertThrowsError(try backup(peers: [badKind]).validated()) {
            XCTAssertEqual($0 as? BackupError, .badValue(field: "kind"))
        }
        var badApproval = peerEntry()
        badApproval.approval = "maybe"
        XCTAssertThrowsError(try backup(peers: [badApproval]).validated()) {
            XCTAssertEqual($0 as? BackupError, .badValue(field: "approval"))
        }
    }

    func testASettingsOnlyBackupCantMakeASetup() throws {
        let doc = try backup(peers: [peerEntry()], serverKey: nil).validated()
        XCTAssertThrowsError(try doc.makeSetup(currentDeniedKeys: [], now: now)) {
            XCTAssertEqual($0 as? BackupError, .settingsOnly)
        }
    }

    func testTheDenylistIsMergedAndWins() throws {
        let deniedKey = Data(repeating: 7, count: 32) // the peer entry's key
        let otherDenied = Data(repeating: 42, count: 32)
        let doc = try backup(peers: [peerEntry()], denied: [otherDenied]).validated()
        let setup = try doc.makeSetup(currentDeniedKeys: [deniedKey], now: now)
        XCTAssertTrue(setup.peers.isEmpty, "a device denied since the backup stays out")
        XCTAssertEqual(Set(setup.deniedKeys), [deniedKey, otherDenied], "the lists are unioned, never replaced")
    }

    func testExpiredGuestsAreDroppedAndUsedGuestPassesComeBackUsed() throws {
        var expired = peerEntry(name: "Old guest")
        expired.expiresAt = now.addingTimeInterval(-3600)
        var guest = peerEntry(name: "Guest", address: "10.7.0.3")
        guest.publicKey = Data(repeating: 11, count: 32)
        guest.privateKey = nil
        guest.guestConsumed = true
        guest.expiresAt = now.addingTimeInterval(3600)
        let setup = try backup(peers: [expired, guest]).validated().makeSetup(currentDeniedKeys: [], now: now)
        XCTAssertEqual(setup.peers.map(\.name), ["Guest"], "the expired guest is dropped")
        XCTAssertNotNil(setup.peers[0].guestPass?.consumedAt, "a used guest pass comes back used")
        XCTAssertEqual(setup.peers[0].guestPass?.accessExpiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(setup.peers[0].privateKey, Data(), "and keyless")
    }

    func testEncryptionRoundTrips() throws {
        let plain = Data("the backup document".utf8)
        let sealed = try BackupCrypto.seal(plain, password: "correct horse", iterations: 1_000)
        XCTAssertTrue(BackupCrypto.isEncrypted(sealed))
        XCTAssertFalse(BackupCrypto.isEncrypted(plain))
        XCTAssertEqual(try BackupCrypto.open(sealed, password: "correct horse"), plain)
        XCTAssertThrowsError(try BackupCrypto.open(sealed, password: "wrong")) {
            XCTAssertEqual($0 as? BackupError, .wrongPasswordOrCorrupt)
        }
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0xff
        XCTAssertThrowsError(try BackupCrypto.open(tampered, password: "correct horse"),
                             "a changed byte fails the GCM tag") {
            XCTAssertEqual($0 as? BackupError, .wrongPasswordOrCorrupt)
        }
        XCTAssertThrowsError(try BackupCrypto.open(plain, password: "x")) {
            XCTAssertEqual($0 as? BackupError, .notABackup)
        }
    }
}

final class SessionRecordTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(seconds: TimeInterval, used: UInt64 = 0, reason: String? = nil) -> SessionRecord {
        var record = SessionRecord(startedAt: start, lastHeartbeatAt: start.addingTimeInterval(seconds))
        if used > 0 { record.perPeer["a"] = DeviceUsage(up: 0, down: used) }
        record.endedAt = start.addingTimeInterval(seconds)
        record.endReason = reason
        return record
    }

    func testShortOrEmptySessionsDontPost() {
        XCTAssertFalse(SessionSummary.shouldPost(record(seconds: 59, used: 1_000), now: start))
        XCTAssertFalse(SessionSummary.shouldPost(record(seconds: 3_600, used: 0), now: start),
                       "an hour of nothing is still nothing")
        XCTAssertTrue(SessionSummary.shouldPost(record(seconds: 60, used: 1), now: start))
    }

    func testDevicesMeansDevicesThatMovedData() {
        var record = SessionRecord(startedAt: start, lastHeartbeatAt: start)
        record.perPeer["a"] = DeviceUsage(up: 0, down: 10)
        record.perPeer["b"] = DeviceUsage()
        record.perPeer["c"] = DeviceUsage(up: 5, down: 0)
        XCTAssertEqual(record.devicesWithTraffic, 2, "a handshake alone doesn't count")
        XCTAssertEqual(record.totalUsage, DeviceUsage(up: 5, down: 10))
    }

    func testAnUnexpectedSessionClosesAtItsLastHeartbeat() {
        var open = SessionRecord(startedAt: start, lastHeartbeatAt: start.addingTimeInterval(600))
        open.perPeer["a"] = DeviceUsage(up: 0, down: 10)
        let closed = open.closedUnexpectedly()
        XCTAssertEqual(closed.endedAt, start.addingTimeInterval(600))
        XCTAssertEqual(closed.endReason, "unexpected")
        XCTAssertEqual(SessionSummary.title(closed), "Ferry stopped unexpectedly")
        XCTAssertTrue(SessionSummary.body(closed, now: start).contains("It stopped at"),
                      SessionSummary.body(closed, now: start))
    }

    func testStaleness() {
        let fresh = SessionRecord(startedAt: start, lastHeartbeatAt: start)
        XCTAssertFalse(fresh.isStale(now: start.addingTimeInterval(3600)))
        XCTAssertTrue(fresh.isStale(now: start.addingTimeInterval(25 * 3600)))
        var closed = fresh
        closed.endedAt = start
        XCTAssertFalse(closed.isStale(now: start.addingTimeInterval(48 * 3600)), "a closed record isn't stale, it's history")
    }

    func testDurationText() {
        XCTAssertEqual(SessionSummary.durationText(45 * 60), "45 min")
        XCTAssertEqual(SessionSummary.durationText(2 * 3600 + 5 * 60), "2 h 5 min")
        XCTAssertEqual(SessionSummary.durationText(2 * 3600), "2 h")
        XCTAssertEqual(SessionSummary.durationText(26 * 3600), "1 d 2 h")
        XCTAssertEqual(SessionSummary.durationText(24 * 3600), "1 d")
        XCTAssertEqual(SessionSummary.durationText(30), "1 min", "never zero minutes")
    }

    func testTheBody() {
        let body = SessionSummary.body(record(seconds: 3_900, used: 2_000_000), now: start)
        XCTAssertTrue(body.contains("1 h 5 min"), body)
        XCTAssertTrue(body.contains("1 device"), body)
        XCTAssertTrue(body.contains("used."), body)
    }
}
