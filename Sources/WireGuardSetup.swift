import CryptoKit
import Foundation
import Security

/// Where Ferry listens. The hotspot always gives the iPhone 172.20.10.1.
enum Hotspot {
    static let host = "172.20.10.1"
}

/// The WireGuard way in: each device gets its own key and an address inside the tunnel, and
/// imports a config that points at the hotspot. WireGuardServer.swift runs the server side.
/// Foundation only, so `swift test` covers it.
struct WireGuardSetup: Codable, Equatable {
    static let port: UInt16 = 51820
    /// The same as MTU in WireGuard/server.go.
    static let mtu = 1420
    static let dns = "1.1.1.1"
    private static let subnet = "10.7.0."

    /// Whether a device may pass traffic without asking first. Devices paired before
    /// approval mode existed are `.approved`; a device that connects while approval mode
    /// is on waits as `.pending` until the person approves it (see AccessControl). There
    /// is no saved "denied" state: denying a device removes it and denies its key.
    enum Approval: String, Codable {
        case pending, approved
    }

    /// A one-time guest pass: a QR code made for one device, usable once. The device's
    /// private key is never saved (see `addGuestPass`), so the code can't be shown again
    /// or backed up; these dates are all that persists.
    struct GuestPass: Codable, Hashable {
        /// An unused code stops working at this date, minutes after it was made.
        var qrExpiresAt: Date
        /// Access ends at this date, used or not.
        var accessExpiresAt: Date
        /// When a device first connected with the code. Nil while unused.
        var consumedAt: Date?
    }

    /// What a device is, picked on its screen; only its list icon depends on it.
    enum Kind: String, Codable, CaseIterable {
        case iphone, ipad, mac, router, other

        /// The SF Symbol the device list shows for it.
        var symbol: String {
            switch self {
            case .iphone: return "iphone"
            case .ipad: return "ipad"
            case .mac: return "laptopcomputer"
            case .router: return "wifi.router"
            case .other: return "personalhotspot"
            }
        }

        var label: String {
            switch self {
            case .iphone: return "iPhone"
            case .ipad: return "iPad"
            case .mac: return "Mac"
            case .router: return "Router"
            case .other: return "Other"
            }
        }
    }

    struct Peer: Codable, Hashable, Identifiable {
        var id = UUID()
        var name: String
        /// The device's key, kept so its QR code can be shown again, until the device
        /// first connects: from then on it is blanked (see `claimReady`), so a saved
        /// setup, and any backup of it, holds no client keys. A guest pass's key is
        /// never saved at all. It's only ever used inside the tunnel.
        var privateKey: Data
        var publicKey: Data
        var address: String
        /// A guest device is removed for good at this date. Nil is permanent access.
        var expiresAt: Date?
        /// The device is paused until this date; `.distantFuture` is "until resumed by
        /// hand". Nil is not paused. Only the date persists, so a timed pause ends by
        /// time passing, with nothing needing to run (see AccessControl).
        var pausedUntil: Date?
        /// Whether the device may pass traffic without being approved first.
        var approval: Approval = .approved
        /// The most the device may use today, up and down together, in bytes. Nil is no cap.
        /// Reaching it blocks the device until tomorrow (see AccessControl); the block
        /// is worked out from usage, never stored.
        var capBytes: UInt64?
        /// Speed limits in bytes per second: down is to the device, up is from it.
        /// Nil is no limit. Enforced where the traffic is forwarded, in WireGuard/.
        var downLimitBps: UInt64?
        var upLimitBps: UInt64?
        /// What the device is, for its list icon. `.other` until someone picks.
        var kind: Kind = .other
        /// Set for a one-time guest pass device (see `addGuestPass`).
        var guestPass: GuestPass?

        /// Has the guest's time run out by `now`? A guest pass that was used stops at
        /// its access date, like a guest's own date.
        func isExpired(now: Date) -> Bool {
            if expiresAt.map({ $0 <= now }) ?? false { return true }
            if let pass = guestPass, pass.consumedAt != nil, pass.accessExpiresAt <= now { return true }
            return false
        }

        /// Paused at `now`: a pause whose date has passed is over by itself.
        func isPaused(now: Date) -> Bool {
            pausedUntil.map { $0 > now } ?? false
        }

