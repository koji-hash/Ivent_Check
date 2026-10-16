import SwiftUI
import MapKit

/// S-02 ホーム（地図）
struct MapHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var position: MapCameraPosition = .automatic
    @State private var region: MKCoordinateRegion?
    @State private var selectedID: UUID?
    @State private var showFilter = false
    @State private var showAreaSearch = false
    @State private var panelExpanded = false
    @State private var areaSearchTask: Task<Void, Never>?

    private var store: EventStore { model.store }

    var body: some View {
        NavigationStack {
            map
                .safeAreaInset(edge: .bottom) {
                    EventPanel(selectedID: $selectedID, expanded: $panelExpanded)
                }
                .overlay(alignment: .top) {
                    if model.needsArea {
                        noLocationBanner
                    }
                }
                .navigationTitle("周辺イベント")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showAreaSearch = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: model.settings.useManualArea ? "mappin.circle" : "location")
                                Text(model.originName).lineLimit(1)
                            }
                        }
                        .accessibilityLabel("検索エリア：\(model.originName)。タップでエリアを指定")
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
                .sheet(isPresented: $showAreaSearch) {
                    AreaSearchView { model.setManualArea($0) }
                }
                .onAppear(perform: recenter)
                .onChange(of: model.originKey) { recenter() }
                .onChange(of: store.filter.radiusKm) { recenter() }
        }
    }

    private var map: some View {
        Map(position: $position) {
            UserAnnotation()
            if model.settings.useManualArea, let area = model.settings.manualArea {
                Marker(area.name, systemImage: "mappin", coordinate: area.coordinate)
                    .tint(.gray)
            }
            if let center = store.lastSearchCenter {
                MapCircle(center: center, radius: store.filter.radiusKm * 1000)
                    .foregroundStyle(Color.accentColor.opacity(0.06))
                    .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
            }
            ForEach(ClusterEngine.clusters(for: store.visibleHits, in: region)) { cluster in
                Annotation(cluster.hits.count == 1 ? cluster.hits[0].event.title : "\(cluster.hits.count)件",
                           coordinate: cluster.coordinate, anchor: .center) {
                    if cluster.hits.count == 1 {
                        let hit = cluster.hits[0]
                        EventPin(hit: hit, isSelected: selectedID == hit.id)
                            .onTapGesture {
                                withAnimation { selectedID = hit.id; panelExpanded = false }
                            }
                    } else {
                        ClusterPin(count: cluster.hits.count)
                            .onTapGesture { zoom(into: cluster) }
                    }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            region = context.region
            scheduleAreaSearch(around: context.region.center)
        }
    }

    private var noLocationBanner: some View {
        VStack(spacing: 8) {
            Label("位置情報が利用できません", systemImage: "location.slash")
                .font(.headline)
            Text("駅名・地名でエリアを指定すると周辺のイベントを表示できます。")
                .font(.caption)
                .multilineTextAlignment(.center)
            Button("エリアを指定") { showAreaSearch = true }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }

    /// 起点（現在地／指定エリア）と検索半径に合わせてカメラを移動
    private func recenter() {
        guard let origin = model.origin else { return }
        let meters = store.filter.radiusKm * 1000 * 2.4
        withAnimation {
            position = .region(MKCoordinateRegion(center: origin, latitudinalMeters: meters, longitudinalMeters: meters))
        }
    }

    private func zoom(into cluster: MapCluster) {
        guard let region else { return }
        let span = MKCoordinateSpan(latitudeDelta: region.span.latitudeDelta / 3, longitudeDelta: region.span.longitudeDelta / 3)
        withAnimation {
            position = .region(MKCoordinateRegion(center: cluster.coordinate, span: span))
        }
    }

    /// 8. 性能：地図スクロール時の再検索はデバウンスする
    private func scheduleAreaSearch(around center: CLLocationCoordinate2D) {
        areaSearchTask?.cancel()
        guard let last = store.lastSearchCenter else { return }
        let moved = CLLocation(latitude: center.latitude, longitude: center.longitude)
            .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
        guard moved > store.filter.radiusKm * 1000 * 0.3 else { return }
        areaSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await model.refresh(center: center)
        }
    }
}

private struct EventPin: View {
    let hit: EventHit
    let isSelected: Bool

    var body: some View {
        EventIconView(icon: hit.event.icon, size: isSelected ? 40 : 30, circle: true)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if EventStatus.of(hit.event) == .ongoing {
                    Circle().fill(.red).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                }
            }
            .shadow(radius: 2, y: 1)
            .contentShape(Circle())
            .accessibilityElement()
            .accessibilityLabel("\(hit.event.title)、\(EventStatus.of(hit.event).label)、\(EventFormatters.distance(hit.distance))")
            .accessibilityAddTraits(.isButton)
    }
}

private struct ClusterPin: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(minWidth: 36, minHeight: 36)
            .padding(.horizontal, count >= 100 ? 4 : 0)
            .background(Capsule().fill(Color.accentColor.gradient))
            .overlay(Capsule().stroke(.white, lineWidth: 2))
            .shadow(radius: 2, y: 1)
            .contentShape(Capsule())
            .accessibilityElement()
            .accessibilityLabel("\(count)件のイベント。タップで拡大")
            .accessibilityAddTraits(.isButton)
    }
}

/// 地図下部の一覧パネル
private struct EventPanel: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedID: UUID?
    @Binding var expanded: Bool

    var body: some View {
        let store = model.store
        let hits = store.visibleHits
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("近くのイベント \(hits.count)件")
                            .font(.headline)
                        Text("\(store.filter.period.label)・\(Int(store.filter.radiusKm))km以内")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.isLoading { ProgressView() }
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "一覧を閉じる" : "一覧を広げる")

            if store.isShowingCache {
                Label("オフライン：前回の検索結果を表示しています", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if hits.isEmpty, !store.isLoading {
                Text("条件に合うイベントが見つかりませんでした。距離や期間を広げてみてください。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if expanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(hits) { hit in
                            NavigationLink(value: hit.event) {
                                EventRow(event: hit.event, distance: hit.distance)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(hits) { hit in
                                NavigationLink(value: hit.event) {
                                    EventCard(hit: hit, isSelected: hit.id == selectedID)
                                }
                                .buttonStyle(.plain)
                                .id(hit.id)
                            }
                        }
                    }
                    .onChange(of: selectedID) { _, id in
                        guard let id else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .frame(height: 104)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}
