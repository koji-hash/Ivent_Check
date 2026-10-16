import Foundation

/// F-EVT-02 期間フィルタ
enum DatePeriod: String, CaseIterable, Identifiable, Codable {
    case ongoing
    case today
    case tomorrow
    case weekend
    case week

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ongoing: "開催中"
        case .today: "今日"
        case .tomorrow: "明日"
        case .weekend: "今週末"
        case .week: "7日以内"
        }
    }

    /// 期間に対応する時間範囲。この範囲と開催期間が重なるイベントが対象
    func interval(now: Date = .now, calendar: Calendar = .current) -> DateInterval {
        let startOfToday = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: startOfToday)!
        }
        switch self {
        case .ongoing:
            return DateInterval(start: now, duration: 1)
        case .today:
            return DateInterval(start: now, end: day(1))
        case .tomorrow:
            return DateInterval(start: day(1), end: day(2))
        case .weekend:
            let saturday = Self.weekendStart(now: now, calendar: calendar)
            let end = calendar.date(byAdding: .day, value: 2, to: saturday)!
            return DateInterval(start: max(saturday, now), end: end)
        case .week:
            return DateInterval(start: now, end: day(7))
        }
    }

    /// 今週末（土曜0:00）。日曜日の場合は前日の土曜日
    static func weekendStart(now: Date, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: now) // 1 = 日曜, 7 = 土曜
        let offset = weekday == 1 ? -1 : 7 - weekday
        return calendar.date(byAdding: .day, value: offset, to: startOfToday)!
    }
}

/// F-EVT-05 並び順
enum EventSortOrder: String, CaseIterable, Identifiable {
    case recommended
    case distance

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recommended: "開催中→開始が近い順"
        case .distance: "距離順"
        }
    }
}

/// S-04 フィルタ条件
struct SearchFilter: Equatable {
    /// F-EVT-01 指定半径
    static let radiusOptions: [Double] = [1, 3, 5, 10, 20, 30, 50]

    var period: DatePeriod = .week
    var radiusKm: Double = 10
    /// 空の場合はすべてのカテゴリ
    var categories: Set<EventCategory> = []
    var freeOnly = false

    var isDefault: Bool { self == SearchFilter() }
}
