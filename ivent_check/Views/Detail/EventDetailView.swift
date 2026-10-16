import SwiftUI
import SwiftData
import MapKit

/// S-05 イベント詳細
struct EventDetailView: View {
    let event: Event

    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Query private var favorites: [FavoriteEvent]
    @State private var showCalendar = false
    @State private var showReport = false

    init(event: Event) {
        self.event = event
        let id = event.id
        _favorites = Query(filter: #Predicate<FavoriteEvent> { $0.eventID == id })
    }

    private var isFavorite: Bool { !favorites.isEmpty }

    private var distance: CLLocationDistance? {
        model.origin.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: event.location) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                titleSection
                actions
                infoSection
                if let summary = event.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("概要").font(.headline)
                        Text(summary)
                    }
                }
                mapPreview
                if let url = event.officialUrl {
                    Link(destination: url) {
                        Label("公式サイトを見る", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                sourceSection
                Button {
                    showReport = true
                } label: {
                    Label("情報が間違っている場合は報告", systemImage: "exclamationmark.bubble")
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
        }
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorite ? .pink : .accentColor)
                }
                .accessibilityLabel(isFavorite ? "お気に入りから外す" : "お気に入りに追加")
            }
        }
        .sheet(isPresented: $showCalendar) {
            CalendarEventEditor(event: event).ignoresSafeArea()
        }
        .sheet(isPresented: $showReport) {
            ReportIssueView(event: event)
        }
    }

    // MARK: - セクション

    @ViewBuilder
    private var header: some View {
        let icon = event.icon
        ZStack {
            icon.gradient.opacity(0.9)
            VStack(spacing: 8) {
                Image(systemName: icon.symbol)
                    .font(.system(size: 60, weight: .semibold))
                Text(icon.label)
                    .font(.subheadline.bold())
            }
            .foregroundStyle(.white.opacity(0.95))
            // 権利確認済みの画像のみ imageUrl に入る（5.3）
            if let url = event.imageUrl {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
        }
        .frame(height: 170)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityHidden(true)
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusBadge(status: .of(event))
                ForEach(event.categories, id: \.self) { category in
                    Text(category.label)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .foregroundStyle(category.color)
                        .background(category.color.opacity(0.15), in: Capsule())
                }
            }
            Text(event.title)
                .font(.title2.bold())
            if event.needsVerification {
                Label("会場の位置や日時を掲載元の記載から推定しているため、正確でない可能性があります（要確認）", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Menu {
                Button("徒歩") { openDirections(MKLaunchOptionsDirectionsModeWalking) }
                Button("公共交通機関") { openDirections(MKLaunchOptionsDirectionsModeTransit) }
                Button("車") { openDirections(MKLaunchOptionsDirectionsModeDriving) }
            } label: {
                ActionLabel(title: "経路", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
            }
            Button { showCalendar = true } label: {
                ActionLabel(title: "カレンダー", systemImage: "calendar.badge.plus")
            }
            ShareLink(item: event.officialUrl ?? event.sourceUrl,
                      subject: Text(event.title),
                      message: Text("\(event.title)\n\(EventFormatters.schedule(for: event))\n\(event.venueName)")) {
                ActionLabel(title: "共有", systemImage: "square.and.arrow.up")
            }
            Button(action: toggleFavorite) {
                ActionLabel(title: isFavorite ? "登録済み" : "お気に入り", systemImage: isFavorite ? "heart.fill" : "heart")
            }
        }
        .buttonStyle(.plain)
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            InfoRow(systemImage: "calendar", title: "日時",
                    value: [EventFormatters.schedule(for: event), event.recurrence].compactMap { $0 }.joined(separator: "\n"))
            InfoRow(systemImage: "mappin.and.ellipse", title: "会場",
                    value: [event.venueName, event.address].compactMap { $0 }.joined(separator: "\n"))
            if let distance {
                InfoRow(systemImage: "figure.walk", title: "距離", value: "\(model.originName)から\(EventFormatters.distance(distance))")
            }
            InfoRow(systemImage: "yensign.circle", title: "料金", value: event.price ?? "情報なし")
            if let organizer = event.organizer {
                InfoRow(systemImage: "person.2", title: "主催", value: organizer)
            }
        }
    }

    private var mapPreview: some View {
        Map(initialPosition: .region(MKCoordinateRegion(center: event.coordinate, latitudinalMeters: 800, longitudinalMeters: 800)),
            interactionModes: []) {
            Marker(event.venueName, systemImage: event.icon.symbol, coordinate: event.coordinate)
                .tint(event.icon.color)
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { openDirections(nil) }
        .accessibilityLabel("会場の地図。タップでマップを開く")
    }

    /// F-DTL-02 出典と最終取得日時 / 8. 信頼性
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("情報の出典").font(.subheadline.bold())
            Link(event.sourceName, destination: event.sourceUrl)
                .font(.subheadline)
            Text("ライセンス：\(event.license)")
            Text("最終取得：\(EventFormatters.dateTime.string(from: event.fetchedAt))")
            Text("最終更新：\(EventFormatters.dateTime.string(from: event.updatedAt))")
            Text("掲載情報の正確性は保証されません。中止・変更の可能性があるため、お出かけ前に公式サイト等で最新情報をご確認ください。")
                .padding(.top, 4)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - アクション

    private func toggleFavorite() {
        Favorites.toggle(event, in: context)
        Task {
            // 初めてのお気に入り登録時に、リマインド通知の許可を求める
            if await model.scheduler.authorizationStatus() == .notDetermined {
                await model.scheduler.requestAuthorization()
            }
            model.scheduleNotificationRefresh()
        }
    }

    private func openDirections(_ mode: String?) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: event.coordinate))
        item.name = event.venueName
        var options: [String: Any] = [:]
        if let mode { options[MKLaunchOptionsDirectionsModeKey] = mode }
        item.openInMaps(launchOptions: options)
    }
}

private struct ActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title3)
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}

private struct InfoRow: View {
    let systemImage: String
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
