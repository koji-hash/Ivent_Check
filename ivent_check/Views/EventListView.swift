import SwiftUI

/// S-03 リスト
struct EventListView: View {
    @Environment(AppModel.self) private var model
    @State private var showFilter = false

    var body: some View {
        @Bindable var store = model.store
        NavigationStack {
            List {
                if store.isShowingCache {
                    Label("オフライン：前回の検索結果を表示しています", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                ForEach(store.sections, id: \.title) { section in
                    Section {
                        ForEach(section.hits) { hit in
                            NavigationLink(value: hit.event) {
                                EventRow(event: hit.event, distance: hit.distance)
                            }
                        }
                    } header: {
                        Text("\(section.title)（\(section.hits.count)件）")
                    }
                }
                if let updated = store.lastUpdated, !store.hits.isEmpty {
                    Text("最終更新 \(EventFormatters.dateTime.string(from: updated))・距離は\(model.originName)から")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .overlay {
                if store.visibleHits.isEmpty {
                    if store.isLoading {
                        ProgressView("検索中…")
                    } else if model.needsArea {
                        ContentUnavailableView("エリアが未設定です", systemImage: "location.slash",
                                               description: Text("設定タブで駅名・地名を指定してください。"))
                    } else {
                        ContentUnavailableView("イベントが見つかりません", systemImage: "calendar.badge.exclamationmark",
                                               description: Text("距離や期間、カテゴリの条件を変えてみてください。"))
                    }
                }
            }
            .searchable(text: $store.keyword, prompt: "キーワードで絞り込み")
            .refreshable { await model.refresh() }
            .navigationTitle("イベント")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("並び順", selection: $store.sortOrder) {
                            ForEach(EventSortOrder.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Label("並び順", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilter = true } label: {
                        Image(systemName: store.filter.isDefault ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("フィルタ")
                }
            }
            .navigationDestination(for: Event.self) { EventDetailView(event: $0) }
            .sheet(isPresented: $showFilter) { FilterView() }
        }
    }
}
