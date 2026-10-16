import Foundation
import CoreLocation
import Observation
import SwiftData
import BackgroundTasks

/// アプリ全体の依存関係と、位置・検索・通知の連携
@Observable
final class AppModel {
    static let shared = AppModel()
    static let refreshTaskID = (Bundle.main.bundleIdentifier ?? "ivent_check") + ".refresh"

    let settings: AppSettings
    let location: LocationService
    let store: EventStore
    let repository: EventRepository
    let scheduler: NotificationScheduler
    let modelContainer: ModelContainer

    @ObservationIgnored private var rescheduleTask: Task<Void, Never>?

    init(settings: AppSettings = AppSettings(),
         repository: EventRepository = FeedEventRepository(),
         modelContainer: ModelContainer = try! ModelContainer(for: FavoriteEvent.self)) {
        self.settings = settings
        self.repository = repository
        self.modelContainer = modelContainer
        self.location = LocationService()
        self.store = EventStore(repository: repository)
        self.scheduler = NotificationScheduler()

        location.onSignificantChange = { [weak self] newLocation in
            self?.handleLocationChange(newLocation)
        }
        if settings.followLocationChanges {
            location.startSignificantChanges()
        }
    }

    // MARK: - 検索の起点

    /// 検索・距離計算の起点。手動エリア指定時はそのエリア、それ以外は現在地
    var origin: CLLocationCoordinate2D? {
        if settings.useManualArea, let area = settings.manualArea { return area.coordinate }
        return location.currentLocation?.coordinate
    }

    var originName: String {
        if settings.useManualArea, let area = settings.manualArea { return area.name }
        return "現在地"
    }

    /// 起点が約100m以上変わったときだけ変化するキー（再検索のトリガー用）
    var originKey: String {
        guard let origin else { return "none" }
        return String(format: "%.3f,%.3f", origin.latitude, origin.longitude)
    }

    /// 位置情報も手動エリアも無く、検索できない状態
    var needsArea: Bool {
        origin == nil && (location.isDenied || settings.useManualArea)
    }

    func refresh(center: CLLocationCoordinate2D? = nil) async {
        guard let center = center ?? origin else { return }
        await store.search(center: center, origin: origin)
    }

    func setManualArea(_ area: ManualArea) {
        settings.manualArea = area
        settings.useManualArea = true
        scheduleNotificationRefresh()
    }

    // MARK: - ライフサイクル

    func didBecomeActive() {
        location.requestLocation()
        Favorites.purgeOld(in: modelContainer.mainContext)
        scheduleNotificationRefresh()
    }

    func didEnterBackground() {
        scheduleBackgroundRefresh()
    }

    private func handleLocationChange(_ newLocation: CLLocation) {
        settings.lastCoarseLocation = EventSearchQuery.coarse(newLocation.coordinate)
        scheduleNotificationRefresh()
    }

    /// 現在地を取得したら通知用に丸めた位置を記録する
    func recordCurrentLocation() {
        guard let coordinate = location.currentLocation?.coordinate else { return }
        settings.lastCoarseLocation = EventSearchQuery.coarse(coordinate)
    }

    func setFollowLocationChanges(_ enabled: Bool) {
        settings.followLocationChanges = enabled
        if enabled {
            if location.authorizationStatus != .authorizedAlways { location.requestAlways() }
            location.startSignificantChanges()
        } else {
            location.stopSignificantChanges()
        }
    }

    // MARK: - 通知

    func enableNotifications() async -> Bool {
        let granted = await scheduler.requestAuthorization()
        settings.morningNotificationEnabled = granted
        if granted { scheduleNotificationRefresh() }
        return granted
    }

    /// 設定変更が続いても最後の1回だけ実行する
    func scheduleNotificationRefresh() {
        rescheduleTask?.cancel()
        rescheduleTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await rescheduleNotifications()
        }
    }

    func rescheduleNotifications() async {
        let favorites = Favorites.all(in: modelContainer.mainContext).compactMap(\.event)
        let notifyOrigin = settings.useManualArea ? settings.manualArea?.coordinate : (origin ?? settings.lastCoarseLocation)
        await scheduler.rescheduleAll(settings: settings,
                                      origin: notifyOrigin.map(EventSearchQuery.coarse),
                                      favorites: favorites,
                                      repository: repository)
    }

    // MARK: - バックグラウンド更新（BGAppRefreshTask）

    func handleBackgroundRefresh() async {
        scheduleBackgroundRefresh()
        await rescheduleNotifications()
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        // 朝の通知の前（4時以降）に当日分を作り直せるようにする
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
        request.earliestBeginDate = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: tomorrow)
        try? BGTaskScheduler.shared.submit(request)
    }
}
