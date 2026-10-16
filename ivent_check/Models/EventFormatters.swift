import Foundation
import CoreLocation

enum EventFormatters {
    static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d(E)"
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm"
        return f
    }()

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/M/d H:mm"
        return f
    }()

    /// 例: 「10/15(水) 10:00〜21:00」「10/15(水) 終日」「10/15(水)〜10/17(金)」
    static func schedule(for event: Event, calendar: Calendar = .current) -> String {
        // 終日イベントの endAt は最終日の翌日0:00
        let lastDay = event.isAllDay ? event.endAt.addingTimeInterval(-1) : event.endAt
        if !calendar.isDate(event.startAt, inSameDayAs: lastDay) {
            if event.isAllDay {
                return "\(shortDay.string(from: event.startAt))〜\(shortDay.string(from: lastDay))"
            }
            return "\(shortDay.string(from: event.startAt)) \(time.string(from: event.startAt))〜\(shortDay.string(from: lastDay)) \(time.string(from: lastDay))"
        }
        if event.isAllDay {
            return "\(shortDay.string(from: event.startAt)) 終日"
        }
        return "\(shortDay.string(from: event.startAt)) \(time.string(from: event.startAt))〜\(time.string(from: event.endAt))"
    }

    static func distance(_ meters: CLLocationDistance) -> String {
        if meters < 1000 {
            return "\(Int((meters / 10).rounded()) * 10)m"
        }
        return String(format: "%.1fkm", meters / 1000)
    }
}
