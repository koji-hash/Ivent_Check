import Foundation
import CoreLocation
import UserNotifications

/// 4.4 検知・通知（ローカル通知）
///
/// 要件書では F-NTF-01 はサーバー側抽出＋APNs が第一候補だが、バックエンドがまだ無いため
/// 端末側で今後7日分の朝の通知をまとめて予約し、起動時・バックグラウンド更新時・位置変更時に作り直す。
final class NotificationScheduler {
    static let morningPrefix = "morning-"
    static let favoritePrefix = "favorite-"
    /// iOS の保留通知上限は64件
    private let maxFavoriteEvents = 25

    private let center = UNUserNotificationCenter.current()
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func rescheduleAll(settings: AppSettings, origin: CLLocationCoordinate2D?, favorites: [Event],
                       repository: EventRepository, now: Date = .now) async {
        guard await authorizationStatus() == .authorized else { return }
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: pending.filter {
            $0.hasPrefix(Self.morningPrefix) || $0.hasPrefix(Self.favoritePrefix)
        })

        if settings.morningNotificationEnabled, let origin {
            await scheduleMorning(settings: settings, origin: origin, repository: repository, now: now)
        }
        if settings.favoriteRemindersEnabled {
            await scheduleFavoriteReminders(settings: settings, favorites: favorites, now: now)
        }
    }

    // MARK: - F-NTF-01 朝の通知

    private func scheduleMorning(settings: AppSettings, origin: CLLocationCoordinate2D,
                                 repository: EventRepository, now: Date) async {
        guard !settings.isQuiet(hour: settings.morningHour) else { return }
        let startOfToday = calendar.startOfDay(for: now)
        let originLocation = CLLocation(latitude: origin.latitude, longitude: origin.longitude)

        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  let fireDate = calendar.date(bySettingHour: settings.morningHour, minute: settings.morningMinute, second: 0, of: day),
                  fireDate > now,
                  settings.notificationFrequency.includes(day, calendar: calendar)
            else { continue }

            let endOfDay = calendar.date(byAdding: .day, value: 1, to: day)!
            let query = EventSearchQuery(center: origin, radiusKm: settings.notificationRadiusKm,
                                         interval: DateInterval(start: fireDate, end: endOfDay),
                                         categories: settings.notificationCategories)
            guard let events = try? await repository.searchEvents(query) else { continue }
            let hits = events
                .filter { $0.endAt > fireDate }
                .map { EventHit(event: $0, distance: originLocation.distance(from: $0.location)) }
            guard !hits.isEmpty else { continue }

            // 代表イベント：その時点で開催中 → 開始が早い順 → 近い順
            let representative = hits.min { a, b in
                let aOngoing = a.event.startAt <= fireDate, bOngoing = b.event.startAt <= fireDate
                if aOngoing != bOngoing { return aOngoing }
                if a.event.startAt != b.event.startAt { return a.event.startAt < b.event.startAt }
                return a.distance < b.distance
            }!

            let content = UNMutableNotificationContent()
            content.title = offset == 0 ? "今日、近くで\(hits.count)件のイベント" : "\(EventFormatters.shortDay.string(from: day))、近くで\(hits.count)件のイベント"
            let time = representative.event.isAllDay ? "終日" : EventFormatters.time.string(from: representative.event.startAt) + "〜"
            content.body = "\(representative.event.title)（\(time)・\(EventFormatters.distance(representative.distance))）ほか"
            content.sound = .default
            content.userInfo = ["eventID": representative.event.id.uuidString]

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let id = Self.morningPrefix + String(Int(day.timeIntervalSince1970))
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    // MARK: - F-NTF-02 お気に入りのリマインド（前日19時・開始1時間前）

    private func scheduleFavoriteReminders(settings: AppSettings, favorites: [Event], now: Date) async {
        let upcoming = favorites.filter { $0.startAt > now }.sorted { $0.startAt < $1.startAt }.prefix(maxFavoriteEvents)
        for event in upcoming {
            let startDay = calendar.startOfDay(for: event.startAt)
            if let previousDay = calendar.date(byAdding: .day, value: -1, to: startDay),
               let dayBefore = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: previousDay),
               let fire = adjustForQuietHours(dayBefore, before: event.startAt, settings: settings), fire > now {
                await add(id: "\(Self.favoritePrefix)\(event.id.uuidString)-daybefore", at: fire,
                          title: "明日開催：\(event.title)",
                          body: "\(EventFormatters.schedule(for: event)) @\(event.venueName)", event: event)
            }
            if !event.isAllDay,
               let fire = adjustForQuietHours(event.startAt.addingTimeInterval(-3600), before: event.startAt, settings: settings),
               fire > now {
                await add(id: "\(Self.favoritePrefix)\(event.id.uuidString)-1h", at: fire,
                          title: "まもなく開始：\(event.title)",
                          body: "\(EventFormatters.time.string(from: event.startAt))から @\(event.venueName)", event: event)
            }
        }
    }

    /// 静音時間に入る場合は静音明けにずらす。開始時刻を過ぎてしまう場合は通知しない
    func adjustForQuietHours(_ date: Date, before deadline: Date, settings: AppSettings) -> Date? {
        let hour = calendar.component(.hour, from: date)
        guard settings.isQuiet(hour: hour) else { return date }
        var candidate = calendar.date(bySettingHour: settings.quietEndHour, minute: 0, second: 0, of: date)!
        if candidate <= date { candidate = calendar.date(byAdding: .day, value: 1, to: candidate)! }
        return candidate < deadline ? candidate : nil
    }

    private func add(id: String, at date: Date, title: String, body: String, event: Event) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["eventID": event.id.uuidString]
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