        /// A short fingerprint of the public key, the first four bytes as hex. A
        /// notification action carries it, so acting on a stale notification for a
        /// device whose key has since changed does nothing.
        var keyFingerprint: String {
            publicKey.prefix(4).map { String(format: "%02x", $0) }.joined()
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, privateKey, publicKey, address, expiresAt, paused, pauseReason, pausedUntil
            case approval, capBytes, downLimitBps, upLimitBps, kind, guestPass
        }

        /// Setups saved before guests, pausing and caps existed have none of those keys, and
        /// an upgrade must not lose the devices in them: the new fields decode as absent.
        /// (`paused` needs this by hand — a non-optional field's default doesn't apply to a
        /// synthesized decoder.)
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            id = try box.decode(UUID.self, forKey: .id)
            name = try box.decode(String.self, forKey: .name)
            privateKey = try box.decode(Data.self, forKey: .privateKey)
            publicKey = try box.decode(Data.self, forKey: .publicKey)
            address = try box.decode(String.self, forKey: .address)
            expiresAt = try box.decodeIfPresent(Date.self, forKey: .expiresAt)
            pausedUntil = try box.decodeIfPresent(Date.self, forKey: .pausedUntil)
            if pausedUntil == nil {
                // Setups saved before timed pauses kept a flag and a reason. A manual
                // pause stays a pause with no end date. A data-cap pause is not carried
                // over: caps are worked out from usage now, not stored, so a device
                // still over its cap today is blocked by the cap itself, and only today.
                let wasPaused = try box.decodeIfPresent(Bool.self, forKey: .paused) ?? false
                let reason = try box.decodeIfPresent(String.self, forKey: .pauseReason)
                if wasPaused, reason != "cap" { pausedUntil = .distantFuture }
            }
            approval = try box.decodeIfPresent(Approval.self, forKey: .approval) ?? .approved
            capBytes = try box.decodeIfPresent(UInt64.self, forKey: .capBytes)
            downLimitBps = try box.decodeIfPresent(UInt64.self, forKey: .downLimitBps)
            upLimitBps = try box.decodeIfPresent(UInt64.self, forKey: .upLimitBps)
            kind = try box.decodeIfPresent(Kind.self, forKey: .kind) ?? .other
            guestPass = try box.decodeIfPresent(GuestPass.self, forKey: .guestPass)
        }

