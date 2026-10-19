import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var navigation: AppNavigation

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            MainView()
                .tabItem { Label("Create", systemImage: "plus.circle.fill") }
                .tag(AppNavigation.Tab.create.rawValue)

            SecondaryView()
                .tabItem { Label("Play", systemImage: "gamecontroller.fill") }
                .tag(AppNavigation.Tab.play.rawValue)

            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(AppNavigation.Tab.history.rawValue)

            ProfileView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppNavigation.Tab.config.rawValue)
        }
    }
}
