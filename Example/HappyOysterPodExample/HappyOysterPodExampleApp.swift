import SwiftUI
import HappyOysterSDK
import os

/// SDK 日志接到 Apple 统一日志（os.Logger）：subsystem 固定，每个模块 tag = 一个 category，
/// 可在 Console.app / Xcode 控制台按 category 勾选过滤，无需子串搜索。
let appLogSubsystem = "com.happyoyster.podexample"

/// App 自有日志（category = "app"），用于 TravelViewModel / MainView 等业务层。
let appLogger = Logger(subsystem: appLogSubsystem, category: "app")

/// 统一日志函数：走 os.Logger，Xcode 控制台与 Console.app 均可见，
/// 无需额外 print（Xcode 会直接展示 os_log 输出，print 会造成重复）。
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
        // 拖拽滚动时自动收起键盘（interactive = 可反悔往上拉回来）。
        UIScrollView.appearance().keyboardDismissMode = .interactive

        // 流引擎注册由 HappyOysterEngine.initialize 内部完成，这里只接日志。
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
                    // TokenManager 与 APIClient 一次性连接（幂等，重复调用无效）
                    session.configure(environment: environment)
                }
        }
    }
}
