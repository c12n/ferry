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
//   AccessControl.swift  the one blocked-check: approval, pauses, caps, guest passes, Foundation only
//   BillingCycle.swift  the monthly cycle's dates and cap alerts, Foundation only
//   UsageHistory.swift  per-day usage history, kept in the app's own container, Foundation only
//   UsageCSV.swift      the history as a spreadsheet file, Foundation only
//   Backup.swift        encrypted backup and restore, Foundation only
//   SessionRecord.swift  one sharing session's record and its summary, Foundation only
//   SharingController.swift  the one place outside callers start and stop sharing through
//   WatchBridge.swift   the watch app's status and its Stop command, app only
//   KeepAlive.swift, KeepAlivePolicy.swift  the silent sound that keeps Ferry running

import OSLog
import SwiftUI
import UIKit
import UserNotifications

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
    /// Per-day usage history, the source for the history screen, the billing cycle
    /// and the CSV export. See UsageHistory.swift. Keyed by device id, so a removed
    /// device's days stay, under its last name.
    @Published private(set) var history = UsageHistory()
    /// Why each device may not pass traffic right now, from the last access
    /// evaluation (see AccessControl). The device rows and screens show these.
    @Published private(set) var deviceBlocks: [WireGuardSetup.Peer.ID: AccessBlock] = [:]
    /// A finished session to show as a sheet, when sharing was stopped from inside
    /// the app while it was on screen. Background stops post a notification instead.
    @Published var sessionSummaryToShow: SessionRecord?
    /// One-time guest passes' private keys, by device id. Memory only, on purpose:
    /// a guest code can be shown while its sheet is open and never again.
    @Published private(set) var guestKeyIDs: Set<WireGuardSetup.Peer.ID> = []
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
    /// Approval mode: a device that connects with the QR code waits, passing no
    /// traffic, until it is approved (see AccessControl).
    @Published var approvalMode: Bool = (UserDefaults.standard.object(forKey: "tether.approvalMode") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(approvalMode, forKey: "tether.approvalMode") }
    }
    /// The day of the month the billing cycle starts on, 1 to 31 (clamped to the
    /// month, see BillingCycle).
    @Published var billingDay: Int = (UserDefaults.standard.object(forKey: "tether.billingDay") as? Int) ?? 1 {
        didSet { UserDefaults.standard.set(billingDay, forKey: "tether.billingDay") }
    }
    /// The monthly cap on Ferry usage over one billing cycle, all devices together.
    /// Nil is no cap. At the cap every device is blocked until the next cycle.
    @Published var monthlyCapBytes: UInt64? = UserDefaults.standard.object(forKey: "tether.monthlyCapBytes") as? UInt64 {
        didSet {
            if let monthlyCapBytes {
                UserDefaults.standard.set(monthlyCapBytes, forKey: "tether.monthlyCapBytes")
            } else {
                UserDefaults.standard.removeObject(forKey: "tether.monthlyCapBytes")
            }
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
    /// The one place outside callers (controls, widget, watch, Shortcuts) start and
    /// stop sharing through. Lazy: it needs the finished model.
    lazy var controller = SharingController(model: self)
    /// The watch app's bridge. Lazy like the controller; the app delegate activates it.
    lazy var watchBridge = WatchBridge(model: self)
    /// The open sharing session's record, saved as it goes (see SessionRecord.swift).
    private var sessionRecord: SessionRecord?
    /// Sharing was stopped on purpose (a control, the watch, in the app) while the
    /// hotspot is still on: it stays stopped until the hotspot goes, or Ferry is
    /// opened or started again.
    private var manualStop = false
    /// Devices whose approval request has already been notified, by id, kept across
    /// launches so a waiting device isn't announced again on every launch.
    private var approvalNotified: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "tether.approvalNotified") ?? [])
    /// The billing cycle the cap alerts were last sent for, and which went out.
    private var billingAlertCycle: String = UserDefaults.standard.string(forKey: "tether.billingAlertCycle") ?? ""
    private var billingAlertsSent: Set<Int> = Set(UserDefaults.standard.array(forKey: "tether.billingAlertsSent") as? [Int] ?? [])
    private var historyDirty = false
    private var guestKeys: [WireGuardSetup.Peer.ID: Data] = [:]
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
        // Guest passes whose code lapsed unused while Ferry was closed are pruned
        // too, and their keys denied.
        _ = wireGuardDevices.pruneLapsedGuestPasses(now: Date())
        publishSetup()
        // The notification delegate and the approval actions exist from launch, or
        // an approval answered from a notification couldn't be delivered.
        notifier.registerCategories()
        notifier.approvalHandler = { [weak self] id, fingerprint, approve in
            self?.resolveApproval(id: id, fingerprint: fingerprint, approve: approve)
        }
        UNUserNotificationCenter.current().delegate = notifier
        loadHistoryAndMigrate()
        recoverSessionRecord()
        refreshExpiryWarning()
        observeScene()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                self?.consumeControlRequest()
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

    /// Loads the per-day history, seeding it once from the tracker's totals (the
    /// 1.1.x record): today's counts become today's bucket, the rest is marked as
    /// before per-day records. The tracker keeps its own store and keeps running;
    /// the history only ever adds new deltas from here, so nothing counts twice.
    private func loadHistoryAndMigrate() {
        history = UsageHistoryStore.load()
        let migratedFlag = "tether.historyMigrated.v1"
        if history.isEmpty, !UserDefaults.standard.bool(forKey: migratedFlag) {
            let keyToPeer = Dictionary(uniqueKeysWithValues: wireGuardDevices.setup.peers.map {
                (Self.key(for: $0), $0.id.uuidString)
            })
            let seeded = UsageHistory.migrating(from: usage, keyToPeer: keyToPeer, now: Date())
            if !seeded.isEmpty {
                history = seeded
                UsageHistoryStore.save(history)
            }
            UserDefaults.standard.set(true, forKey: migratedFlag)
        }
        if !history.isEmpty {
            history.prune(keepingDays: 400, now: Date())
            UsageHistoryStore.save(history)
        }
    }

    private static let sessionRecordKey = "tether.sessionRecord.v1"

    /// A session record still open at launch means the last session ended without
    /// Ferry seeing it (the app was killed, the phone restarted). It is closed at
    /// its last heartbeat and summarized, unless it is over a day old, when it is
    /// dropped quietly: a summary that late is noise.
    private func recoverSessionRecord() {
        guard let data = UserDefaults.standard.data(forKey: Self.sessionRecordKey),
              let record = try? JSONDecoder().decode(SessionRecord.self, from: data) else { return }
        UserDefaults.standard.removeObject(forKey: Self.sessionRecordKey)
        guard record.isOpen, !record.isStale(now: Date()) else { return }
        let closed = record.closedUnexpectedly()
        if SessionSummary.shouldPost(closed, now: Date()), notifyStopped {
            notifier.sessionSummary(title: SessionSummary.title(closed),
                                    body: SessionSummary.body(closed, now: Date()))
        }
    }

    private func saveSessionRecord() {
        if let sessionRecord, let data = try? JSONEncoder().encode(sessionRecord) {
            UserDefaults.standard.set(data, forKey: Self.sessionRecordKey)
        }
    }

    private func openSession(now: Date) {
        guard sessionRecord == nil else { return }
        sessionRecord = SessionRecord(startedAt: now, lastHeartbeatAt: now)
        saveSessionRecord()
    }

    /// Keeps the open record current: its heartbeat, each device's session usage,
    /// and the most devices connected at once.
    private func updateSessionRecord(now: Date) {
        guard var record = sessionRecord else { return }
        record.lastHeartbeatAt = now
        for peer in wireGuardPeers {
            record.perPeer[peer.id.uuidString] = usage.sessionUsage(for: Self.key(for: peer))
        }
        record.peakConcurrent = max(record.peakConcurrent, wireGuardConnected.count)
        sessionRecord = record
        saveSessionRecord()
    }

    /// Closes the open session record and presents its summary: as a sheet when the
    /// stop was made in the app on screen, as a notification otherwise, and as the
    /// Live Activity's final state either way. True when a summary was presented.
    @discardableResult
    private func closeSession(reason: String, now: Date) -> Bool {
        guard var record = sessionRecord, record.isOpen else { return false }
        record.endedAt = now
        record.endReason = reason
        sessionRecord = nil
        UserDefaults.standard.removeObject(forKey: Self.sessionRecordKey)
        guard SessionSummary.shouldPost(record, now: now) else { return false }
        let body = SessionSummary.body(record, now: now)
        sharingActivity.endWithSummary(body, state: TetherActivityAttributes.ContentState(
            isSharing: false, connectedDevices: 0, downSpeed: 0, upSpeed: 0,
            usageToday: usage.todayTotal().total), now: now)
        if reason == "manual", sceneActive {
            sessionSummaryToShow = record
        } else if notifyStopped {
            notifier.sessionSummary(title: SessionSummary.title(record), body: body)
        }
        return true
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
        // A stop made on purpose (control, watch, in the app) holds while the hotspot
        // stays on. It clears when the hotspot goes, so the next hotspot is a fresh start.
        if manualStop {
            if Interfaces.hotspotAddress() == nil {
                manualStop = false
            } else {
                if wireGuard.running { wireGuard.stop() }
                if running { running = false }
                publishExternalState()
                return
            }
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
            openSession(now: Date())
            if notifyJoins || notifyLeaves || notifyStopped { notifier.requestAuthorization() }
        }
        if wasSharing, !sharing {
            // The session summary replaces the plain stopped notice when there is a
            // session worth summarizing; a brief one still gets the old notice.
            if !closeSession(reason: "hotspot", now: Date()), notifyStopped {
                notifier.sharingStopped(reason: running
                    ? (wireGuardProblem ?? "WireGuard stopped.")
                    : "Personal Hotspot turned off.")
            }
        }
        updateBatteryMonitoring()
        publishExternalState()
    }

    /// Stops sharing now, on purpose: from a control, the watch, or the app itself.
    /// The hotspot stays on; Ferry stops passing traffic and stays stopped until the
    /// hotspot goes or Ferry is started again. The end of a session has an order:
    /// a background task holds the app open, the server stops, the final usage is
    /// saved, the session record closes and its summary goes out, the widgets and
    /// controls are refreshed, and the keep-alive sound stops last, since stopping
    /// it is what lets iOS suspend Ferry.
    func stopSharingNow(reason: String) {
        guard running || wireGuard.running else { return }
        manualStop = true
        let task = UIApplication.shared.beginBackgroundTask(withName: "Ferry session end")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        wireGuard.stop()
        running = false
        recordUsage(now: Date()) // the final counters, into the tracker and the history
        UsageStore.save(usage)
        if historyDirty { UsageHistoryStore.save(history); historyDirty = false }
        closeSession(reason: reason, now: Date())
        publishExternalState()
        keepAlive.stop()
    }

    /// For SharingControl: a Start that found no hotspot shouldn't leave the
    /// keep-alive running.
    func stopKeepAliveAfterFailedStart() {
        keepAlive.stop()
    }

    /// For SharingControl: sharing was asked for with no hotspot to share.
    func notifyHotspotNeeded() {
        notifier.hotspotNeeded()
    }

    /// Acts on a Start or Stop left by the widget extension (see ControlRequestStore).
    /// Runs on the watcher's rounds, so a request is picked up within seconds while
    /// Ferry is alive in the background.
    private func consumeControlRequest() {
        guard let request = ControlRequestStore.consume() else { return }
        switch request {
        case .start:
            manualStop = false
            syncWithHotspot()
        case .stop:
            stopSharingNow(reason: "control")
        }
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
        manualStop = false // being opened or started again is the resume
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
            wireGuard.closePeer(address: peer.address) // its streams end now, not at the next sample
            approvalNotified.remove(peer.id.uuidString)
            UserDefaults.standard.set(Array(approvalNotified), forKey: "tether.approvalNotified")
            guestKeys[peer.id] = nil
            guestKeyIDs = Set(guestKeys.keys)
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

    /// Pauses a device until `until` (`.distantFuture` pauses it until it is resumed
    /// by hand), or resumes it with nil. The device stays in the server; the policy
    /// layer blocks it, and a timed pause ends by time passing alone.
    func setWireGuardDevicePausedUntil(_ peer: WireGuardSetup.Peer, _ until: Date?) {
        if !wireGuardDevices.setPausedUntil(peer.id, until) { append("WireGuard: the pause couldn't be saved") }
        wireGuardPeersChanged()
        evaluateAccess(now: Date())
    }

    /// Approves a device that was waiting, or sends an approved device back to waiting.
    func setWireGuardDeviceApproval(_ peer: WireGuardSetup.Peer, _ approval: WireGuardSetup.Approval) {
        if !wireGuardDevices.setApproval(peer.id, approval) { append("WireGuard: the approval couldn't be saved") }
        approvalNotified.remove(peer.id.uuidString)
        UserDefaults.standard.set(Array(approvalNotified), forKey: "tether.approvalNotified")
        wireGuardPeersChanged()
        evaluateAccess(now: Date())
    }

    /// Sets a device's speed limits in bytes per second, or lifts them with nil.
    func setWireGuardDeviceSpeedLimits(_ peer: WireGuardSetup.Peer, down: UInt64?, up: UInt64?) {
        if !wireGuardDevices.setSpeedLimits(peer.id, down: down, up: up) { append("WireGuard: the speed limits couldn't be saved") }
        publishSetup()
        evaluateAccess(now: Date())
    }

    /// An approval answered from the notification (or anywhere else): the device id
    /// plus the key fingerprint the notification carried. A fingerprint that no
    /// longer matches means the notification is stale, and nothing happens.
    func resolveApproval(id: WireGuardSetup.Peer.ID, fingerprint: String, approve: Bool) {
        guard let peer = wireGuardPeers.first(where: { $0.id == id }),
              peer.keyFingerprint == fingerprint else { return }
        if approve {
            setWireGuardDeviceApproval(peer, .approved)
        } else {
            // Denying is forever for this key: the key is denied first, then the
            // device is removed, so it can't come back even if the removal fails.
            if !wireGuardDevices.denyKey(peer.publicKey) { append("WireGuard: the denial couldn't be saved") }
            removeWireGuardDevice(peer.id)
        }
    }

    /// The devices waiting for approval, for the main screen's section.
    var pendingDevices: [WireGuardSetup.Peer] {
        wireGuardPeers.filter { $0.approval == .pending }
    }

    /// Why this device may not pass traffic right now, if anything.
    func block(for peer: WireGuardSetup.Peer) -> AccessBlock? { deviceBlocks[peer.id] }

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
    /// Whether the silent sound is playing, for the Shortcuts reply.
    var keepAliveSounding: Bool { keepAlive.sounding }

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
        evaluateAccess(now: now)
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
        let today = UsageTracker.stamp(for: now, calendar: .current)
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
                if movedDown + movedUp > 0 {
                    markSeen(key, now)
                    // The same delta goes into the per-day history, under the
                    // device's permanent id (the tracker files it under its key).
                    history.add(DeviceUsage(up: movedUp, down: movedDown),
                                peer: peer.id.uuidString, name: peer.name, day: today)
                    historyDirty = true
                }
            }
        }
        lastUsageReadings = byKey
        lastUsageAt = now
        deviceSpeeds = speeds
        _ = usage.record(byKey, now: now)
        noticeApprovalArrivals(readings: readings)
        noticeGuestConsumption(readings: readings, now: now)
        if now.timeIntervalSince(lastUsageSave) > 10 {
            lastUsageSave = now
            UsageStore.save(usage)
            if historyDirty {
                UsageHistoryStore.save(history)
                historyDirty = false
            }
            updateSessionRecord(now: now)
        }
    }

    /// A device waiting for approval announces itself by handshaking: it can pass no
    /// traffic, so the handshake is all it can do. Announced once per device, ever
    /// (the set is kept across launches), until it is approved, denied or removed.
    private func noticeApprovalArrivals(readings: [String: WireGuardServer.PeerReading]) {
        for peer in wireGuardPeers where peer.approval == .pending {
            guard readings[peer.address]?.lastHandshake != nil,
                  !approvalNotified.contains(peer.id.uuidString) else { continue }
            approvalNotified.insert(peer.id.uuidString)
            UserDefaults.standard.set(Array(approvalNotified), forKey: "tether.approvalNotified")
            notifier.requestAuthorization()
            notifier.approvalRequested(id: peer.id, fingerprint: peer.keyFingerprint, name: peer.name)
        }
    }

    /// A guest pass is used the first time its device handshakes. Its key, which only
    /// ever lived in memory, is dropped; with approval mode on the guest then waits
    /// for approval like any new device.
    private func noticeGuestConsumption(readings: [String: WireGuardServer.PeerReading], now: Date) {
        for peer in wireGuardPeers where peer.guestPass != nil && peer.guestPass?.consumedAt == nil {
            guard readings[peer.address]?.lastHandshake != nil else { continue }
            guard wireGuardDevices.consumeGuestPass(peer.id, at: now) else { continue }
            guestKeys[peer.id] = nil
            guestKeyIDs = Set(guestKeys.keys)
            append("WireGuard: a guest pass was used by \(peer.name)")
            if approvalMode, peer.approval == .approved {
                _ = wireGuardDevices.setApproval(peer.id, .pending)
            }
            publishSetup()
            evaluateAccess(now: now)
        }
    }

    private func markSeen(_ key: String, _ date: Date) {
        if let current = deviceLastSeen[key], current >= date { return }
        deviceLastSeen[key] = date
    }

    /// The one place access is decided (see AccessControl): guest passes whose code
    /// lapsed are pruned and denied, guests whose time is up are removed, the billing
    /// cycle's alerts go out, and every device's block and policy are worked out and
    /// sent to the server. Runs on the sampler and the watcher, and after any change
    /// to a device or a setting it depends on. Blocks are derived from usage and
    /// dates, never stored, so a cap pause lifts by the day turning and a timed
    /// pause by its date passing, with nothing needing to run at that moment.
    private func evaluateAccess(now: Date) {
        let pruned = wireGuardDevices.pruneLapsedGuestPasses(now: now)
        if !pruned.isEmpty {
            append("WireGuard: \(pruned.count) guest pass code(s) lapsed unused and were denied")
            publishSetup()
        }
        var removedAny = false
        for peer in wireGuardDevices.setup.expiredPeers(now: now) {
            append("WireGuard: guest \(peer.name) expired, removing it")
            usage.forget(Self.key(for: peer))
            removedAny = wireGuardDevices.remove(peer.id) || removedAny
        }
        if removedAny || !pruned.isEmpty { wireGuardPeersChanged() }

        let cycleUsed = cycleUsageTotal(now: now)
        checkBillingAlerts(used: cycleUsed, now: now)
        let monthlyCapReached = monthlyCapBytes.map { $0 > 0 && cycleUsed >= $0 } ?? false

        var blocks: [WireGuardSetup.Peer.ID: AccessBlock] = [:]
        var policies: [WireGuardServer.PeerPolicy] = []
        for peer in wireGuardDevices.setup.serverPeers {
            var policy = WireGuardServer.PeerPolicy(address: peer.address)
            policy.downBps = peer.downLimitBps ?? 0
            policy.upBps = peer.upLimitBps ?? 0
            if peer.id != wireGuardReady?.id {
                let block = AccessControl.block(
                    approval: peer.approval, pausedUntil: peer.pausedUntil,
                    guestAccessExpiresAt: peer.guestPass?.consumedAt != nil ? peer.guestPass?.accessExpiresAt : nil,
                    capBytes: peer.capBytes,
                    usedToday: usage.todayUsage(for: Self.key(for: peer)).total,
                    monthlyCapReached: monthlyCapReached, now: now)
                if let block {
                    blocks[peer.id] = block
                    switch block {
                    case .notApproved:
                        policy.noForward = true
                    case .paused(let until):
                        policy.pausedUntil = Int64(until.timeIntervalSince1970)
                    case .dailyCap, .monthlyCap, .guestAccessEnded:
                        policy.blockedNow = true
                    }
                    if block == .dailyCap, deviceBlocks[peer.id] != .dailyCap {
                        notifier.deviceCapped(peer.name)
                    }
                }
            }
            policies.append(policy)
        }
        if blocks != deviceBlocks { deviceBlocks = blocks }
        if policies != wireGuard.lastPolicies, wireGuard.running {
            if let error = wireGuard.setPolicies(policies) {
                append("WireGuard policies: \(error)")
            }
        }
    }

    /// Ferry usage over the current billing cycle, all devices together. Days come
    /// from the history; usage from before per-day records (the migration's legacy)
    /// counts towards a cycle that started before those records did.
    func cycleUsageTotal(now: Date) -> UInt64 {
        let range = BillingCycle.range(billingDay: billingDay, containing: now)
        let startDay = UsageTracker.stamp(for: range.start, calendar: .current)
        let endDay = UsageTracker.stamp(for: range.end, calendar: .current)
        var total = history.total(fromDay: startDay, toDayExclusive: endDay).total
        let firstRecorded = history.recordedDays.first ?? "9999-12-31"
        if startDay < firstRecorded {
            total += history.legacy.values.reduce(DeviceUsage()) { $0 + $1 }.total
        }
        return total
    }

    /// The current billing cycle, for the screens.
    func cycleRange(now: Date = Date()) -> (start: Date, end: Date) {
        BillingCycle.range(billingDay: billingDay, containing: now)
    }

    /// The 80% and 100% cap alerts, once per cycle each, only the highest newly
    /// crossed (see BillingCycle.crossedThreshold). The sent set is kept across
    /// launches, keyed by the cycle it belongs to.
    private func checkBillingAlerts(used: UInt64, now: Date) {
        guard let cap = monthlyCapBytes, cap > 0 else { return }
        let key = BillingCycle.key(forCycleStart: BillingCycle.start(billingDay: billingDay, containing: now))
        if key != billingAlertCycle {
            billingAlertCycle = key
            billingAlertsSent = []
            UserDefaults.standard.set(key, forKey: "tether.billingAlertCycle")
            UserDefaults.standard.set([Int](), forKey: "tether.billingAlertsSent")
        }
        guard let percent = BillingCycle.crossedThreshold(used: used, cap: cap, alreadySent: billingAlertsSent) else { return }
        billingAlertsSent.formUnion(percent >= 100 ? [80, 100] : [percent])
        UserDefaults.standard.set(Array(billingAlertsSent), forKey: "tether.billingAlertsSent")
        notifier.billingAlert(percent: percent, used: used, cap: cap)
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
        if !closeSession(reason: "battery", now: Date()), notifyStopped {
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
        let waiting = wireGuardPeers.filter { $0.approval == .pending }.count
        sharingActivity.update(sharing: sharing, connectedDevices: wireGuardConnected.count,
                               downSpeed: downSpeed, upSpeed: upSpeed,
                               usageToday: usage.todayTotal().total, waitingCount: waiting)
        watchBridge.publish(sharing: sharing, connectedDevices: wireGuardConnected.count,
                            downSpeed: downSpeed, upSpeed: upSpeed,
                            usageToday: usage.todayTotal().total, waitingCount: waiting)
    }

    /// A device that connected with the QR code is listed, and the code changes for the next one.
    /// Not saved means not claimed: the next check tries again.
    private func claimReady(connected: Set<String>) {
        guard let ready = wireGuardReady, connected.contains(ready.address),
              wireGuardDevices.claimReady(address: ready.address,
                                          approval: approvalMode ? .pending : .approved) else { return }
        append("WireGuard: a new device connected with the QR code")
        wireGuardPeersChanged()
        evaluateAccess(now: Date())
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
        evaluateAccess(now: now)
        checkBattery()
        UsageStore.save(usage)
        lastUsageSave = now
        publishExternalState()
    }

    /// The server's counters never go backwards. The guard is only a safety net.
    private static func bps(_ new: UInt64, _ old: UInt64, _ seconds: TimeInterval) -> Double {
        new >= old ? Double(new - old) * 8 / seconds : 0
    }

    // MARK: - One-time guest passes

    /// How many unused guest passes there can be at once: each holds a tunnel
    /// address, and addresses are finite.
    static let maxUnusedGuestPasses = 5

    /// Makes a one-time guest pass: its code works for 10 minutes, for one device,
    /// whose access then lasts 4 hours. The returned device carries its private key;
    /// Model keeps it in memory only (`guestKeys`), and the saved device has none.
    func createGuestPass(now: Date = Date()) -> WireGuardSetup.Peer? {
        guard wireGuardDevices.setup.unusedGuestPassCount < Self.maxUnusedGuestPasses else { return nil }
        guard let peer = wireGuardDevices.addGuestPass(qrExpiresAt: now.addingTimeInterval(10 * 60),
                                                       accessExpiresAt: now.addingTimeInterval(4 * 3600)) else {
            append("WireGuard: a guest pass couldn't be made or saved")
            return nil
        }
        guestKeys[peer.id] = peer.privateKey
        guestKeyIDs = Set(guestKeys.keys)
        wireGuardPeersChanged()
        return peer
    }

    /// The config a guest pass's QR code shows, while its key is still in memory.
    func guestConfig(for peer: WireGuardSetup.Peer) -> String? {
        guard let key = guestKeys[peer.id] else { return nil }
        var withKey = peer
        withKey.privateKey = key
        return wireGuardDevices.setup.clientConfig(for: withKey)
    }

    /// Forgets a guest pass's key: its code can never be shown again. The pass
    /// itself stays until it is used or its code lapses.
    func discardGuestKey(_ id: WireGuardSetup.Peer.ID) {
        guestKeys[id] = nil
        guestKeyIDs = Set(guestKeys.keys)
    }

    /// A fresh pass in place of this one (after a screenshot, say): the old device
    /// is removed and its key forgotten, a new one is made.
    func regenerateGuestPass(_ peer: WireGuardSetup.Peer) -> WireGuardSetup.Peer? {
        discardGuestKey(peer.id)
        removeWireGuardDevice(peer.id)
        return createGuestPass()
    }

    /// Takes a guest pass back before it is used.
    func revokeGuestPass(_ peer: WireGuardSetup.Peer) {
        discardGuestKey(peer.id)
        removeWireGuardDevice(peer.id)
    }

    // MARK: - Backup and restore

    /// The settings as a backup carries them.
    func backupSettings() -> FerryBackup.SettingsEntry {
        FerryBackup.SettingsEntry(idleTimeoutMinutes: idleTimeoutMinutes,
                                  batteryThresholdPercent: batteryThresholdPercent,
                                  notifyJoins: notifyJoins, notifyLeaves: notifyLeaves,
                                  notifyStopped: notifyStopped, approvalMode: approvalMode,
                                  billingDay: billingDay, monthlyCapBytes: monthlyCapBytes)
    }

    private func applyBackupSettings(_ settings: FerryBackup.SettingsEntry) {
        idleTimeoutMinutes = settings.idleTimeoutMinutes
        batteryThresholdPercent = settings.batteryThresholdPercent
        notifyJoins = settings.notifyJoins
        notifyLeaves = settings.notifyLeaves
        notifyStopped = settings.notifyStopped
        approvalMode = settings.approvalMode
        billingDay = settings.billingDay
        monthlyCapBytes = settings.monthlyCapBytes
    }

    /// A backup of the current setup and settings. `includesKeys` is the full
    /// backup (server key and device keys); without it, the export is settings and
    /// device names only, and restoring it can only restore settings.
    func makeBackup(includesKeys: Bool) -> FerryBackup {
        FerryBackup.make(from: wireGuardDevices.setup, settings: backupSettings(),
                         includesKeys: includesKeys,
                         appVersion: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.2.0",
                         now: Date())
    }

    /// Restores a validated backup: settings always; the setup too when the backup
    /// carries keys. The server stops, the setup is replaced, and the server starts
    /// again, so nothing runs on a half-restored setup. Throws BackupError.
    func restoreBackup(_ backup: FerryBackup) throws {
        let validated = try backup.validated()
        if validated.serverPrivateKey != nil {
            let setup = try validated.makeSetup(currentDeniedKeys: wireGuardDevices.setup.deniedKeys, now: Date())
            let wasRunning = wireGuard.running
            if wasRunning { wireGuard.stop() }
            guard wireGuardDevices.replaceSetup(setup) else {
                if wasRunning, let boundHost { startWireGuard(on: boundHost) }
                throw RestoreSaveFailed()
            }
            guestKeys = [:]
            guestKeyIDs = []
            publishSetup()
            if wasRunning, let boundHost { startWireGuard(on: boundHost) }
        }
        applyBackupSettings(validated.settings)
        evaluateAccess(now: Date())
        append("backup restored")
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
            if model.historyDirty {
                UsageHistoryStore.save(model.history)
                model.historyDirty = false
            }
            model.saveSessionRecord()
        }
        observe(UIApplication.didReceiveMemoryWarningNotification) { $0.wireGuard.freeMemory() }
    }

    /// Internal log, read in Console.app. Nothing in the app shows it.
    private func append(_ s: String) {
        Self.logger.info("\(s, privacy: .public)")
    }
}

/// Restoring a backup failed at the last step: the new setup couldn't be saved.
/// Nothing was changed.
struct RestoreSaveFailed: Error, CustomStringConvertible {
    var description: String { "The restored setup couldn't be saved, so nothing was changed." }
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
