import Foundation
import CoreLocation

/// 6.3 検索API `GET /events?lat=&lng=&radius_km=&from=&to=&category=` に対応する検索条件
struct EventSearchQuery: Hashable {
    let latitude: Double
    let longitude: Double
    let radiusKm: Double
    let from: Date
    let to: Date
    let categories: Set<EventCategory>
    let freeOnly: Bool

    /// 8. プライバシー：サーバーへ送る座標は約1km単位に丸める
    init(center: CLLocationCoordinate2D, radiusKm: Double, interval: DateInterval,
         categories: Set<EventCategory> = [], freeOnly: Bool = false) {
        let rounded = Self.coarse(center)
        self.latitude = rounded.latitude
        self.longitude = rounded.longitude
        self.radiusKm = radiusKm
        self.from = interval.start
        self.to = interval.end
        self.categories = categories
        self.freeOnly = freeOnly
    }

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var interval: DateInterval { DateInterval(start: from, end: to) }

    /// 終了済みを除き、期間・半径・カテゴリ・無料の条件に合うか
    func matches(_ event: Event, now: Date) -> Bool {
        event.endAt > now
            && event.overlaps(interval)
            && CLLocation(latitude: latitude, longitude: longitude).distance(from: event.location) <= radiusKm * 1000
            && (categories.isEmpty || !categories.isDisjoint(with: event.categories))
            && (!freeOnly || event.isFree == true)
    }

    /// 小数第2位（緯度方向で約1.1km）に丸める
    static func coarse(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (coordinate.latitude * 100).rounded() / 100,
                               longitude: (coordinate.longitude * 100).rounded() / 100)
    }
}

/// F-DTL-06 「情報が間違っている」報告
struct EventIssueReport: Codable {
    enum Reason: String, Codable, CaseIterable, Identifiable {
        case wrongDate, wrongPlace, cancelled, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .wrongDate: "日時が違う"
            case .wrongPlace: "場所が違う"
            case .cancelled: "中止・延期になった"
            case .other: "その他"
            }
        }
    }

    let eventID: UUID
    let reason: Reason
    let comment: String
    let reportedAt: Date
}

/// 設定画面の「データ出典一覧」に表示する情報
struct DataSourceInfo: Identifiable {
    let name: String
    let url: URL
    let license: String
    let note: String
    var id: String { name }
}

/// バックエンド検索APIの抽象。現在はモック実装のみ。
/// バックエンド完成後はこのプロトコルに準拠した API クライアントに差し替える。
protocol EventRepository {
    /// 終了済みイベントは含めない（D-06）
    func searchEvents(_ query: EventSearchQuery) async throws -> [Event]
    func reportIssue(_ report: EventIssueReport) async throws
    var dataSources: [DataSourceInfo] { get }
}
