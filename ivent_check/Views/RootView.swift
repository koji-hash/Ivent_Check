import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.settings.hasCompletedOnboarding {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.didBecomeActive()
            case .background: model.didEnterBackground()
            default: break
            }
        }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            MapHomeView()
                .tabItem { Label("地図", systemImage: "map") }
            EventListView()
                .tabItem { Label("リスト", systemImage: "list.bullet") }
            FavoritesView()
                .tabItem { Label("お気に入り", systemImage: "heart") }
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
        // 現在地・指定エリアが変わったら再検索
        .task(id: model.originKey) {
            model.recordCurrentLocation()
            await model.refresh()
        }
    }
}
