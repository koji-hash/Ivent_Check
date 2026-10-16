import SwiftUI

/// F-EVT-06 ステータスバッジ
enum EventStatus: Equatable {
    case ongoing
    case startingSoon
    case today
    case tomorrow
    case weekend
    case upcoming(Date)
    case ended

    static func of(_ event: Event, now: Date = .now, calendar: Calendar = .current) -> EventStatus {
        if event.endAt <= now { return .ended }
        if event.startAt <= now { return .ongoing }
        if event.startAt.timeIntervalSince(now) <= 60 * 60 { return .startingSoon }
        if calendar.isDate(event.startAt, inSameDayAs: now) { return .today }
        let startOfToday = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        if calendar.isDate(event.startAt, inSameDayAs: tomorrow) { return .tomorrow }
        if DatePeriod.weekend.interval(now: now, calendar: calendar).contains(event.startAt) { return .weekend }
        return .upcoming(event.startAt)
    }

    var label: String {
        switch self {
        case .ongoing: "開催中"
        case .startingSoon: "まもなく開始"
        case .today: "今日"
        case .tomorrow: "明日"
        case .weekend: "今週末"
        case .upcoming(let date): EventFormatters.shortDay.string(from: date)
        case .ended: "終了"
        }
    }

    var color: Color {
        switch self {
        case .ongoing: .red
        case .startingSoon: .orange
        case .today: .accentColor
        case .tomorrow: .blue
        case .weekend: .indigo
        case .upcoming: .gray
        case .ended: .secondary
        }
    }
}
