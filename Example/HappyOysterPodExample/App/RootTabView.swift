import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var navigation: AppNavigation

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            MainView()
                .tabItem { Label("创建", systemImage: "plus.circle.fill") }
                .tag(AppNavigation.Tab.create.rawValue)

            SecondaryView()
                .tabItem { Label("游玩", systemImage: "gamecontroller.fill") }
                .tag(AppNavigation.Tab.play.rawValue)

            HistoryView()
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
                .tag(AppNavigation.Tab.history.rawValue)

            ProfileView()
                .tabItem { Label("配置", systemImage: "gearshape.fill") }
                .tag(AppNavigation.Tab.config.rawValue)
        }
    }
}
