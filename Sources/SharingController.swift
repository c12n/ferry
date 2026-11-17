import Foundation

/// The one writer of sharing state. Everything that starts or stops sharing from
/// outside the main screen (the Control Center control, the widget's buttons, the
/// watch, Shortcuts) goes through here, so the start and stop paths can't drift
/// apart, and a request made while the app was suspended is applied once, in order.
/// The actor only sequences; the work itself is Model's, on the main actor.
actor SharingController {
    private let model: Model

    init(model: Model) {
        self.model = model
    }

    /// Wakes Ferry (the same as opening it) and waits until the server has had its
    /// chance to bind. True when Ferry is sharing afterwards.
    func requestStart() async -> Bool {
        await model.wake()
        // The watcher binds within its round; give it a moment before answering,
        // so the control doesn't report failure for a start that is still landing.
        for _ in 0..<10 {
            if await model.sharing { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return await model.sharing
    }

    /// Stops sharing now, with the full end-of-session sequence (see Model).
    func requestStop() async {
        await model.stopSharingNow(reason: "control")
    }

    func isSharing() async -> Bool {
        await model.sharing
    }
}
