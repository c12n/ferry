import CommonCrypto
import CryptoKit
import Foundation
import Security

/// A Ferry backup: one JSON document with the server key, the devices and the
/// settings. A backup is a credentials file (it holds the server's private key),
/// so the export the app offers is encrypted by default (see `BackupCrypto`);
/// the plain export carries settings and public information only, no keys.
///
/// A backup file is untrusted input. Nothing in it reaches the server until
/// `validated()` has checked every field, and even then the values travel to
/// WireGuard as binary keys and parsed addresses through the C API, never as
/// text interpolated into a config string, so a newline planted in a name or an
/// address can't inject a line into anything. Restoring replaces everything,
/// never merges, except the denylist, which is unioned (see `makeSetup`).
struct FerryBackup: Codable, Equatable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var appVersion: String
    var createdAt: Date
    /// False for the plain settings-only export: no private keys anywhere in it.
    var includesKeys: Bool
    var serverPrivateKey: Data?
    var peers: [PeerEntry]
    var deniedKeys: [Data]
    var settings: SettingsEntry

    struct PeerEntry: Codable, Equatable {
        var id: UUID
        var name: String
        var publicKey: Data
        /// Nil for a device whose key Ferry no longer holds (it connected already,
        /// or the export is the plain one). Restoring it keeps the device paired;
        /// its QR code just can't be shown again, like in Ferry itself.
        var privateKey: Data?
        var address: String
        var kind: String
        var approval: String
        var capBytes: UInt64?
        var downLimitBps: UInt64?
        var upLimitBps: UInt64?
        /// A classic guest's expiry, or a used guest pass's access end.
        var expiresAt: Date?
        var pausedUntil: Date?
        /// The device came from a one-time guest pass that was used. Unused guest
        /// passes are never exported: their keys exist only in memory.
        var guestConsumed: Bool
    }

    struct SettingsEntry: Codable, Equatable {
        var idleTimeoutMinutes: Int
        var batteryThresholdPercent: Int
        var notifyJoins: Bool
        var notifyLeaves: Bool
        var notifyStopped: Bool
        var approvalMode: Bool
        var billingDay: Int
        var monthlyCapBytes: UInt64?
    }

    /// Builds the document from the live setup. The ready device (the unused QR
    /// code on the main screen) is not exported: a restored setup makes a fresh
    /// one, so an old code someone photographed can't come back.
    static func make(from setup: WireGuardSetup, settings: SettingsEntry,
                     includesKeys: Bool, appVersion: String, now: Date) -> FerryBackup {
        let peers = setup.peers.compactMap { peer -> PeerEntry? in
            if let pass = peer.guestPass, pass.consumedAt == nil { return nil } // unused guest pass
            return PeerEntry(
                id: peer.id, name: peer.name, publicKey: peer.publicKey,
                privateKey: includesKeys && !peer.privateKey.isEmpty ? peer.privateKey : nil,
                address: peer.address, kind: peer.kind.rawValue, approval: peer.approval.rawValue,
                capBytes: peer.capBytes, downLimitBps: peer.downLimitBps, upLimitBps: peer.upLimitBps,
                expiresAt: peer.guestPass?.accessExpiresAt ?? peer.expiresAt,
                pausedUntil: peer.pausedUntil, guestConsumed: peer.guestPass != nil)
        }
        return FerryBackup(formatVersion: currentFormatVersion, appVersion: appVersion, createdAt: now,
                           includesKeys: includesKeys,
                           serverPrivateKey: includesKeys ? setup.serverPrivateKey : nil,
                           peers: peers, deniedKeys: setup.deniedKeys, settings: settings)
    }

    /// Checks every field and returns a cleaned copy (names stripped of control
    /// characters and capped, the billing day clamped), or throws the first
    /// problem found. Nothing is applied from an unvalidated document.
    func validated() throws -> FerryBackup {
        guard formatVersion == Self.currentFormatVersion else {
            throw BackupError.unsupportedVersion(formatVersion)
        }
        if let serverPrivateKey, serverPrivateKey.count != 32 { throw BackupError.badServerKey }
        for key in deniedKeys where key.count != 32 { throw BackupError.badDeniedKey }
        var seenAddresses: Set<String> = []
        var cleanedPeers: [PeerEntry] = []
        for var peer in peers {
            guard peer.publicKey.count == 32 else { throw BackupError.badPeerKey(name: peer.name) }
            if let privateKey = peer.privateKey, privateKey.count != 32 {
                throw BackupError.badPeerKey(name: peer.name)
            }
            guard BackupValidation.isTunnelAddress(peer.address) else {
                throw BackupError.badAddress(peer.address)
            }
            guard seenAddresses.insert(peer.address).inserted else {
                throw BackupError.duplicateAddress(peer.address)
            }
            guard WireGuardSetup.Kind(rawValue: peer.kind) != nil else {
                throw BackupError.badValue(field: "kind")
            }
            guard WireGuardSetup.Approval(rawValue: peer.approval) != nil else {
                throw BackupError.badValue(field: "approval")
            }
            peer.name = BackupValidation.sanitizedName(peer.name)
            cleanedPeers.append(peer)
        }
        var cleaned = self
        cleaned.peers = cleanedPeers
        cleaned.settings.billingDay = max(1, min(cleaned.settings.billingDay, 31))
        return cleaned
    }

    /// The setup this backup restores to. Call only on a `validated()` document.
    /// Throws `.settingsOnly` when the document has no server key: then only the
    /// settings can be restored, and Model does that instead.
    ///
    /// The denylist is merged with the current one, never replaced, and a device
    /// whose key is denied by either list is dropped, so restoring an old backup
    /// can't bring a revoked device back. Expired guests are dropped too, and a
    /// used guest pass comes back used and keyless, as it was.
    func makeSetup(currentDeniedKeys: [Data], now: Date) throws -> WireGuardSetup {
        guard let serverPrivateKey else { throw BackupError.settingsOnly }
        let denied = Set(currentDeniedKeys).union(deniedKeys)
        var restored: [WireGuardSetup.Peer] = []
        for entry in peers {
            if denied.contains(entry.publicKey) { continue }
            if let expiresAt = entry.expiresAt, expiresAt <= now { continue } // an expired guest
            let guestPass = entry.guestConsumed
                ? WireGuardSetup.GuestPass(qrExpiresAt: .distantPast,
                                           accessExpiresAt: entry.expiresAt ?? .distantFuture,
                                           consumedAt: createdAt)
                : nil
            restored.append(WireGuardSetup.Peer(
                id: entry.id, name: entry.name, privateKey: entry.privateKey ?? Data(),
                publicKey: entry.publicKey, address: entry.address,
                expiresAt: entry.guestConsumed ? nil : entry.expiresAt,
                pausedUntil: entry.pausedUntil,
                approval: WireGuardSetup.Approval(rawValue: entry.approval) ?? .approved,
                capBytes: entry.capBytes, downLimitBps: entry.downLimitBps, upLimitBps: entry.upLimitBps,
                kind: WireGuardSetup.Kind(rawValue: entry.kind) ?? .other, guestPass: guestPass))
        }
        var setup = WireGuardSetup(serverPrivateKey: serverPrivateKey, peers: restored)
        setup.deniedKeys = denied.sorted { $0.base64EncodedString() < $1.base64EncodedString() }
        setup.prepareReady()
        return setup
    }
}

