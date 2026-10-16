import Foundation
import SwiftData

/// F-ETC-01 お気に入り。オフラインでも閲覧できるようイベント全体をJSONで保持する
@Model
final class FavoriteEvent {
    @Attribute(.unique) var eventID: UUID
    var addedAt: Date
    var startAt: Date
    var endAt: Date
    var payload: Data

    init(event: Event, addedAt: Date = .now) {
        self.eventID = event.id
        self.addedAt = addedAt
        self.startAt = event.startAt
        self.endAt = event.endAt
        self.payload = (try? JSONEncoder().encode(event)) ?? Data()
    }

    var event: Event? {
        try? JSONDecoder().decode(Event.self, from: payload)
    }
}

enum Favorites {
    /// 終了から何日経ったお気に入りを自動整理するか（S-06）
    static let retentionDays = 30

    static func isFavorite(_ id: UUID, in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<FavoriteEvent>(predicate: #Predicate { $0.eventID == id })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    static func toggle(_ event: Event, in context: ModelContext) {
        let id = event.id
        let descriptor = FetchDescriptor<FavoriteEvent>(predicate: #Predicate { $0.eventID == id })
        if let existing = try? context.fetch(descriptor), !existing.isEmpty {
            existing.forEach(context.delete)
        } else {
            context.insert(FavoriteEvent(event: event))
        }
        try? context.save()
    }

    static func all(in context: ModelContext) -> [FavoriteEvent] {
        (try? context.fetch(FetchDescriptor<FavoriteEvent>(sortBy: [SortDescriptor(\.startAt)]))) ?? []
    }

    /// 終了後 retentionDays 日を過ぎたお気に入りを削除する
    static func purgeOld(in context: ModelContext, now: Date = .now) {
        let threshold = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        try? context.delete(model: FavoriteEvent.self, where: #Predicate { $0.endAt < threshold })
        try? context.save()
    }
}
