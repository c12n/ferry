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

    /// Why a device can't pass traffic right now, though it stays paired.
    enum PauseReason: String, Codable {
        /// The person paused it on the device's screen.
        case manual
        /// Its data cap for today was reached. Lifts by itself tomorrow.
        case cap
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
        /// Kept so the device's QR code can be shown again. It's only ever used inside the tunnel.
        var privateKey: Data
        var publicKey: Data
        var address: String
        /// A guest device is removed for good at this date. Nil is permanent access.
        var expiresAt: Date?
        /// A paused device keeps its key and settings but isn't in the server's peer list,
        /// so nothing it sends gets through.
        var paused = false
        var pauseReason: PauseReason?
        /// The most the device may use today, up and down together, in bytes. Nil is no cap.
        /// Reaching it pauses the device (reason `.cap`) until tomorrow.
        var capBytes: UInt64?
        /// What the device is, for its list icon. `.other` until someone picks.
        var kind: Kind = .other

        /// Has the guest's time run out by `now`?
        func isExpired(now: Date) -> Bool {
            expiresAt.map { $0 <= now } ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, privateKey, publicKey, address, expiresAt, paused, pauseReason, capBytes, kind
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
            paused = try box.decodeIfPresent(Bool.self, forKey: .paused) ?? false
            pauseReason = try box.decodeIfPresent(PauseReason.self, forKey: .pauseReason)
            capBytes = try box.decodeIfPresent(UInt64.self, forKey: .capBytes)
            kind = try box.decodeIfPresent(Kind.self, forKey: .kind) ?? .other
        }

        /// Hand-written with the decoder (a custom `init(from:)` in the body stops the
        /// synthesized Codable pair, so both halves are here). Optionals encode only
        /// when set, as the synthesized one would have done.
        func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(id, forKey: .id)
            try box.encode(name, forKey: .name)
            try box.encode(privateKey, forKey: .privateKey)
            try box.encode(publicKey, forKey: .publicKey)
            try box.encode(address, forKey: .address)
            try box.encodeIfPresent(expiresAt, forKey: .expiresAt)
            try box.encode(paused, forKey: .paused)
            try box.encodeIfPresent(pauseReason, forKey: .pauseReason)
            try box.encodeIfPresent(capBytes, forKey: .capBytes)
            try box.encode(kind, forKey: .kind)
        }

        init(id: UUID = UUID(), name: String, privateKey: Data, publicKey: Data, address: String,
             expiresAt: Date? = nil, paused: Bool = false, pauseReason: PauseReason? = nil,
             capBytes: UInt64? = nil, kind: Kind = .other) {
            self.id = id
            self.name = name
            self.privateKey = privateKey
            self.publicKey = publicKey
            self.address = address
            self.expiresAt = expiresAt
            self.paused = paused
            self.pauseReason = pauseReason
            self.capBytes = capBytes
            self.kind = kind
        }
    }

    var serverPrivateKey: Data
    /// The devices someone has used, in the order they first connected.
    var peers: [Peer]
    /// The device behind the QR code on the main screen: a key nobody has used yet. The server lets
    /// it in, and the first time it connects it joins `peers` and a new one takes its place. Nil
    /// only in a setup saved before there was one, or with all 253 addresses taken.
    var ready: Peer?

    /// Everyone the server lets in: the devices that aren't paused, and whoever scans the
    /// QR code next. A guest whose time is up is taken out of `peers` itself (see Model),
    /// so it isn't filtered here.
    var serverPeers: [Peer] { peers.filter { !$0.paused } + (ready.map { [$0] } ?? []) }

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
    mutating func claimReady(address: String) -> Bool {
        guard var peer = ready, peer.address == address else { return false }
        peer.name = freeName("Device")
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

    /// Pauses or resumes a device. Resuming clears the reason; pausing by hand is `.manual`.
    mutating func setPeerPaused(_ id: Peer.ID, _ paused: Bool, reason: PauseReason = .manual) {
        guard let i = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[i].paused = paused
        peers[i].pauseReason = paused ? reason : nil
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
    func claimReady(address: String) -> Bool {
        guard loaded else { return false }
        let before = setup
        guard setup.claimReady(address: address) else { return false }
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
    func setPaused(_ id: WireGuardSetup.Peer.ID, _ paused: Bool, reason: WireGuardSetup.PauseReason = .manual) -> Bool {
        change { $0.setPeerPaused(id, paused, reason: reason) }
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
