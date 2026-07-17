import Foundation

/// 全局 tab 导航状态，通过 EnvironmentObject 在各层级间共享。
/// 使用 static 常量统一管理 tab 索引，避免魔法数字。
@MainActor
final class AppNavigation: ObservableObject {
    /// 落地页为设置页：apiHost 默认值已移除，必须先在此处配置才能正常使用其余 tab。
    @Published var selectedTab: Int = Tab.config.rawValue

    enum Tab: Int {
        case create  = 0
        case play    = 1
        case history = 2
        case config  = 3
    }

    func switchTo(_ tab: Tab) {
        selectedTab = tab.rawValue
    }
}
