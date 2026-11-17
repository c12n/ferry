import XCTest
@testable import TetherCore

/// The 1.2 peer model: timed pauses, approval, speed limits, one-time guest
/// passes, denied keys, and what setups saved by 1.1.x decode to.
final class PeerV2Tests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A setup JSON as 1.1.x saved it, edited from a current one: the peer has the
    /// old `paused`/`pauseReason` pair and none of the 1.2 keys.
    private func oldJSON(paused: Bool, reason: String?) throws -> Data {
        var setup = WireGuardSetup.new()
        _ = setup.addPeer(name: "iPad")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(setup)) as? [String: Any])
        var peers = try XCTUnwrap(object["peers"] as? [[String: Any]])
        for key in ["pausedUntil", "approval", "downLimitBps", "upLimitBps", "guestPass"] {
            peers[0].removeValue(forKey: key)
        }
        peers[0]["paused"] = paused
        if let reason { peers[0]["pauseReason"] = reason } else { peers[0].removeValue(forKey: "pauseReason") }
        object["peers"] = peers
        object.removeValue(forKey: "deniedKeys")
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testAManualPauseFrom111StaysPaused() throws {
        let decoded = try JSONDecoder().decode(WireGuardSetup.self, from: oldJSON(paused: true, reason: "manual"))
        XCTAssertEqual(decoded.peers[0].pausedUntil, .distantFuture, "a hand pause has no end date")
        XCTAssertTrue(decoded.peers[0].isPaused(now: now))
    }

    func testACapPauseFrom111IsNotCarriedOver() throws {
        // Caps are worked out from usage now, not stored: carrying the pause over
        // would keep the device paused tomorrow even under its cap.
        let decoded = try JSONDecoder().decode(WireGuardSetup.self, from: oldJSON(paused: true, reason: "cap"))
        XCTAssertNil(decoded.peers[0].pausedUntil)
    }

    func testAnUnpausedDeviceFrom111DecodesClean() throws {
        let decoded = try JSONDecoder().decode(WireGuardSetup.self, from: oldJSON(paused: false, reason: nil))
        let peer = try XCTUnwrap(decoded.peers.first)
        XCTAssertNil(peer.pausedUntil)
        XCTAssertEqual(peer.approval, .approved, "devices paired before approval mode are approved")
        XCTAssertNil(peer.downLimitBps)
        XCTAssertNil(peer.upLimitBps)
        XCTAssertNil(peer.guestPass)
        XCTAssertTrue(decoded.deniedKeys.isEmpty)
    }

    func testTimedPauseSemantics() throws {
        var setup = WireGuardSetup.new()
        let peer = try XCTUnwrap(setup.addPeer(name: "iPad"))
        XCTAssertFalse(peer.isPaused(now: now))
        setup.setPeerPausedUntil(peer.id, now.addingTimeInterval(900))
        XCTAssertTrue(setup.peers[0].isPaused(now: now))
        XCTAssertFalse(setup.peers[0].isPaused(now: now.addingTimeInterval(901)), "over by time passing alone")
        setup.setPeerPausedUntil(peer.id, nil)
        XCTAssertFalse(setup.peers[0].isPaused(now: now), "resumed")
    }

    func testAPausedDeviceStaysInTheServersPeers() throws {
        // Pausing no longer removes the device from the server (that reset its
        // counters and forced a new handshake). It stays, and the policy layer
        // blocks it; see AccessControl and WireGuard's policies.
        var setup = WireGuardSetup.new()
        let peer = try XCTUnwrap(setup.addPeer(name: "iPad"))
        setup.setPeerPausedUntil(peer.id, .distantFuture)
        XCTAssertTrue(setup.serverPeers.contains { $0.id == peer.id })
    }

    func testClaimingBlanksTheClientKey() throws {
        var setup = WireGuardSetup.new()
        setup.prepareReady()
        let ready = try XCTUnwrap(setup.ready)
        XCTAssertEqual(ready.privateKey.count, 32)
        XCTAssertTrue(setup.claimReady(address: ready.address))
        XCTAssertEqual(setup.peers[0].privateKey, Data(), "once a device has connected, its key is no longer saved")
    }

    func testClaimingWithApprovalModeWaits() throws {
        var setup = WireGuardSetup.new()
        setup.prepareReady()
        let ready = try XCTUnwrap(setup.ready)
        XCTAssertTrue(setup.claimReady(address: ready.address, approval: .pending))
        XCTAssertEqual(setup.peers[0].approval, .pending)
        setup.setPeerApproval(setup.peers[0].id, .approved)
        XCTAssertEqual(setup.peers[0].approval, .approved)
    }

    func testTheFingerprintIsStableAndShort() throws {
        var setup = WireGuardSetup.new()
        let peer = try XCTUnwrap(setup.addPeer(name: "iPad"))
        XCTAssertEqual(peer.keyFingerprint.count, 8)
        XCTAssertEqual(peer.keyFingerprint, peer.keyFingerprint)
        XCTAssertTrue(peer.keyFingerprint.allSatisfy { $0.isHexDigit })
    }

    // MARK: guest passes

    func testAGuestPassSavesNoKey() throws {
        var setup = WireGuardSetup.new()
        let shown = try XCTUnwrap(setup.addGuestPass(qrExpiresAt: now.addingTimeInterval(600),
                                                     accessExpiresAt: now.addingTimeInterval(4 * 3600)))
        XCTAssertEqual(shown.privateKey.count, 32, "the caller gets the key, in memory only")
        let saved = try XCTUnwrap(setup.peers.first { $0.id == shown.id })
        XCTAssertEqual(saved.privateKey, Data(), "the saved copy has no key, so the code can't be shown again")
        XCTAssertEqual(saved.guestPass?.qrExpiresAt, now.addingTimeInterval(600))
        XCTAssertNil(saved.guestPass?.consumedAt)
        XCTAssertEqual(setup.unusedGuestPassCount, 1)
        XCTAssertEqual(saved.name, "Guest")
    }

    func testAUsedGuestPassStopsAtItsAccessDate() throws {
        var setup = WireGuardSetup.new()
        let shown = try XCTUnwrap(setup.addGuestPass(qrExpiresAt: now.addingTimeInterval(600),
                                                     accessExpiresAt: now.addingTimeInterval(3600)))
        setup.consumeGuestPass(shown.id, at: now)
        XCTAssertEqual(setup.unusedGuestPassCount, 0)
        XCTAssertFalse(setup.peers[0].isExpired(now: now.addingTimeInterval(3599)))
        XCTAssertTrue(setup.peers[0].isExpired(now: now.addingTimeInterval(3600)), "a used pass ends like a guest")
    }

    func testAnUnusedGuestPassIsPrunedAndDenied() throws {
        var setup = WireGuardSetup.new()
        let shown = try XCTUnwrap(setup.addGuestPass(qrExpiresAt: now.addingTimeInterval(600),
                                                     accessExpiresAt: now.addingTimeInterval(3600)))
        XCTAssertTrue(setup.pruneLapsedGuestPasses(now: now.addingTimeInterval(599)).isEmpty, "not before the deadline")
        let removed = setup.pruneLapsedGuestPasses(now: now.addingTimeInterval(600))
        XCTAssertEqual(removed.map(\.id), [shown.id])
        XCTAssertTrue(setup.peers.isEmpty)
        XCTAssertTrue(setup.isDenied(shown.publicKey), "a photographed code can never be used late")
    }

    func testAUsedGuestPassIsNotPruned() throws {
        var setup = WireGuardSetup.new()
        let shown = try XCTUnwrap(setup.addGuestPass(qrExpiresAt: now.addingTimeInterval(600),
                                                     accessExpiresAt: now.addingTimeInterval(3600)))
        setup.consumeGuestPass(shown.id, at: now)
        XCTAssertTrue(setup.pruneLapsedGuestPasses(now: now.addingTimeInterval(700)).isEmpty)
        XCTAssertEqual(setup.peers.count, 1)
    }

    func testDeniedKeysRoundTrip() throws {
        var setup = WireGuardSetup.new()
        let peer = try XCTUnwrap(setup.addPeer(name: "iPad"))
        setup.denyKey(peer.publicKey)
        setup.denyKey(peer.publicKey)
        XCTAssertEqual(setup.deniedKeys.count, 1, "denying twice is denying once")
        let data = try JSONEncoder().encode(setup)
        let decoded = try JSONDecoder().decode(WireGuardSetup.self, from: data)
        XCTAssertTrue(decoded.isDenied(peer.publicKey))
    }

    func testSpeedLimitsRoundTrip() throws {
        var setup = WireGuardSetup.new()
        let peer = try XCTUnwrap(setup.addPeer(name: "iPad"))
        setup.setPeerSpeedLimits(peer.id, down: 625_000, up: 125_000)
        let data = try JSONEncoder().encode(setup)
        let decoded = try JSONDecoder().decode(WireGuardSetup.self, from: data)
        XCTAssertEqual(decoded.peers[0].downLimitBps, 625_000)
        XCTAssertEqual(decoded.peers[0].upLimitBps, 125_000)
    }

    func testTheStoreSavesAGuestPassWithoutItsKey() throws {
        let secrets = InMemorySecrets()
        let devices = WireGuardDevices(secrets: secrets)
        let shown = try XCTUnwrap(devices.addGuestPass(qrExpiresAt: now.addingTimeInterval(600),
                                                       accessExpiresAt: now.addingTimeInterval(3600)))
        XCTAssertEqual(shown.privateKey.count, 32)
        let reloaded = WireGuardDevices(secrets: secrets).setup
        XCTAssertEqual(reloaded.peers.first?.privateKey, Data(), "not in the saved setup either")
        XCTAssertTrue(devices.consumeGuestPass(shown.id, at: now))
        XCTAssertNotNil(WireGuardDevices(secrets: secrets).setup.peers[0].guestPass?.consumedAt)
    }
}