enum BackupError: Error, Equatable, CustomStringConvertible {
    case notABackup
    case unsupportedVersion(Int)
    case settingsOnly
    case badServerKey
    case badPeerKey(name: String)
    case badAddress(String)
    case duplicateAddress(String)
    case badDeniedKey
    case badValue(field: String)
    case wrongPasswordOrCorrupt

    var description: String {
        switch self {
        case .notABackup: return "That file isn't a Ferry backup."
        case .unsupportedVersion(let version): return "This backup is from a newer Ferry (format \(version)) and can't be restored here."
        case .settingsOnly: return "This backup has no keys, so only its settings can be restored."
        case .badServerKey: return "The backup's server key is damaged."
        case .badPeerKey(let name): return "The backup's key for \(name) is damaged."
        case .badAddress(let address): return "The backup has an address Ferry can't use: \(address)."
        case .duplicateAddress(let address): return "The backup gives two devices the same address: \(address)."
        case .badDeniedKey: return "The backup's denied keys are damaged."
        case .badValue(let field): return "The backup has a \(field) Ferry doesn't know."
        case .wrongPasswordOrCorrupt: return "The password is wrong, or the backup is damaged."
        }
    }
}

/// The field-level rules, kept apart so the tests can drive them directly.
enum BackupValidation {
    /// A name as it may be saved: control characters stripped (a newline in a name
    /// is how a planted file would try to inject a config line), trimmed, capped
    /// at the same 40 characters the app itself caps at, never empty.
    static func sanitizedName(_ raw: String) -> String {
        let stripped = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(stripped)).trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(trimmed.prefix(40))
        return capped.isEmpty ? "Device" : capped
    }

    /// Exactly one tunnel address: a canonical dotted quad in Ferry's subnet,
    /// host part 2 to 254. A `/32` suffix, a `/0`, another subnet or any other
    /// spelling is refused, so a restored device can only ever hold the one
    /// address Ferry would have given it.
    static func isTunnelAddress(_ raw: String) -> Bool {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber }),
                  (part.count == 1 || !part.hasPrefix("0")),
                  let value = Int(part), value <= 255 else { return false }
            octets.append(value)
        }
        guard octets[0] == 10, octets[1] == 7, octets[2] == 0 else { return false }
        return (2...254).contains(octets[3])
    }
}

