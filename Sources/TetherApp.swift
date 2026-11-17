import SwiftUI
import UIKit

@main
struct TetherApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { MainView() }
    }
}

/// The few things that have to happen at launch, before anything can arrive:
/// the model exists (its init registers the notification categories and the
/// notification delegate, and recovers an unfinished session), and the watch
/// session is activated, since a session activated late misses the watch's
/// first messages.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let model = Model.shared
        model.watchBridge.activate()
        return true
    }
}
