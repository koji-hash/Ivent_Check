import SwiftUI

/// S-04 フィルタ（期間・距離・カテゴリ・無料のみ）
struct FilterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SearchFilter()

    var body: some View {
        NavigationStack {
            Form {
                Section("期間") {
                    Picker("期間", selection: $draft.period) {
                        ForEach(DatePeriod.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Picker("半径", selection: $draft.radiusKm) {
                        ForEach(SearchFilter.radiusOptions, id: \.self) { Text("\(Int($0))").tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("距離（km以内）").textCase(nil)
                } footer: {
                    Text("現在地（または指定エリア）からの距離です。掲載している市区町村は「設定 > データ出典一覧」で確認できます。")
                }
                Section {
                    CategoryGrid(selection: $draft.categories)
                } header: {
                    HStack {
                        Text("カテゴリ")
                        Spacer()
                        if !draft.categories.isEmpty {
                            Button("選択解除") { draft.categories = [] }
                                .font(.caption)
                        }
                    }
                } footer: {
                    Text("未選択の場合はすべてのカテゴリを表示します。")
                }
                Section {
                    Toggle("無料のイベントのみ", isOn: $draft.freeOnly)
                }
            }
            .navigationTitle("絞り込み")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("適用") {
                        model.store.filter = draft
                        dismiss()
                        Task { await model.refresh(center: model.store.lastSearchCenter) }
                    }
                    .bold()
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("リセット") { draft = SearchFilter() }
                        .disabled(draft.isDefault)
                }
            }
            .onAppear { draft = model.store.filter }
        }
    }
}
