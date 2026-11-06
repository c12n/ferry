// File map (all in Sources/):
//   TetherApp.swift     the @main App only
//   Model.swift         Model, Interfaces
//   Traffic.swift       the server's byte counters, Foundation only
//   Usage.swift         per-device usage totals and caps, Foundation only
//   BatteryGuard.swift  when low battery stops sharing, Foundation only
//   Format.swift        bytes and speeds as text
//   MainView.swift      MainView (the main screen), StatusCard, the speeds, settings and the history graph
//   DevicesView.swift   the QR code for the next device, and a device's own screen
//   DiagnosticsView.swift  the Diagnostics screen and its shareable summary
//   WidgetSnapshot.swift  the state the widget shows, shared through the App Group, Foundation only
//   TetherActivityAttributes.swift  the Live Activity's shape, app and widget extension only
//   SharingActivity.swift  drives the Live Activity and the widget snapshot, app only
//   Notifier.swift      local notifications: joins, leaves, stops, caps, battery, app only
//   AppExpiry.swift     when a sideloaded build stops opening, and the warning before it
//   DemoMode.swift      fake app state for the UI tests, Debug builds only
//   Shortcuts.swift     the Shortcuts actions; ShortcutReply.swift has what they say, Foundation only
//   WireGuardSetup.swift  the hotspot address, WireGuard keys, devices and client configs, Foundation only
//   WireGuardServer.swift  runs the WireGuard server (WireGuard/, Go)
//   KeepAlive.swift, KeepAlivePolicy.swift  the silent sound that keeps Ferry running

import OSLog
import SwiftUI
import UIKit

@MainActor
final class Model: ObservableObject {
    /// The screen and the Shortcuts actions share it. An action can launch Ferry in the
    /// background, with no screen, and this is all that runs then.
    static let shared = Model()

    @Published var running = false
    /// Download and upload speed now, in bits per second. Zero until there are two samples to compare.
    @Published var downSpeed = 0.0
    @Published var upSpeed = 0.0
    /// When this build stops opening, from its provisioning profile. Nil without one.
    var expires: Date? = AppExpiry.installed { didSet { refreshExpiryWarning() } }
    /// "Ferry stops opening in 2 days ...", in the last three days before `expires`. Refreshed by
    /// the 1 s sampler, so it appears on time even on a screen where nothing else changes.
    @Published private(set) var expiryWarning: String?
    /// The devices that have connected, in the order they first did. Their keys are in the Keychain.
    @Published private(set) var wireGuardPeers: [WireGuardSetup.Peer]
    /// Behind the QR code on the main screen, see `WireGuardSetup.ready`.
    @Published private(set) var wireGuardReady: WireGuardSetup.Peer?
    /// Why WireGuard isn't running while the hotspot is on, shown on the WireGuard screen.
    @Published private(set) var wireGuardProblem: String?
    /// The hotspot is on and WireGuard runs. `running` alone is only the hotspot.
    var sharing: Bool { running && wireGuardProblem == nil }
    /// The tunnel addresses of the WireGuard devices that are connected. Read with every sample
    /// while the app is on screen.
    @Published var wireGuardConnected: Set<String> = []

    /// Per-device usage (session, today, all time), kept across launches. See Usage.swift.
    @Published private(set) var usage: UsageTracker
    /// Each device's speed now, in bits per second, by device key (see `key(for:)`).
    /// From the same readings as the usage; a quiet device reads zero.
    @Published private(set) var deviceSpeeds: [String: (down: Double, up: Double)] = [:]
    /// When each device last handshaked, by device key. Nil for a device that never has
    /// in any run Ferry has seen.
    @Published private(set) var deviceHandshakes: [String: Date] = [:]
    /// When each device was last seen — a handshake or traffic, whichever is later.
    @Published private(set) var deviceLastSeen: [String: Date] = [:]