        /// Hand-written with the decoder (a custom `init(from:)` in the body stops the
        /// synthesized Codable pair, so both halves are here). Optionals encode only
        /// when set, as the synthesized one would have done. The old `paused` flag is
        /// still written, so an older Ferry reading this setup sees the pause too.
        func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(id, forKey: .id)
            try box.encode(name, forKey: .name)
            try box.encode(privateKey, forKey: .privateKey)
            try box.encode(publicKey, forKey: .publicKey)
            try box.encode(address, forKey: .address)
            try box.encodeIfPresent(expiresAt, forKey: .expiresAt)
            try box.encode(pausedUntil != nil, forKey: .paused)
            try box.encodeIfPresent(pausedUntil, forKey: .pausedUntil)
            try box.encode(approval, forKey: .approval)
            try box.encodeIfPresent(capBytes, forKey: .capBytes)
            try box.encodeIfPresent(downLimitBps, forKey: .downLimitBps)
            try box.encodeIfPresent(upLimitBps, forKey: .upLimitBps)
            try box.encode(kind, forKey: .kind)
            try box.encodeIfPresent(guestPass, forKey: .guestPass)
        }

        init(id: UUID = UUID(), name: String, privateKey: Data, publicKey: Data, address: String,
             expiresAt: Date? = nil, pausedUntil: Date? = nil, approval: Approval = .approved,
             capBytes: UInt64? = nil, downLimitBps: UInt64? = nil, upLimitBps: UInt64? = nil,
             kind: Kind = .other, guestPass: GuestPass? = nil) {
            self.id = id
            self.name = name
            self.privateKey = privateKey
            self.publicKey = publicKey
            self.address = address
            self.expiresAt = expiresAt
            self.pausedUntil = pausedUntil
            self.approval = approval
            self.capBytes = capBytes
            self.downLimitBps = downLimitBps
            self.upLimitBps = upLimitBps
            self.kind = kind
            self.guestPass = guestPass
        }
    }

    var serverPrivateKey: Data
    /// The devices someone has used, in the order they first connected.
    var peers: [Peer]
    /// The device behind the QR code on the main screen: a key nobody has used yet. The server lets
    /// it in, and the first time it connects it joins `peers` and a new one takes its place. Nil
    /// only in a setup saved before there was one, or with all 253 addresses taken.
    var ready: Peer?
    /// Public keys that must never be let in again: a device that was denied, a guest
    /// pass code that lapsed unused. Checked wherever a device could come back, above
    /// all when a backup is restored (see Backup.swift).
    var deniedKeys: [Data] = []

    /// Everyone the server lets in: every paired device, and whoever scans the QR code
    /// next. Who may actually pass traffic is a separate question, answered per device
    /// by AccessControl and enforced by the server's policies (see WireGuardServer):
    /// a paused device stays in the server, so its pause can end by time passing, and
    /// an unapproved device stays too, so its arrival shows as a handshake, without
    /// either ever losing its place. A guest whose time is up is taken out of `peers`
    /// itself (see Model), so it isn't filtered here.
    var serverPeers: [Peer] { peers + (ready.map { [$0] } ?? []) }

    var serverPublicKey: Data { Self.publicKey(of: serverPrivateKey) }

    static func new() -> WireGuardSetup {
        WireGuardSetup(serverPrivateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation, peers: [])
    }

    static func publicKey(of privateKey: Data) -> Data {
        (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey))?.publicKey.rawRepresentation ?? Data()
    }

    /// Adds a device with a new key and the lowest free address, or nil when all 253 are taken.
    mutating func addPeer(name: String) -> Peer? {
        guard var peer = newPeer() else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        peer.name = trimmed.isEmpty ? freeName("Device") : trimmed
        peers.append(peer)
        return peer
    }

    /// Makes the ready device when there is none. It keeps its key until someone uses it.
    mutating func prepareReady() {
        if ready == nil { ready = newPeer() }
    }

    /// The ready device connected for the first time from `address`: it's listed from now on, and
    /// a new one is ready for the next device. False when `address` isn't the ready device's.
    /// With approval mode on, the claimed device starts out `.pending` (see AccessControl).
    mutating func claimReady(address: String, approval: Approval = .approved) -> Bool {
        guard var peer = ready, peer.address == address else { return false }
        peer.name = freeName("Device")
        peer.approval = approval
        // The code has been scanned and used; the key has done its job. Blank it, so
        // the saved setup holds no client keys (see Peer.privateKey).
        peer.privateKey = Data()
        peers.append(peer)
        ready = nil
        prepareReady()
        return true
    }

    /// A new key at the lowest address nobody has, the ready device included. Unnamed.
    private func newPeer() -> Peer? {
        let used = Set(serverPeers.map(\.address))
        guard let host = (2...254).first(where: { !used.contains(Self.subnet + String($0)) }) else { return nil }
        let key = Curve25519.KeyAgreement.PrivateKey()
        return Peer(name: "", privateKey: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation,
                    address: Self.subnet + String(host))
    }

    mutating func removePeer(_ id: Peer.ID) {
        peers.removeAll { $0.id == id }
    }

    /// Pauses a device until `until` (`.distantFuture` is until resumed by hand), or
    /// resumes it with nil.
    mutating func setPeerPausedUntil(_ id: Peer.ID, _ until: Date?) {
        guard let i = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[i].pausedUntil = until
    }

    /// Approves a device that was waiting, or sends an approved one back to waiting.
    mutating func setPeerApproval(_ id: Peer.ID, _ approval: Approval) {
        guard let i = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[i].approval = approval
    }

    /// Sets a device's speed limits in bytes per second, or lifts them with nil.
    mutating func setPeerSpeedLimits(_ id: Peer.ID, down: UInt64?, up: UInt64?) {
        guard let i = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[i].downLimitBps = down
        peers[i].upLimitBps = up
    }

    /// Makes a device a guest until `expiresAt`, or permanent again with nil.
    mutating func setPeerExpiry(_ id: Peer.ID, to expiresAt: Date?) {
        guard let i = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[i].expiresAt = expiresAt
    }

    /// Sets the device's daily data cap in bytes, or lifts it with nil.
    mutating func setPeerCap(_ id: Peer.ID, to capBytes: UInt64?) {
        guard let i = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[i].capBytes = capBytes
    }

    /// Sets what the device is, for its list icon.
    mutating func setPeerKind(_ id: Peer.ID, to kind: Kind) {
        guard let i = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[i].kind = kind
    }

    /// The guests whose time is up by `now`. Model removes them, which revokes their keys.
    func expiredPeers(now: Date) -> [Peer] {
        peers.filter { $0.isExpired(now: now) }
    }

    // MARK: - Denied keys and one-time guest passes

    func isDenied(_ publicKey: Data) -> Bool { deniedKeys.contains(publicKey) }

    /// Denies a key for good. Denying is forever: there is no undeny, a device can
    /// always be paired again with a fresh key instead.
    mutating func denyKey(_ publicKey: Data) {
        if !deniedKeys.contains(publicKey) { deniedKeys.append(publicKey) }
    }

    /// Adds a one-time guest pass device and returns it WITH its private key: the
    /// caller shows the QR code from it and keeps the key in memory only. The saved
    /// copy has no key, so the code can never be shown again or backed up. Nil when
    /// all 253 addresses are taken.
    mutating func addGuestPass(qrExpiresAt: Date, accessExpiresAt: Date) -> Peer? {
        guard var peer = newPeer() else { return nil }
        peer.name = freeName("Guest")
        peer.guestPass = GuestPass(qrExpiresAt: qrExpiresAt, accessExpiresAt: accessExpiresAt, consumedAt: nil)
        var saved = peer
        saved.privateKey = Data()
        peers.append(saved)
        return peer
    }

    /// Marks a guest pass used: its device connected for the first time at `date`.
    mutating func consumeGuestPass(_ id: Peer.ID, at date: Date) {
        guard let i = peers.firstIndex(where: { $0.id == id }), peers[i].guestPass != nil else { return }
        peers[i].guestPass?.consumedAt = date
    }

    /// Guest passes still waiting to be used. Tunnel addresses are finite, so Model
    /// caps how many of these there can be.
    var unusedGuestPassCount: Int {
        peers.filter { $0.guestPass != nil && $0.guestPass?.consumedAt == nil }.count
    }

    /// Removes guest passes whose code lapsed unused by `now`, and denies their keys,
    /// so a code someone photographed can never be used late. Returns the removed.
    mutating func pruneLapsedGuestPasses(now: Date) -> [Peer] {
        let lapsed = peers.filter { peer in
            peer.guestPass.map { $0.consumedAt == nil && $0.qrExpiresAt <= now } ?? false
        }
        for peer in lapsed { denyKey(peer.publicKey) }
        peers.removeAll { peer in lapsed.contains { $0.id == peer.id } }
        return lapsed
    }

    /// "Device", then "Device 2", "Device 3", skipping names already taken.
    private func freeName(_ base: String) -> String {
        guard peers.contains(where: { $0.name == base }) else { return base }
        var number = 2
        while peers.contains(where: { $0.name == "\(base) \(number)" }) { number += 1 }
        return "\(base) \(number)"
    }

    /// A blank name leaves the old one. A long one is cut to 40 characters, which still fits a list row.
    mutating func renamePeer(_ id: Peer.ID, to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !trimmed.isEmpty, let i = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[i].name = trimmed
    }

    /// What the device imports, as a QR code or a .conf file. All traffic goes into the tunnel,
    /// IPv6 too, so nothing slips past Ferry onto the hotspot directly.
    func clientConfig(for peer: Peer) -> String {
        """
        [Interface]
        PrivateKey = \(peer.privateKey.base64EncodedString())
        Address = \(peer.address)/32
        DNS = \(Self.dns)
        MTU = \(Self.mtu)

        [Peer]
        PublicKey = \(serverPublicKey.base64EncodedString())
        Endpoint = \(Hotspot.host):\(Self.port)
        AllowedIPs = 0.0.0.0/0, ::/0
        PersistentKeepalive = 25

        """
    }

    /// WireGuard names the tunnel after the file, so keep it to letters, digits and dashes.
    static func fileName(for name: String) -> String {
        let parts = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return (["Ferry"] + parts).joined(separator: "-") + ".conf"
    }
}

