import AppIntents
import Foundation

// Start and Stop for the Control Center, the Lock Screen and the interactive widget
// (iOS 18 controls; iOS 17 gets the same intents as widget buttons). Compiled into the
// app, where SharingControl runs the sharing controller, and into the widget
// extension, where SharingControl only leaves a request for the app (see
// SharingControlApp.swift and Widgets/SharingControlWidget.swift). The extension
// never links the Go framework.
//
// Both conform to AudioPlaybackIntent: Ferry keeps itself alive with silent audio,
// and an intent that declares audio playback is what lets iOS keep the app running
// after the intent finishes. Start also conforms to LiveActivityIntent, so starting
// from a control may start the Live Activity.

struct StartSharingIntent: AppIntent, AudioPlaybackIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Start Ferry"
    static var description = IntentDescription("Starts sharing, the same as opening Ferry with the hotspot on.")

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let started = await SharingControl.start()
        return .result(value: started)
    }
}

struct StopSharingIntent: AppIntent, AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Stop Ferry"
    static var description = IntentDescription("Stops sharing now. Personal Hotspot stays on; Ferry just stops passing traffic.")

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        await SharingControl.stop()
        return .result(value: true)
    }
}

/// The Control Center toggle's value intent (iOS 18). Setting it on is starting,
/// off is stopping; the toggle's shown state comes from the App Group snapshot's
/// heartbeat, not from this intent.
@available(iOS 18.0, *)
struct SetSharingIntent: SetValueIntent, AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Set Ferry Sharing"

    @Parameter(title: "Sharing")
    var value: Bool

    func perform() async throws -> some IntentResult {
        if value {
            _ = await SharingControl.start()
        } else {
            await SharingControl.stop()
        }
        return .result()
    }
}
