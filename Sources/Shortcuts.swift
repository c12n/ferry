import AppIntents

// Actions for the Shortcuts app, Siri, Spotlight and the Action button. iOS suspends Ferry
// once nothing has been on the hotspot for the idle timeout (KeepAlivePolicy; 10 minutes by
// default, adjustable in Settings), and Shortcuts has no trigger for Personal Hotspot
// turning on. So a shortcut turns the hotspot on with Shortcuts' own Set Personal Hotspot
// action, then runs Start Ferry, which wakes Ferry in the background without opening it.

struct StartTetherIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Ferry"
    static var description = IntentDescription(
        "Wakes Ferry in the background, the same as opening it. It shares as soon as a device joins Personal Hotspot. Put it after Set Personal Hotspot.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let model = Model.shared
        let keptAlive = model.wake()
        let state = model.shortcutState()
        return .result(value: state.sharing, dialog: "\(ShortcutReply.start(state, keptAlive: keptAlive, idleLimit: model.idleLimit))")
    }
}

struct TetherStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Is Ferry Sharing?"
    static var description = IntentDescription(
        "True while Ferry is sharing Personal Hotspot, for an If in a shortcut. It also says how many devices are connected.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let model = Model.shared
        model.syncWithHotspot() // a cold launch for this action hasn't looked at the hotspot yet
        let state = model.shortcutState()
        return .result(value: state.sharing, dialog: "\(ShortcutReply.status(state))")
    }
}

/// Ready in Shortcuts, Siri and Spotlight as soon as Ferry is installed, with nothing to set up.
struct TetherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartTetherIntent(),
                    phrases: ["Start \(.applicationName)", "Share internet with \(.applicationName)"],
                    shortTitle: "Start Ferry", systemImageName: "link")
        AppShortcut(intent: TetherStatusIntent(),
                    phrases: ["Is \(.applicationName) sharing", "\(.applicationName) status"],
                    shortTitle: "Is Ferry Sharing?", systemImageName: "link.circle")
    }
}