/// Where the setup is kept. It holds private keys, so the app keeps it in the Keychain.
protocol SecretStore: AnyObject {
    /// Nil when nothing is saved. Throws when something may be saved but can't be read now.
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// For demo launches and tests, which must not touch the Keychain.
final class InMemorySecrets: SecretStore {
    var data: Data?
    func load() -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}

final class KeychainSecrets: SecretStore {
    private let query: [String: Any]

    /// `service` only changes in tests, which keep their own item apart from the app's.
    init(service: String = "tether.wireguard") {
        query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "setup",
        ]
    }

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "Keychain error \(status)" }
    }

    func load() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &out) {
        case errSecSuccess: return out as? Data
        case errSecItemNotFound: return nil
        case let status: throw Failure(status: status) // locked since a restart, for example
        }
    }

    func save(_ data: Data) throws {
        // After first unlock, so the server can start in the background after a restart.
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
        }
        if status != errSecSuccess { throw Failure(status: status) }
    }
}

/// The saved setup. Nothing saved starts afresh with a new server key. Anything else that goes
/// wrong leaves the saved setup alone: nothing is saved and devices can't be added, so neither a
/// passing Keychain error nor a setup this version can't decode replaces the key every device was
/// set up with. `load()` tries again, `reset()` gives up on a setup that doesn't decode.
final class WireGuardDevices {
    struct Unreadable: Error, CustomStringConvertible {
        var description: String { "the saved WireGuard setup can't be read" }
    }