/// The backup file's encryption: a password-derived key (PBKDF2-HMAC-SHA256,
/// 600,000 rounds; CryptoKit has no password-based derivation, so CommonCrypto
/// does that step) and AES-GCM, with the header (magic, version, rounds, salt)
/// covered by the GCM tag as authenticated data. File layout:
/// magic "FERRYBK1" | version byte | rounds (UInt32, big-endian) | salt (16) |
/// AES.GCM combined (nonce, ciphertext, tag).
enum BackupCrypto {
    static let magic = Data("FERRYBK1".utf8)
    private static let version: UInt8 = 1
    static let defaultIterations: UInt32 = 600_000
    private static let saltLength = 16
    private static let keyLength = 32

    static func isEncrypted(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    static func seal(_ plaintext: Data, password: String, iterations: UInt32 = defaultIterations) throws -> Data {
        let salt = randomData(saltLength)
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let header = headerData(iterations: iterations, salt: salt)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(), authenticating: header)
        guard let combined = sealed.combined else { throw BackupError.wrongPasswordOrCorrupt }
        return header + combined
    }

    static func open(_ data: Data, password: String) throws -> Data {
        guard isEncrypted(data) else { throw BackupError.notABackup }
        let headerLength = magic.count + 1 + 4 + saltLength
        guard data.count > headerLength, data[magic.count] == version else {
            throw BackupError.wrongPasswordOrCorrupt
        }
        let rounds = data.subdata(in: (magic.count + 1)..<(magic.count + 5))
        let iterations = rounds.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard iterations >= 1, iterations <= 10_000_000 else { throw BackupError.wrongPasswordOrCorrupt }
        let salt = data.subdata(in: (magic.count + 5)..<headerLength)
        let header = data.subdata(in: 0..<headerLength)
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: data.subdata(in: headerLength..<data.count))
            return try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw BackupError.wrongPasswordOrCorrupt
        }
    }

    private static func headerData(iterations: UInt32, salt: Data) -> Data {
        var header = Data()
        header.append(magic)
        header.append(version)
        var rounds = iterations.bigEndian
        withUnsafeBytes(of: &rounds) { header.append(contentsOf: $0) }
        header.append(salt)
        return header
    }

    static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        var derived = Data(count: keyLength)
        let status: Int32 = derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                password.withCString { passwordPtr in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordPtr, password.utf8.count,
                                         saltPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                         derivedPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), keyLength)
                }
            }
        }
        guard status == 0 else { throw BackupError.wrongPasswordOrCorrupt }
        return SymmetricKey(data: derived)
    }

    private static func randomData(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess {
            return Data(bytes)
        }
        var generator = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes)
    }
}
