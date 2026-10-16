import Foundation
import CoreLocation

/// 5.3 イベントデータモデル（共通スキーマ）
nonisolated struct Event: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var summary: String?
    var categories: [EventCategory]
    var startAt: Date
    var endAt: Date
    var isAllDay: Bool
    var recurrence: String?
    var venueName: String
    var address: String?
    var latitude: Double
    var longitude: Double
    var price: String?
    var isFree: Bool?
    var organizer: String?
    var officialUrl: URL?
    var imageUrl: URL?
    /// 収集バッチが選んだアイコン（EventIcon の rawValue）
    var iconKey: String?
    var sourceName: String
    var sourceUrl: URL
    var license: String
    var confidence: Double
    var fetchedAt: Date
    var updatedAt: Date
    /// 開催市町村（例: 川西市）
    var area: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, title
        case summary = "description"
        case categories = "category"
        case startAt, endAt, isAllDay, recurrence, venueName, address, latitude, longitude
        case iconKey = "icon"
        case price, isFree, organizer, officialUrl, imageUrl, sourceName, sourceUrl, license
        case confidence, fetchedAt, updatedAt, area
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    var primaryCategory: EventCategory { categories.first ?? .other }

    /// 表示するアイコン。データに無ければカテゴリから決める
    var icon: EventIcon { iconKey.flatMap(EventIcon.init(rawValue:)) ?? EventIcon(category: primaryCategory) }

    /// 会場名に市町村名が含まれていなければ表示用に返す
    var displayArea: String? {
        guard let area, !venueName.contains(area) else { return nil }
        return area
    }

    /// 9. LLM抽出の誤り対策：信頼度が低いものは「要確認」表示
    var needsVerification: Bool { confidence < 0.7 }

    func overlaps(_ interval: DateInterval) -> Bool {
        startAt < interval.end && endAt > interval.start
    }
}

/// 検索結果（イベント＋距離）。6.3 の応答形式に対応
nonisolated struct EventHit: Identifiable, Hashable {
    let event: Event
    /// 現在地（または指定エリア）からの距離（m）
    let distance: CLLocationDistance

    var id: UUID { event.id }
}
