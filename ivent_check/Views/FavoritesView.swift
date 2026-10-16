import SwiftUI
import SwiftData
import CoreLocation

/// S-06 お気に入り（終了済みの自動整理つき）
struct FavoritesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query(sort: \FavoriteEvent.startAt) private var favorites: [FavoriteEvent]

    var body: some View {
        let now = Date.now
        let upcoming = favorites.filter { $0.endAt > now }
        let ended = favorites.filter { $0.endAt <= now }

        NavigationStack {
            List {
                if !upcoming.isEmpty {
                    Section("予定") {
                        ForEach(upcoming) { row($0) }
                            .onDelete { delete(upcoming, at: $0) }
                    }
                }
                if !ended.isEmpty {
                    Section {
                        ForEach(ended) { row($0).opacity(0.6) }
                            .onDelete { delete(ended, at: $0) }
                        Button("終了済みをすべて削除", role: .destructive) {
                            ended.forEach(context.delete)
                            try? context.save()
                        }
                    } header: {
                        Text("終了済み")
                    } footer: {
                        Text("終了から\(Favorites.retentionDays)日が過ぎたイベントは自動で整理されます。")
                    }
                }
            }
            .overlay {
                if favorites.isEmpty {
                    ContentUnavailableView("お気に入りはまだありません", systemImage: "heart",
                                           description: Text("イベント詳細のハートをタップすると登録できます。前日と開始1時間前にお知らせします。"))
                }
            }
            .navigationTitle("お気に入り")
            .navigationDestination(for: Event.self) { EventDetailView(event: $0) }
        }
    }

    @ViewBuilder
    private func row(_ favorite: FavoriteEvent) -> some View {
        if let event = favorite.event {
            NavigationLink(value: event) {
                EventRow(event: event, distance: model.origin.map {
                    CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: event.location)
                })
            }
        }
    }

    private func delete(_ items: [FavoriteEvent], at offsets: IndexSet) {
        offsets.map { items[$0] }.forEach(context.delete)
        try? context.save()
        model.scheduleNotificationRefresh()
    }
}
