import SwiftUI
import HappyOysterSDK
import os

/// Route SDK logs to Apple unified logging (os.Logger): fixed subsystem, one category per module tag,
/// so you can filter by category in Console.app / the Xcode console without substring searches.
let appLogSubsystem = "com.happyoyster.podexample"

/// The app's own logs (category = "app"), used by business layers such as TravelViewModel / MainView.
let appLogger = Logger(subsystem: appLogSubsystem, category: "app")

/// Unified log function: goes through os.Logger, visible in both the Xcode console and Console.app,
/// no extra print needed (Xcode shows os_log output directly; print would duplicate it).
func appLog(_ message: @autoclosure () -> String) {
    let msg = message()
    appLogger.notice("\(msg, privacy: .public)")
}

private let oysterLoggers: [String: Logger] = [
    "core", "network", "world", "stream", "control", "sdk", "rtc-trace",
].reduce(into: [:]) { $0[$1] = Logger(subsystem: appLogSubsystem, category: $1) }

@main
struct HappyOysterPodExampleApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var environment = AppEnvironment()
    @StateObject private var session = AppSession()
    @StateObject private var navigation = AppNavigation()

    init() {
        // Auto-dismiss the keyboard when drag-scrolling (interactive = can be pulled back up to cancel).
        UIScrollView.appearance().keyboardDismissMode = .interactive

        // Stream engine registration is done inside HappyOysterEngine.initialize; only logging is hooked up here.
        OysterLog.setHandler { level, tag, message in
            let logger = oysterLoggers[tag] ?? Logger(subsystem: appLogSubsystem, category: tag)
            switch level {
            case .debug:   logger.debug("\(message, privacy: .public)")
            case .info:    logger.info("\(message, privacy: .public)")
            case .warning: logger.warning("\(message, privacy: .public)")
            case .error:   logger.error("\(message, privacy: .public)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(environment)
                .environmentObject(session)
                .environmentObject(navigation)
                .task {
                    // One-time wiring of TokenManager and APIClient (idempotent; repeated calls are no-ops)
                    session.configure(environment: environment)
                }
        }
    }
}