    private(set) var setup = WireGuardSetup.new()
    /// Why the saved setup couldn't be read, until it can.
    private(set) var loadError: Error?
    private let secrets: SecretStore

    init(secrets: SecretStore) {
        self.secrets = secrets
        load()
    }

    /// Reads the saved setup, again after a failure. Does nothing once it has worked.
    func load() {
        do {
            guard let data = try secrets.load() else {
                setup = .new()
                setup.prepareReady()
                try save()
                loadError = nil
                return
            }
            guard var saved = try? JSONDecoder().decode(WireGuardSetup.self, from: data) else { throw Unreadable() }
            if saved.ready == nil {
                saved.prepareReady()
                try? secrets.save(JSONEncoder().encode(saved)) // tried again on the next change if it fails
            }
            setup = saved
            loadError = nil
        } catch {
            loadError = error
        }
    }

    var loaded: Bool { loadError == nil }
    /// The saved setup is there but this version can't decode it, so only `reset()` gets past it.
    var needsReset: Bool { loadError is Unreadable }

    /// A new server key and no devices, replacing what's saved. Every device has to be added again.
    func reset() {
        setup = .new()
        setup.prepareReady()
        do { try save(); loadError = nil } catch { loadError = error }
    }

    /// See `WireGuardSetup.claimReady`. False too when it couldn't be saved, and then nothing changes,
    /// so the next sample tries again.
    func claimReady(address: String, approval: WireGuardSetup.Approval = .approved) -> Bool {
        guard loaded else { return false }
        let before = setup
        guard setup.claimReady(address: address, approval: approval) else { return false }
        do {
            try save()
            return true
        } catch {
            setup = before
            return false
        }
    }

    /// False when the change couldn't be saved, and then nothing changes.
    @discardableResult
    func rename(_ id: WireGuardSetup.Peer.ID, to name: String) -> Bool {
        change { $0.renamePeer(id, to: name) }
    }

    /// False when the change couldn't be saved, and then nothing changes.
    @discardableResult
    func setPausedUntil(_ id: WireGuardSetup.Peer.ID, _ until: Date?) -> Bool {
        change { $0.setPeerPausedUntil(id, until) }
    }

    @discardableResult
    func setApproval(_ id: WireGuardSetup.Peer.ID, _ approval: WireGuardSetup.Approval) -> Bool {
        change { $0.setPeerApproval(id, approval) }
    }

