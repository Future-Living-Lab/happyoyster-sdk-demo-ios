import Foundation

/// Global tab navigation state, shared across levels via EnvironmentObject.
/// Tab indices are managed via constants to avoid magic numbers.
@MainActor
final class AppNavigation: ObservableObject {
    /// The landing page is Settings: apiHost / model have no defaults and must be configured here before the other tabs work.
    @Published var selectedTab: Int = Tab.config.rawValue

    enum Tab: Int {
        case create  = 0
        case play    = 1
        case history = 2
        case config  = 3
    }

    /// World mode to show when switching to the Play tab; nil means "unspecified, keep the Play page's current filter".
    ///
    /// The Play page's mode filter has no "All" (since models are split by mode, list requests must carry a definite mode),
    /// so after creating an Acting world, auto-jumping to a list still filtered to Wander would hide the newly created world.
    /// Set by the create flow once the world is ready and before switching tabs; the Play page resets it to nil after
    /// consuming it. It is **one-shot**, so filters the user later changes manually aren't overwritten by this stale value next time.
    @Published var pendingPlayMode: ServerWorldMode?

    func switchTo(_ tab: Tab) {
        selectedTab = tab.rawValue
    }

    /// Switch to the Play tab and specify the world mode to show (used to navigate after creation).
    func switchToPlay(mode: ServerWorldMode) {
        pendingPlayMode = mode
        selectedTab = Tab.play.rawValue
    }
}
