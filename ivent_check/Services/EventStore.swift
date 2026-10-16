import Foundation
import CoreLocation
import Observation

/// 検索条件と検索結果（地図・リストで共有）
@Observable
final class EventStore {
    var filter = SearchFilter()
    var sortOrder: EventSortOrder = .recommended
    /// F-EVT-08 キーワード検索（取得済みの結果を絞り込む）
    var keyword = ""

    private(set) var hits: [EventHit] = []
    private(set) var isLoading = false
    /// 通信できず前回の結果を表示している
    private(set) var isShowingCache = false
    private(set) var lastUpdated: Date?
    private(set) var lastSearchCenter: CLLocationCoordinate2D?
    private(set) var errorMessage: String?

    @ObservationIgnored private let repository: EventRepository
    @ObservationIgnored private let cache: SearchCache
    @ObservationIgnored private var generation = 0

    init(repository: EventRepository, cache: SearchCache = SearchCache()) {
        self.repository = repository
        self.cache = cache
    }

    /// center を中心に検索し、origin（現在地 or 指定エリア）からの距離を付ける
    func search(center: CLLocationCoordinate2D, origin: CLLocationCoordinate2D?, now: Date = .now) async {
        generation += 1
        let current = generation
        isLoading = true
        defer { if current == generation { isLoading = false } }

        let query = EventSearchQuery(center: center, radiusKm: filter.radiusKm, interval: filter.period.interval(now: now),
                                     categories: filter.categories, freeOnly: filter.freeOnly)
        let events: [Event]
        do {
            events = try await repository.searchEvents(query)
            guard current == generation else { return }
            cache.save(.init(events: events, latitude: query.latitude, longitude: query.longitude, savedAt: now))
            isShowingCache = false
            errorMessage = nil
            lastUpdated = now
        } catch is CancellationError {
            return
        } catch {
            guard current == generation else { return }
            errorMessage = "イベントを取得できませんでした"
            guard let snapshot = cache.load() else { hits = []; return }
            events = snapshot.events.filter { $0.endAt > now }
            isShowingCache = true
            lastUpdated = snapshot.savedAt
        }
        lastSearchCenter = center
        let originLocation = CLLocation(latitude: (origin ?? center).latitude, longitude: (origin ?? center).longitude)
        hits = events.map { EventHit(event: $0, distance: originLocation.distance(from: $0.location)) }
    }

    /// キーワードと並び順を適用した結果
    var visibleHits: [EventHit] {
        let keyword = keyword.trimmingCharacters(in: .whitespaces)
        let filtered = keyword.isEmpty ? hits : hits.filter { hit in
            let e = hit.event
            return [e.title, e.summary, e.venueName, e.organizer, e.address, e.area, e.icon.label]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(keyword) }
        }
        return Self.sorted(filtered, by: sortOrder)
    }

    static func sorted(_ hits: [EventHit], by order: EventSortOrder, now: Date = .now) -> [EventHit] {
        switch order {
        case .distance:
            return hits.sorted { $0.distance < $1.distance }
        case .recommended:
            return hits.sorted { a, b in
                let aOngoing = a.event.startAt <= now, bOngoing = b.event.startAt <= now
                if aOngoing != bOngoing { return aOngoing }
                if aOngoing { return a.distance < b.distance }
                if a.event.startAt != b.event.startAt { return a.event.startAt < b.event.startAt }
                return a.distance < b.distance
            }
        }
    }

    /// S-03 リストのセクション分け
    var sections: [(title: String, hits: [EventHit])] {
        Self.sections(for: visibleHits)
    }

    static func sections(for hits: [EventHit], now: Date = .now, calendar: Calendar = .current) -> [(title: String, hits: [EventHit])] {
        let order = ["開催中", "今日", "明日", "今週末", "それ以降"]
        var grouped: [String: [EventHit]] = [:]
        for hit in hits {
            let key = switch EventStatus.of(hit.event, now: now, calendar: calendar) {
            case .ongoing: "開催中"
            case .startingSoon, .today: "今日"
            case .tomorrow: "明日"
            case .weekend: "今週末"
            case .upcoming, .ended: "それ以降"
            }
            grouped[key, default: []].append(hit)
        }
        return order.compactMap { key in grouped[key].map { (key, $0) } }
    }
}