    @discardableResult
    func setSpeedLimits(_ id: WireGuardSetup.Peer.ID, down: UInt64?, up: UInt64?) -> Bool {
        change { $0.setPeerSpeedLimits(id, down: down, up: up) }
    }

    @discardableResult
    func denyKey(_ publicKey: Data) -> Bool {
        change { $0.denyKey(publicKey) }
    }

    /// Adds a one-time guest pass (see `WireGuardSetup.addGuestPass`). The returned
    /// device carries its private key; the saved one doesn't. Nil when the subnet is
    /// full or the pass couldn't be saved, and then nothing changes.
    func addGuestPass(qrExpiresAt: Date, accessExpiresAt: Date) -> WireGuardSetup.Peer? {
        guard loaded else { return nil }
        let before = setup
        guard let peer = setup.addGuestPass(qrExpiresAt: qrExpiresAt, accessExpiresAt: accessExpiresAt) else { return nil }
        do {
            try save()
            return peer
        } catch {
            setup = before
            return nil
        }
    }

    @discardableResult
    func consumeGuestPass(_ id: WireGuardSetup.Peer.ID, at date: Date) -> Bool {
        change { $0.consumeGuestPass(id, at: date) }
    }

    /// Removes guest passes whose code lapsed unused. Empty when there were none or
    /// the removal couldn't be saved, and then nothing changes.
    func pruneLapsedGuestPasses(now: Date) -> [WireGuardSetup.Peer] {
        guard loaded else { return [] }
        let before = setup
        let removed = setup.pruneLapsedGuestPasses(now: now)
        if removed.isEmpty { return [] }
        do {
            try save()
            return removed
        } catch {
            setup = before
            return []
        }
    }

    /// Replaces the whole setup, for restoring a backup. The replacement is validated
    /// by the caller (see Backup.swift) before it gets here. False when it couldn't
    /// be saved, and then nothing changes.
    @discardableResult
    func replaceSetup(_ newSetup: WireGuardSetup) -> Bool {
        guard loaded else { return false }
        let before = setup
        setup = newSetup
        do {
            try save()
            return true
        } catch {
            setup = before
            return false
        }
    }

    @discardableResult
    func setExpiry(_ id: WireGuardSetup.Peer.ID, to expiresAt: Date?) -> Bool {
        change { $0.setPeerExpiry(id, to: expiresAt) }
    }

    @discardableResult
    func setCap(_ id: WireGuardSetup.Peer.ID, to capBytes: UInt64?) -> Bool {
        change { $0.setPeerCap(id, to: capBytes) }
    }

    @discardableResult
    func setKind(_ id: WireGuardSetup.Peer.ID, to kind: WireGuardSetup.Kind) -> Bool {
        change { $0.setPeerKind(id, to: kind) }
    }

    private func change(_ apply: (inout WireGuardSetup) -> Void) -> Bool {
        guard loaded else { return false }
        let before = setup
        apply(&setup)
        do {
            try save()
            return true
        } catch {
            setup = before
            return false
        }
    }

    /// False when the change couldn't be saved. Then the device stays, here and on the server, since
    /// it would come back with the next launch anyway.
    @discardableResult
    func remove(_ id: WireGuardSetup.Peer.ID) -> Bool {
        change { $0.removePeer(id) }
    }

    private func save() throws {
        try secrets.save(JSONEncoder().encode(setup))
    }
}

extension WireGuardSetup {
    /// Hand-written, like Peer's, and in an extension so the memberwise
    /// initializer stays: a setup saved before `deniedKeys` existed (every
    /// 1.0/1.1 install) has no such key, and the synthesized decoder refuses a
    /// missing key even when the property declares a default, which would have
    /// lost every paired device on the 1.2 upgrade. Encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        serverPrivateKey = try box.decode(Data.self, forKey: .serverPrivateKey)
        peers = try box.decode([Peer].self, forKey: .peers)
        ready = try box.decodeIfPresent(Peer.self, forKey: .ready)
        deniedKeys = try box.decodeIfPresent([Data].self, forKey: .deniedKeys) ?? []
    }
}
