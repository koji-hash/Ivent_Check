import Foundation
import CoreLocation
import Observation

/// F-LOC-02 手動エリア
struct ManualArea: Codable, Equatable {
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// F-NTF-05 通知頻度
enum NotificationFrequency: String, CaseIterable, Identifiable {
    case daily, weekendsOnly, weekdaysOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .daily: "毎日"
        case .weekendsOnly: "土日のみ"
        case .weekdaysOnly: "平日のみ"
        }
    }

    func includes(_ date: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .daily: true
        case .weekendsOnly: calendar.isDateInWeekend(date)
        case .weekdaysOnly: !calendar.isDateInWeekend(date)
        }
    }
}

/// UserDefaults に保存されるユーザー設定（S-07）
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

    // MARK: 検索エリア
    var useManualArea: Bool { didSet { defaults.set(useManualArea, forKey: "useManualArea") } }
    var manualArea: ManualArea? {
        didSet { defaults.set(manualArea.flatMap { try? JSONEncoder().encode($0) }, forKey: "manualArea") }
    }
    /// 通知の抽出に使う直近の位置（約1km単位に丸めた1点のみ。履歴は保存しない）
    var lastCoarseLocation: CLLocationCoordinate2D? {
        get {
            guard defaults.object(forKey: "lastLat") != nil else { return nil }
            return CLLocationCoordinate2D(latitude: defaults.double(forKey: "lastLat"), longitude: defaults.double(forKey: "lastLon"))
        }
        set {
            defaults.set(newValue?.latitude, forKey: "lastLat")
            defaults.set(newValue?.longitude, forKey: "lastLon")
        }
    }

    // MARK: 通知（F-NTF-01, 02, 05）
    var morningNotificationEnabled: Bool { didSet { defaults.set(morningNotificationEnabled, forKey: "morningEnabled") } }
    var morningHour: Int { didSet { defaults.set(morningHour, forKey: "morningHour") } }
    var morningMinute: Int { didSet { defaults.set(morningMinute, forKey: "morningMinute") } }
    var notificationFrequency: NotificationFrequency { didSet { defaults.set(notificationFrequency.rawValue, forKey: "frequency") } }
    var notificationRadiusKm: Double { didSet { defaults.set(notificationRadiusKm, forKey: "notifyRadius") } }
    /// 空の場合はすべて
    var notificationCategories: Set<EventCategory> {
        didSet { defaults.set(notificationCategories.map(\.rawValue), forKey: "notifyCategories") }
    }
    var quietHoursEnabled: Bool { didSet { defaults.set(quietHoursEnabled, forKey: "quietEnabled") } }
    var quietStartHour: Int { didSet { defaults.set(quietStartHour, forKey: "quietStart") } }
    var quietEndHour: Int { didSet { defaults.set(quietEndHour, forKey: "quietEnd") } }
    var favoriteRemindersEnabled: Bool { didSet { defaults.set(favoriteRemindersEnabled, forKey: "favoriteReminders") } }
    /// F-LOC-03 移動先でも検知（Significant Location Change）
    var followLocationChanges: Bool { didSet { defaults.set(followLocationChanges, forKey: "followLocation") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "morningEnabled": true,
            "morningHour": 8,
            "morningMinute": 0,
            "notifyRadius": 5.0,
            "quietEnabled": true,
            "quietStart": 22,
            "quietEnd": 7,
            "favoriteReminders": true,
        ])
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        useManualArea = defaults.bool(forKey: "useManualArea")
        manualArea = defaults.data(forKey: "manualArea").flatMap { try? JSONDecoder().decode(ManualArea.self, from: $0) }
        morningNotificationEnabled = defaults.bool(forKey: "morningEnabled")
        morningHour = defaults.integer(forKey: "morningHour")
        morningMinute = defaults.integer(forKey: "morningMinute")
        notificationFrequency = NotificationFrequency(rawValue: defaults.string(forKey: "frequency") ?? "") ?? .daily
        notificationRadiusKm = defaults.double(forKey: "notifyRadius")
        notificationCategories = Set((defaults.stringArray(forKey: "notifyCategories") ?? []).compactMap(EventCategory.init(rawValue:)))
        quietHoursEnabled = defaults.bool(forKey: "quietEnabled")
        quietStartHour = defaults.integer(forKey: "quietStart")
        quietEndHour = defaults.integer(forKey: "quietEnd")
        favoriteRemindersEnabled = defaults.bool(forKey: "favoriteReminders")
        followLocationChanges = defaults.bool(forKey: "followLocation")
    }

    /// DatePicker 用
    var morningTime: Date {
        get { Calendar.current.date(from: DateComponents(hour: morningHour, minute: morningMinute)) ?? .now }
        set {
            let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            morningHour = c.hour ?? 8
            morningMinute = c.minute ?? 0
        }
    }

    /// 静音時間帯に含まれるか（例: 22時〜7時）
    func isQuiet(hour: Int) -> Bool {
        guard quietHoursEnabled, quietStartHour != quietEndHour else { return false }
        if quietStartHour < quietEndHour {
            return (quietStartHour..<quietEndHour).contains(hour)
        }
        return hour >= quietStartHour || hour < quietEndHour
    }
}
