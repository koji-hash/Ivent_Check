import SwiftUI
import MapKit

/// F-LOC-02 地名・駅名による手動エリア指定
struct AreaSearchView: View {
    var onSelect: (ManualArea) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            List(results, id: \.self) { item in
                Button {
                    let coordinate = item.placemark.coordinate
                    onSelect(ManualArea(name: item.name ?? query, latitude: coordinate.latitude, longitude: coordinate.longitude))
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "").foregroundStyle(.primary)
                        if let subtitle = item.placemark.title {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if isSearching {
                    ProgressView()
                } else if results.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "駅名・地名を入力" : "見つかりませんでした",
                                           systemImage: "magnifyingglass",
                                           description: Text("例：渋谷駅、鎌倉、梅田"))
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "駅名・地名")
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await search()
            }
            .navigationTitle("エリアを指定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { results = []; return }
        isSearching = true
        defer { isSearching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        // 日本国内を優先
        request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 36.2, longitude: 138.25),
                                            span: MKCoordinateSpan(latitudeDelta: 16, longitudeDelta: 16))
        results = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
    }
}
