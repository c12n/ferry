import Foundation
import TetherWG

/// Runs the WireGuard server from WireGuard/ (Go, linked as TetherWG.xcframework). Only the main actor calls it. The Go side is thread-safe and quick, so nothing here waits.
@MainActor
final class WireGuardServer {
    private(set) var running = false
    private var carried = CarriedTotals()
    /// Each device's counters from runs that have stopped, by tunnel address. The same
    /// carry as `carried`, per device, so usage survives the hotspot going away and back.
    private var carriedPeers: [String: TrafficTotals] = [:]

    /// Listens on the hotspot address only.
    /// `port` is for the tests, which can't count on 51820 being free.
    func start(host: String, setup: WireGuardSetup, port: UInt16 = WireGuardSetup.port) throws {
        stop()
        // Go reads exactly 32 bytes behind each key pointer.
        guard setup.serverPrivateKey.count == 32 else { throw Failure(message: "the server key isn't 32 bytes") }
        let error = setup.serverPrivateKey.withUnsafeBytes { key in
            host.withCString { h in
                TetherWGStart(UnsafeMutablePointer(mutating: h), Int32(port),
                              UnsafeMutablePointer(mutating: key.bindMemory(to: UInt8.self).baseAddress))
            }
        }
        if let message = take(error) { throw Failure(message: message) }
        running = true
        do {
            try setPeers(setup)
        } catch {
            // Not left half started: the watcher in Model retries a server that isn't running.
            TetherWGStop()
            running = false
            throw error
        }
    }

    func stop() {
        guard running else { return }
        let run = currentRun()
        carried.absorb(run.totals)
        for (address, reading) in run.peers {
            let soFar = carriedPeers[address] ?? TrafficTotals()
            carriedPeers[address] = TrafficTotals(bytesUp: soFar.bytesUp + reading.totals.bytesUp,
                                                  bytesDown: soFar.bytesDown + reading.totals.bytesDown)
        }
        TetherWGStop()
        running = false
        connectedAddresses = []
    }

    /// Lets in exactly the devices in `setup`. A removed device's open connections finish on their own.
    func setPeers(_ setup: WireGuardSetup) throws {
        guard running else { return }
        let peers = setup.serverPeers
        guard peers.allSatisfy({ $0.publicKey.count == 32 }) else { throw Failure(message: "a device key isn't 32 bytes") }
        var keys = Data()
        for p in peers { keys.append(p.publicKey) }
        // No router mark: the server finds a router by its clients' traffic, see noticeRouter in server.go.
        let addresses = peers.map(\.address).joined(separator: "\n")
        let error = keys.withUnsafeBytes { k in
            addresses.withCString { a in
                TetherWGSetPeers(UnsafeMutablePointer(mutating: k.bindMemory(to: UInt8.self).baseAddress),
                                 UnsafeMutablePointer(mutating: a), Int32(peers.count))
            }
        }
        if let message = take(error) { throw Failure(message: message) }
    }

    /// Gives memory Go's GC has freed back to iOS, on a memory warning.
    func freeMemory() {
        if running { TetherWGFreeMemory() }
    }

    /// Counters that only grow, across restarts.
    func snapshot() -> TrafficTotals {
        carried.apply(to: running ? currentRun().totals : TrafficTotals())
    }

    /// What the server last saw of one device in a run: its counters, and when it last
    /// handshaked (nil when it never has, or in a run that already stopped).
    struct PeerReading {
        var totals = TrafficTotals()
        var lastHandshake: Date?
    }

    /// Each device's reading by tunnel address, counters carried across restarts like
    /// `snapshot`. Only devices the server currently lets in appear; a device with no
    /// traffic yet reads as zero, since the Go side reports every peer.
    func peerSnapshot() -> [String: PeerReading] {
        var out = carriedPeers.mapValues { PeerReading(totals: $0) }
        guard running else { return out }
        for (address, reading) in currentRun().peers {
            let soFar = out[address]?.totals ?? TrafficTotals()
            out[address] = PeerReading(
                totals: TrafficTotals(bytesUp: soFar.bytesUp + reading.totals.bytesUp,
                                      bytesDown: soFar.bytesDown + reading.totals.bytesDown),
                lastHandshake: reading.lastHandshake)
        }
        return out
    }

    /// The tunnel addresses of the devices with a recent handshake: set up and working, also
    /// before they sent anything. From the last `snapshot()`, so both describe the same moment.
    private(set) var connectedAddresses: Set<String> = []

    private func currentRun() -> (totals: TrafficTotals, peers: [String: PeerReading]) {
        guard let json = take(TetherWGStats()), let data = json.data(using: .utf8),
              let stats = try? JSONDecoder().decode(GoStats.self, from: data) else {
            connectedAddresses = []
            return (TrafficTotals(), [:])
        }
        connectedAddresses = Set(stats.connected)
        var peers: [String: PeerReading] = [:]
        for peer in stats.peers ?? [] {
            peers[peer.address] = PeerReading(
                totals: TrafficTotals(bytesUp: peer.up, bytesDown: peer.down),
                lastHandshake: peer.handshake.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil })
        }
        return (TrafficTotals(bytesUp: stats.up, bytesDown: stats.down), peers)
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// The parts of TetherWGStats' JSON the app uses, see Stats in server.go.
    private struct GoStats: Decodable {
        let up: UInt64
        let down: UInt64
        let connected: [String]
        /// Per-device totals. Optional so a stats reply from before they existed (an older
        /// WireGuard build in a test, say) still decodes.
        let peers: [PeerStat]?
    }

    private struct PeerStat: Decodable {
        let address: String
        let up: UInt64
        let down: UInt64
        /// Latest handshake, Unix seconds. Optional like `peers` itself, for older replies.
        let handshake: Int64?
    }
}

/// Reads and frees a string Go returned.
private func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    defer { TetherWGFree(p) }
    return String(cString: p)
}