    /// One point of the speed history graph: the total speeds at a moment.
    struct SpeedSample: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let down: Double
        let up: Double
    }

    /// The session's speed samples, newest last, at most an hour of them. Session-only:
    /// a relaunch starts an empty graph.
    @Published private(set) var speedHistory: [SpeedSample] = []

    // MARK: - Settings

    /// The settings, all in UserDefaults, all changeable from the main screen's Settings
    /// section. The defaults preserve the behaviour before there were settings.
    @Published var idleTimeoutMinutes: Int = (UserDefaults.standard.object(forKey: "tether.idleTimeoutMinutes") as? Int) ?? 10 {
        didSet { UserDefaults.standard.set(idleTimeoutMinutes, forKey: "tether.idleTimeoutMinutes") }
    }
    /// The idle timeout as KeepAlivePolicy takes it: nil is "Never".
    var idleLimit: TimeInterval? { idleTimeoutMinutes > 0 ? TimeInterval(idleTimeoutMinutes * 60) : nil }
    /// The battery guard's stop level in percent; 0 is off.
    @Published var batteryThresholdPercent: Int = UserDefaults.standard.integer(forKey: "tether.batteryThresholdPercent") {
        didSet { UserDefaults.standard.set(batteryThresholdPercent, forKey: "tether.batteryThresholdPercent") }
    }
    @Published var notifyJoins: Bool = (UserDefaults.standard.object(forKey: "tether.notifyJoins") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(notifyJoins, forKey: "tether.notifyJoins")
            if notifyJoins { notifier.requestAuthorization() }
        }
    }
    @Published var notifyLeaves: Bool = (UserDefaults.standard.object(forKey: "tether.notifyLeaves") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(notifyLeaves, forKey: "tether.notifyLeaves")
            if notifyLeaves { notifier.requestAuthorization() }
        }
    }
    @Published var notifyStopped: Bool = (UserDefaults.standard.object(forKey: "tether.notifyStopped") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(notifyStopped, forKey: "tether.notifyStopped")
            if notifyStopped { notifier.requestAuthorization() }
        }
    }
    /// The battery guard stopped sharing and it hasn't recovered (or been resumed) yet.
    @Published private(set) var batteryBlocked = false
    /// A manual Resume after a battery stop: the guard stays out of the way until the
    /// battery recovers properly (see BatteryGuard.recovered).
    private var batteryOverride = false
    private var batteryWarned = false

    private let wireGuard = WireGuardServer()
    private let wireGuardDevices: WireGuardDevices
    private let keepAlive = KeepAlive()
    private let notifier = Notifier()
    private let sharingActivity = SharingActivity()
    private static let logger = Logger(subsystem: "com.vsvirskyi.phoneshare", category: "tether")
    /// Only the on-screen sampler publishes connections and speeds, so it runs only while the app is on screen.
    /// False in a launch from a Shortcuts action, which happens in the background.
    private var sceneActive = UIApplication.shared.applicationState != .background

    #if DEBUG
    /// Set in a demo launch (`-TetherDemo`, see DemoMode.swift). Nothing real runs then.
    private var demo: DemoState?
    #endif

    init() {
        #if DEBUG
        let demo = DemoState.fromLaunchArguments()
        let secrets: SecretStore = demo?.secrets() ?? KeychainSecrets()
        #else
        let secrets: SecretStore = KeychainSecrets()
        #endif
        self.wireGuardDevices = WireGuardDevices(secrets: secrets)
        self.wireGuardPeers = wireGuardDevices.setup.peers
        self.wireGuardReady = wireGuardDevices.setup.ready
        self.usage = UsageStore.load()
        #if DEBUG
        if let demo {
            self.demo = demo
            demo.apply(to: self)
            if !wireGuardDevices.loaded { startWireGuard(on: Hotspot.host) } // only reports the problem, no server starts
            return // no server, keep-alive audio, watcher, sampler or scene observers
        }
        #endif
        // Guests whose time ran out while Ferry was closed are removed before anything
        // starts, so their keys never work again.
        for peer in wireGuardDevices.setup.expiredPeers(now: Date()) {
            usage.forget(Self.key(for: peer))
            _ = wireGuardDevices.remove(peer.id)
        }
        publishSetup()
        refreshExpiryWarning()
        observeScene()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                self?.syncWithHotspot()
                // On screen the sampler does this every second.
                if self?.sceneActive == false { self?.claimReadyInBackground() }
                // The slack lets iOS wake the app for this together with other timers.
                let interval = KeepAlivePolicy.watchInterval(sceneActive: self?.sceneActive ?? false)
                try? await Task.sleep(for: interval.every, tolerance: interval.tolerance)
            }
        }
        if sceneActive { startSampler() }
    }

    /// Every second while the app is on screen. In the background nothing on screen needs it, so it stops.
    private func startSampler() {
        sampler?.cancel()
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleTraffic()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Publishes only when the text changes, so the sampler doesn't redraw the screen every second.
    func refreshExpiryWarning(now: Date = Date()) {
        var now = now
        #if DEBUG
        if demo != nil { now = DemoScenario.now }
        #endif
        let warning = expires.flatMap { AppExpiry.warning(expires: $0, now: now) }
        if warning != expiryWarning { expiryWarning = warning }
    }

    private var watcher: Task<Void, Never>?
    /// When the hotspot went away, or Ferry was last on screen since. Nil while the hotspot is on.
    /// A launch starts long past, so only opening Ferry or Start Ferry (`wake`) gives it the
    /// idle timeout. "Is Ferry Sharing?" launches Ferry in the background too, and only reports.
    private var waitingSince: Date? = .distantPast
    private var sampler: Task<Void, Never>?
    private var lastSample: (up: UInt64, down: UInt64, at: Date)?
    /// The hotspot address the server is bound to, for the Diagnostics screen.
    @Published private(set) var boundHost: String?
    /// The last per-device readings fed to the usage tracker, and when, for device speeds.
    private var lastUsageReadings: [String: DeviceUsage] = [:]
    private var lastUsageAt: Date?
    private var lastUsageSave = Date.distantPast

    /// The hotspot interface exists only while Personal Hotspot is on. This starts WireGuard when
    /// it appears and stops it when it goes away or changes, so it never listens anywhere else.
    func syncWithHotspot() {
        // The battery guard stopped sharing: nothing starts again until the battery
        // recovers or the person resumes it (see checkBattery / resumeAfterBatteryGuard).
        // The recovery is checked here too, since the sampler's checks stop with sharing.
        if batteryBlocked {
            updateBatteryMonitoring()
            if !batteryRecovered() {
                if wireGuard.running { wireGuard.stop() }
                if running { running = false }
                return
            }
            batteryBlocked = false
            batteryOverride = false
            batteryWarned = false
            append("battery recovered, the guard steps aside")
        }
        let wasRunning = running
        let wasSharing = sharing
        let hotspot = Interfaces.hotspotAddress()
        if running, hotspot != boundHost {
            append("hotspot address gone or changed, stopping")
            wireGuard.stop()
            running = false
        }
        // A WireGuard start that failed (keys locked after a restart, say) is tried again here.
        if running, !wireGuard.running, let boundHost { startWireGuard(on: boundHost) }
        keepAliveWhileSharing(hotspot: hotspot != nil)
        if !running, let hotspot {
            append("binding to \(hotspot)")
            boundHost = hotspot
            startWireGuard(on: hotspot)
            // A restart (hotspot address change) never passes through running == false in the
            // sampler, so start the session's counters afresh here.
            lastSample = nil
            downSpeed = 0
            upSpeed = 0
            running = true
        }
        if running, !wasRunning {
            // A new sharing session: its usage and its graph start from zero, and this is
            // the contextual moment to ask about notifications — never at first launch.
            usage.startSession()
            speedHistory = []
            if notifyJoins || notifyLeaves || notifyStopped { notifier.requestAuthorization() }
        }
        if wasSharing, !sharing, notifyStopped {
            notifier.sharingStopped(reason: running
                ? (wireGuardProblem ?? "WireGuard stopped.")
                : "Personal Hotspot turned off.")
        }
        updateBatteryMonitoring()
        publishExternalState()
    }

    /// Plays the silent sound while the hotspot is on, and for a while after it goes, see
    /// `KeepAlivePolicy`. Once it stops, iOS suspends Ferry, and it starts again when opened.
    private func keepAliveWhileSharing(hotspot: Bool, now: Date = Date()) {
        // On screen the wait keeps starting again, so the sound never stops there, and the 10 minutes
        // run from leaving the screen, to turn on Personal Hotspot in Settings, say.
        if hotspot { waitingSince = nil } else if sceneActive || waitingSince == nil { waitingSince = now }
        let plays = KeepAlivePolicy.plays(waitingSince: waitingSince, now: now, idleLimit: idleLimit)
        if plays { keepAlive.start() } else if keepAlive.playing {
            append("no hotspot for \(idleTimeoutMinutes) minutes, letting iOS suspend Ferry until it's opened")
            keepAlive.stop()
        }
    }

    /// If WireGuard can't start, the problem shows on the WireGuard screen. The watcher tries
    /// again on its next round, and a problem is logged once, not on every try.
    private func startWireGuard(on hotspot: String) {
        if !wireGuardDevices.loaded, !wireGuardDevices.needsReset {
            wireGuardDevices.load() // the Keychain can be locked until the first unlock after a restart
            publishSetup()
        }
        if let error = wireGuardDevices.loadError {
            wireGuardFailed(wireGuardDevices.needsReset
                ? "Its saved keys can't be read. Start over with new keys to use it."
                : "Its keys can't be read yet. Unlock this iPhone once.", error)
            return
        }
        do {
            try wireGuard.start(host: hotspot, setup: wireGuardDevices.setup)
            wireGuardProblem = nil
            append("WireGuard on \(hotspot):\(WireGuardSetup.port), \(wireGuardPeers.count) devices")
        } catch {
            wireGuardFailed("It couldn't start: \(error)", error)
        }
    }

    private func wireGuardFailed(_ problem: String, _ error: Error) {
        guard problem != wireGuardProblem else { return }
        wireGuardProblem = problem
        append("WireGuard not started: \(error)")
    }

    /// The same as opening Ferry, for Start Ferry in Shortcuts: the 10 minutes' wait for the hotspot
    /// starts again, and sharing starts now if the hotspot is on. True when the silent sound plays,
    /// so iOS keeps Ferry running after the action ends.
    @discardableResult
    func wake() -> Bool {
        #if DEBUG
        if demo != nil { return true }
        #endif
        if waitingSince != nil { waitingSince = Date() }
        syncWithHotspot()
        return keepAlive.sounding
    }

    /// For the Shortcuts actions. Off screen the sampler doesn't run, so the connected devices are read now.
    func shortcutState() -> ShortcutReply.State {
        var connected = wireGuardConnected
        if running, wireGuard.running {
            _ = wireGuard.snapshot() // refreshes connectedAddresses
            connected = wireGuard.connectedAddresses
        }
        return ShortcutReply.State(running: running, connected: connected.count, problem: wireGuardProblem)
    }

    var wireGuardNeedsReset: Bool { wireGuardDevices.needsReset }

    /// Gives up on saved keys this version can't read: a new server key and no devices.
    func resetWireGuard() {
        wireGuardDevices.reset()
        publishSetup()
        wireGuardProblem = nil
        append("WireGuard keys started over")
        if running, let boundHost { startWireGuard(on: boundHost) }
    }

    /// Only the name Ferry shows changes. The tunnel already imported keeps its own name.
    func renameWireGuardDevice(_ id: WireGuardSetup.Peer.ID, to name: String) {
        if !wireGuardDevices.rename(id, to: name) { append("WireGuard: the new name couldn't be saved") }
        publishSetup()
    }

    func removeWireGuardDevice(_ id: WireGuardSetup.Peer.ID) {
        if let peer = wireGuardPeers.first(where: { $0.id == id }) {
            usage.forget(Self.key(for: peer))
            deviceSpeeds[Self.key(for: peer)] = nil
        }
        if !wireGuardDevices.remove(id) { append("WireGuard: the removal couldn't be saved, the device stays") }
        wireGuardPeersChanged()
    }

    /// The key a device's usage, speeds and last-seen are filed under: its public key, so
    /// they follow the device even if its tunnel address is reused by another later.
    static func key(for peer: WireGuardSetup.Peer) -> String {
        peer.publicKey.base64EncodedString()
    }

    func usageToday(for peer: WireGuardSetup.Peer) -> DeviceUsage { usage.todayUsage(for: Self.key(for: peer)) }
    func usageSession(for peer: WireGuardSetup.Peer) -> DeviceUsage { usage.sessionUsage(for: Self.key(for: peer)) }
    func usageAllTime(for peer: WireGuardSetup.Peer) -> DeviceUsage { usage.allTimeUsage(for: Self.key(for: peer)) }
    func speed(for peer: WireGuardSetup.Peer) -> (down: Double, up: Double) { deviceSpeeds[Self.key(for: peer)] ?? (0, 0) }
    func lastSeen(for peer: WireGuardSetup.Peer) -> Date? { deviceLastSeen[Self.key(for: peer)] }
    func lastHandshake(for peer: WireGuardSetup.Peer) -> Date? { deviceHandshakes[Self.key(for: peer)] }

    /// Pauses or resumes a device by hand. A paused device leaves the server's peer list
    /// at once (see `wireGuardPeersChanged`), so its traffic stops; its key stays.
    func setWireGuardDevicePaused(_ peer: WireGuardSetup.Peer, _ paused: Bool) {
        if !wireGuardDevices.setPaused(peer.id, paused) { append("WireGuard: the pause couldn't be saved") }
        wireGuardPeersChanged()
    }

    /// Makes a device a guest until `expiresAt`, or permanent again with nil. Only the
    /// record changes; enforcement (removal at the date) happens on the sampler/watcher.
    func setWireGuardDeviceExpiry(_ peer: WireGuardSetup.Peer, to expiresAt: Date?) {
        if !wireGuardDevices.setExpiry(peer.id, to: expiresAt) { append("WireGuard: the guest change couldn't be saved") }
        publishSetup()
    }

    /// Sets the device's daily data cap. If it is already past the new cap, the next
    /// sample pauses it — usually the one a second later.
    func setWireGuardDeviceCap(_ peer: WireGuardSetup.Peer, to capBytes: UInt64?) {
        if !wireGuardDevices.setCap(peer.id, to: capBytes) { append("WireGuard: the cap couldn't be saved") }
        publishSetup()
    }

    func setWireGuardDeviceKind(_ peer: WireGuardSetup.Peer, to kind: WireGuardSetup.Kind) {
        if !wireGuardDevices.setKind(peer.id, to: kind) { append("WireGuard: the kind couldn't be saved") }
        publishSetup()
    }

    /// The Diagnostics screen reads these.
    var wireGuardRunning: Bool { wireGuard.running }
    var keepAliveActive: Bool { keepAlive.playing }

    func wireGuardConfig(for peer: WireGuardSetup.Peer) -> String {
        wireGuardDevices.setup.clientConfig(for: peer)
    }

    private func publishSetup() {
        wireGuardPeers = wireGuardDevices.setup.peers
        wireGuardReady = wireGuardDevices.setup.ready
    }

    private func wireGuardPeersChanged() {
        publishSetup()
        do { try wireGuard.setPeers(wireGuardDevices.setup) } catch { append("WireGuard devices: \(error)") }
    }

    /// Reads the server's counters, see `startSampler`: which devices are connected, and the speeds
    /// from how far the counters moved since the last sample. A device that connected with the QR
    /// code is listed here, and the code changes for the next one.
    /// `snapshot()` reads a small JSON from Go, which is fine to do on the main actor.
    func sampleTraffic() {
        let now = Date()
        refreshExpiryWarning(now: now)
        guard running else {
            // A new session starts with zero speeds and nobody connected.
            lastSample = nil
            if downSpeed != 0 { downSpeed = 0 }
            if upSpeed != 0 { upSpeed = 0 }
            if !wireGuardConnected.isEmpty { wireGuardConnected = [] }
            publishExternalState()
            return
        }
        let snap = wireGuard.snapshot()
        defer { lastSample = (snap.bytesUp, snap.bytesDown, now) }
        let connected = wireGuard.connectedAddresses // from the snapshot above
        let wasConnected = wireGuardConnected
        if connected != wireGuardConnected { wireGuardConnected = connected }
        claimReady(connected: connected)
        // After claiming, so a device that just paired is in the list and has its name.
        if connected != wasConnected { notifyConnectionChanges(from: wasConnected, to: connected) }
        recordUsage(now: now)
        enforceAccess(now: now)
        checkBattery()
        guard let last = lastSample else { publishExternalState(); return } // the first sample has nothing to compare with
        let seconds = now.timeIntervalSince(last.at)
        guard seconds > 0 else { publishExternalState(); return }
        upSpeed = Self.bps(snap.bytesUp, last.up, seconds)
        downSpeed = Self.bps(snap.bytesDown, last.down, seconds)
        speedHistory.append(SpeedSample(date: now, down: downSpeed, up: upSpeed))
        if speedHistory.count > 3600 { speedHistory.removeFirst(speedHistory.count - 3600) }
        publishExternalState()
    }

    /// Feeds the server's per-device counters to the usage tracker, and works out each
    /// device's speed and last-seen from the same readings. The readings are cumulative
    /// (the server's carried totals), so what a device used while the screen was off is
    /// in the difference when the next sample arrives.
    private func recordUsage(now: Date) {
        let readings = wireGuard.peerSnapshot()
        var byKey: [String: DeviceUsage] = [:]
        var speeds: [String: (down: Double, up: Double)] = [:]
        let seconds = lastUsageAt.map { now.timeIntervalSince($0) } ?? 0
        for peer in wireGuardDevices.setup.serverPeers {
            guard let reading = readings[peer.address] else { continue }
            let key = Self.key(for: peer)
            let current = DeviceUsage(up: reading.totals.bytesUp, down: reading.totals.bytesDown)
            byKey[key] = current
            if let handshake = reading.lastHandshake {
                if handshake != deviceHandshakes[key] { deviceHandshakes[key] = handshake }
                markSeen(key, handshake)
            }
            if let before = lastUsageReadings[key], seconds > 0 {
                let movedDown = UsageTracker.delta(new: current.down, old: before.down)
                let movedUp = UsageTracker.delta(new: current.up, old: before.up)
                speeds[key] = (Double(movedDown) * 8 / seconds, Double(movedUp) * 8 / seconds)
                if movedDown + movedUp > 0 { markSeen(key, now) }
            }
        }
        lastUsageReadings = byKey
        lastUsageAt = now
        deviceSpeeds = speeds
        if usage.record(byKey, now: now) {
            liftCapPauses() // a new day: yesterday's cap pauses lift by themselves
        }
        if now.timeIntervalSince(lastUsageSave) > 10 {
            lastUsageSave = now
            UsageStore.save(usage)
        }
    }

    private func markSeen(_ key: String, _ date: Date) {
        if let current = deviceLastSeen[key], current >= date { return }
        deviceLastSeen[key] = date
    }

    /// Guests whose time is up are removed (their keys stop working), and a device that
    /// reaches its data cap for today is paused until tomorrow.
    private func enforceAccess(now: Date) {
        for peer in wireGuardDevices.setup.expiredPeers(now: now) {
            append("WireGuard: guest \(peer.name) expired, removing it")
            removeWireGuardDevice(peer.id)
        }
        for peer in wireGuardPeers where !peer.paused && peer.capBytes != nil {
            let used = usage.todayUsage(for: Self.key(for: peer)).total
            guard UsageTracker.capReached(usedToday: used, capBytes: peer.capBytes) else { continue }
            if wireGuardDevices.setPaused(peer.id, true, reason: .cap) {
                append("WireGuard: \(peer.name) reached its data cap for today, paused until tomorrow")
                notifier.deviceCapped(peer.name)
            }
            wireGuardPeersChanged()
        }
    }

    /// A new day starts with no cap reached: devices the cap paused come back.
    private func liftCapPauses() {
        var lifted = false
        for peer in wireGuardPeers where peer.paused && peer.pauseReason == .cap {
            if wireGuardDevices.setPaused(peer.id, false) { lifted = true }
        }
        if lifted {
            wireGuardPeersChanged()
            append("WireGuard: a new day, cap-paused devices are back")
        }
    }

    private func notifyConnectionChanges(from old: Set<String>, to new: Set<String>) {
        for address in new.subtracting(old) where notifyJoins {
            if let peer = wireGuardPeers.first(where: { $0.address == address }) { notifier.deviceJoined(peer.name) }
        }
        for address in old.subtracting(new) where notifyLeaves {
            if let peer = wireGuardPeers.first(where: { $0.address == address }) { notifier.deviceLeft(peer.name) }
        }
    }

    /// The battery guard: warn once on the way down, stop sharing at the chosen level
    /// while on battery, and stay stopped until the battery recovers or the person
    /// resumes. Runs on the sampler (on screen) and the watcher (background).
    private func checkBattery() {
        updateBatteryMonitoring()
        let threshold = batteryThresholdPercent
        guard threshold > 0 else { batteryWarned = false; return }
        let device = UIDevice.current
        let level = device.batteryLevel
        let charging = device.batteryState == .charging || device.batteryState == .full
        if batteryBlocked || batteryOverride {
            if batteryRecovered() {
                let wasBlocked = batteryBlocked
                batteryBlocked = false
                batteryOverride = false
                batteryWarned = false
                append("battery recovered, the guard steps aside")
                if wasBlocked { syncWithHotspot() }
            }
            return
        }
        if BatteryGuard.shouldWarn(level: level, isCharging: charging, thresholdPercent: threshold) {
            if !batteryWarned {
                batteryWarned = true
                notifier.batteryWarning(percent: Int((level * 100).rounded()), threshold: threshold)
            }
        } else if level * 100 > Float(threshold + 10) {
            batteryWarned = false
        }
        guard running, BatteryGuard.shouldStop(level: level, isCharging: charging, thresholdPercent: threshold) else { return }
        batteryBlocked = true
        wireGuard.stop()
        running = false
        keepAlive.stop()
        append("battery at \(Int((level * 100).rounded()))%, the battery guard stopped sharing")
        if notifyStopped {
            notifier.sharingStopped(reason: "Battery fell to \(Int((level * 100).rounded()))%. Plug in, or resume in Ferry.")
        }
        publishExternalState()
    }

    /// The battery is past the guard's stop level again: charging, or clear water above it.
    private func batteryRecovered() -> Bool {
        let device = UIDevice.current
        return BatteryGuard.recovered(level: device.batteryLevel,
                                      isCharging: device.batteryState == .charging || device.batteryState == .full,
                                      thresholdPercent: batteryThresholdPercent)
    }

    /// The Resume button on the battery section: sharing starts again now, and the guard
    /// stays out of the way until the battery recovers properly.
    func resumeAfterBatteryGuard() {
        batteryBlocked = false
        batteryOverride = true
        syncWithHotspot()
    }

    /// Battery levels only read while sharing or while the guard is on. Monitoring once
    /// enabled is left on: it's the Diagnostics screen's battery row too.
    private func updateBatteryMonitoring() {
        if (running || batteryThresholdPercent > 0), !UIDevice.current.isBatteryMonitoringEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
    }

    /// The Live Activity and the widget snapshot follow the model from here, so every
    /// caller (sampler, watcher, sync) publishes the same way.
    private func publishExternalState() {
        sharingActivity.update(sharing: sharing, connectedDevices: wireGuardConnected.count,
                               downSpeed: downSpeed, upSpeed: upSpeed,
                               usageToday: usage.todayTotal().total)
    }

    /// A device that connected with the QR code is listed, and the code changes for the next one.
    /// Not saved means not claimed: the next check tries again.
    private func claimReady(connected: Set<String>) {
        guard let ready = wireGuardReady, connected.contains(ready.address),
              wireGuardDevices.claimReady(address: ready.address) else { return }
        append("WireGuard: a new device connected with the QR code")
        wireGuardPeersChanged()
    }

    /// The watcher's check in the background, where the sampler doesn't run, so a device that
    /// connects then is listed too and the next one gets a new code. The usage, guest, cap
    /// and battery rules run here too, at the watcher's slower cadence: a cap or a guest
    /// expiry shouldn't wait for the screen to come back.
    private func claimReadyInBackground() {
        guard running else { return }
        _ = wireGuard.snapshot() // refreshes connectedAddresses
        let wasConnected = wireGuardConnected
        wireGuardConnected = wireGuard.connectedAddresses
        claimReady(connected: wireGuard.connectedAddresses)
        if wireGuardConnected != wasConnected { notifyConnectionChanges(from: wasConnected, to: wireGuardConnected) }
        let now = Date()
        recordUsage(now: now)
        enforceAccess(now: now)
        checkBattery()
        UsageStore.save(usage)
        lastUsageSave = now
        publishExternalState()
    }

    /// The server's counters never go backwards. The guard is only a safety net.
    private static func bps(_ new: UInt64, _ old: UInt64, _ seconds: TimeInterval) -> Double {
        new >= old ? Double(new - old) * 8 / seconds : 0
    }

    private func observeScene() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ action: @escaping @MainActor (Model) -> Void) {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
        }
        observe(UIApplication.didBecomeActiveNotification) { model in
            model.sceneActive = true
            // Opening Ferry starts the wait again, so there's time to turn on Personal Hotspot in Settings.
            model.wake()
            model.startSampler() // samples at once, then every second again
        }
        observe(UIApplication.willResignActiveNotification) { model in
            model.sceneActive = false
            model.sampler?.cancel()
            model.lastSample = nil // or the first speed back on screen averages the whole time away
            UsageStore.save(model.usage)
        }
        observe(UIApplication.didReceiveMemoryWarningNotification) { $0.wireGuard.freeMemory() }
    }

    /// Internal log, read in Console.app. Nothing in the app shows it.
    private func append(_ s: String) {
        Self.logger.info("\(s, privacy: .public)")
    }
}

enum Interfaces {
    /// iOS Personal Hotspot always gives the phone 172.20.10.1 on a bridge interface.
    /// Matching the subnet, not only the name, keeps other bridges out.
    static func hotspotAddress() -> String? {
        ipv4().lazy
            .filter { $0.hasPrefix("bridge") }
            .compactMap { $0.components(separatedBy: ": ").last }
            .first { $0.hasPrefix("172.20.10.") }
    }

    static func ipv4() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let name = String(cString: p.pointee.ifa_name)
            let addr = String(cString: host)
            if name != "lo0" { out.append("\(name): \(addr)") }
        }
        return out
    }
}
