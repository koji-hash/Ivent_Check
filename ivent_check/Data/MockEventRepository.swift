import Foundation
import CoreLocation

/// どこで起動しても周辺にサンプルイベントを生成するモック。
/// 緯度経度 0.05° のセル × 日付 ごとにシード固定で生成するため、同じ場所・同じ日なら常に同じ結果になる。
final class MockEventRepository: EventRepository {
    static let sourceName = "サンプルデータ（モック）"
    static let sourceURL = URL(string: "https://example.com/mock-events")!

    private let cellSize = 0.05
    /// 複数日開催イベントを拾うため、検索開始日より何日前の開催開始まで遡るか
    private let maxEventDays = 3
    private let latency: Duration
    private let calendar: Calendar
    private let now: () -> Date
    private(set) var reports: [EventIssueReport] = []

    init(latency: Duration = .milliseconds(300), calendar: Calendar = .current, now: @escaping () -> Date = { .now }) {
        self.latency = latency
        self.calendar = calendar
        self.now = now
    }

    var dataSources: [DataSourceInfo] {
        [DataSourceInfo(name: Self.sourceName, url: Self.sourceURL, license: "CC BY 4.0（サンプル）",
                        note: "開発用に自動生成した架空のイベントです。実在のイベントではありません。")]
    }

    func searchEvents(_ query: EventSearchQuery) async throws -> [Event] {
        if latency > .zero { try await Task.sleep(for: latency) }
        let current = now()
        // 検索円を囲むセル範囲
        let latDelta = query.radiusKm / 111.0
        let lonDelta = query.radiusKm / (111.0 * max(cos(query.latitude * .pi / 180), 0.1))
        let latRange = cellIndex(query.latitude - latDelta)...cellIndex(query.latitude + latDelta)
        let lonRange = cellIndex(query.longitude - lonDelta)...cellIndex(query.longitude + lonDelta)

        let firstDay = calendar.date(byAdding: .day, value: -maxEventDays, to: calendar.startOfDay(for: query.from))!
        var results: [Event] = []
        var day = firstDay
        while day < query.to {
            for latIndex in latRange {
                for lonIndex in lonRange {
                    results += generateEvents(latIndex: latIndex, lonIndex: lonIndex, day: day, now: current)
                        .filter { query.matches($0, now: current) }
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return results
    }

    func reportIssue(_ report: EventIssueReport) async throws {
        if latency > .zero { try await Task.sleep(for: latency) }
        reports.append(report)
    }

    // MARK: - 生成

    private func cellIndex(_ degree: Double) -> Int {
        Int((degree / cellSize).rounded(.down))
    }

    private func dayNumber(_ day: Date) -> Int {
        let reference = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        return calendar.dateComponents([.day], from: reference, to: day).day ?? 0
    }

    private func generateEvents(latIndex: Int, lonIndex: Int, day: Date, now: Date) -> [Event] {
        let dayNo = dayNumber(day)
        var rng = SeededGenerator(seed: UInt64(bitPattern: Int64(latIndex)) &* 0x9E37_79B9_7F4A_7C15
                                  ^ UInt64(bitPattern: Int64(lonIndex)) &* 0xC2B2_AE3D_27D4_EB4F
                                  ^ UInt64(bitPattern: Int64(dayNo)) &* 0x1656_67B1_9E37_79F9)
        let count = Int.random(in: 0...3, using: &rng)
        return (0..<count).map { _ in
            makeEvent(latIndex: latIndex, lonIndex: lonIndex, day: day, now: now, rng: &rng)
        }
    }

    private func makeEvent(latIndex: Int, lonIndex: Int, day: Date, now: Date, rng: inout SeededGenerator) -> Event {
        let category = EventCategory.allCases.randomElement(using: &rng)!
        let template = Self.templates[category]!
        let area = Self.areaNames.randomElement(using: &rng)!
        let title = template.titles.randomElement(using: &rng)!.replacingOccurrences(of: "{area}", with: area)
        let venue = template.venues.randomElement(using: &rng)!.replacingOccurrences(of: "{area}", with: area)

        var categories = [category]
        if category == .festival, Bool.random(using: &rng) { categories.append(.food) }
        if category == .market, Bool.random(using: &rng) { categories.append(.food) }

        let latitude = (Double(latIndex) + Double.random(in: 0..<1, using: &rng)) * cellSize
        let longitude = (Double(lonIndex) + Double.random(in: 0..<1, using: &rng)) * cellSize

        let durationDays = Int.random(in: 1...template.maxDays, using: &rng)
        let startAt: Date
        let endAt: Date
        let isAllDay = template.allDay
        if isAllDay {
            startAt = day
            endAt = calendar.date(byAdding: .day, value: durationDays, to: day)!
        } else {
            let hour = template.startHours.randomElement(using: &rng)!
            startAt = calendar.date(byAdding: .minute, value: hour * 60 + [0, 30].randomElement(using: &rng)!, to: day)!
            let base = calendar.date(byAdding: .day, value: durationDays - 1, to: startAt)!
            endAt = base.addingTimeInterval(TimeInterval(template.durationHours.randomElement(using: &rng)! * 3600))
        }

        let isFree: Bool? = template.alwaysFree ? true
            : (Double.random(in: 0..<1, using: &rng) < 0.1 ? nil : Double.random(in: 0..<1, using: &rng) < 0.55)
        let price: String? = switch isFree {
        case true?: "無料"
        case false?: ["500円", "1,000円", "大人800円・子ども無料", "2,000円", "前売1,500円"].randomElement(using: &rng)!
        case nil: nil
        }

        let id = UUID(rng: &rng)
        let confidence = Double.random(in: 0.55...1.0, using: &rng)
        let fetchedAt = now.addingTimeInterval(-Double.random(in: 600...21_600, using: &rng))
        let summary = template.summary.replacingOccurrences(of: "{area}", with: area)
            + "\n\n※このイベントは開発用のサンプルデータです。"

        return Event(
            id: id,
            title: title,
            summary: summary,
            categories: categories,
            startAt: startAt,
            endAt: endAt,
            isAllDay: isAllDay,
            recurrence: durationDays > 1 ? "\(durationDays)日間開催" : nil,
            venueName: venue,
            address: "\(area)\(Int.random(in: 1...5, using: &rng))丁目\(Int.random(in: 1...20, using: &rng))-\(Int.random(in: 1...15, using: &rng))（サンプル住所）",
            latitude: latitude,
            longitude: longitude,
            price: price,
            isFree: isFree,
            organizer: ["\(area)実行委員会", "\(area)商店会", "\(area)町内会", "NPO法人まちづくり\(area)"].randomElement(using: &rng)!,
            officialUrl: URL(string: "https://example.com/events/\(id.uuidString.lowercased())"),
            imageUrl: nil,
            iconKey: nil,
            sourceName: Self.sourceName,
            sourceUrl: Self.sourceURL,
            license: "CC BY 4.0",
            confidence: confidence,
            fetchedAt: fetchedAt,
            updatedAt: fetchedAt
        )
    }

    private struct Template {
        let titles: [String]
        let venues: [String]
        let summary: String
        var allDay = false
        var startHours: [Int] = [10]
        var durationHours: [Int] = [3]
        var maxDays = 1
        var alwaysFree = false
    }

    private static let areaNames = ["本町", "緑ヶ丘", "桜台", "川辺", "中央", "東町", "西町", "港町", "旭", "若葉", "富士見", "宮前"]

    private static let templates: [EventCategory: Template] = [
        .festival: Template(titles: ["{area}まつり", "{area}神社 例大祭", "{area}ふるさと祭り", "{area}よさこい祭り"],
                            venues: ["{area}神社", "{area}公園", "{area}駅前通り"],
                            summary: "{area}地区で毎年恒例のお祭りです。神輿や山車の巡行、屋台が並びます。",
                            startHours: [10, 11, 16], durationHours: [5, 8], maxDays: 2, alwaysFree: true),
        .fireworks: Template(titles: ["{area}花火大会", "{area}納涼花火", "{area}冬花火"],
                             venues: ["{area}河川敷", "{area}海浜公園"],
                             summary: "約3,000発の花火が打ち上げられます。雨天時は翌日に順延予定です。",
                             startHours: [19], durationHours: [1, 2], alwaysFree: true),
        .market: Template(titles: ["{area}朝市", "{area}マルシェ", "{area}ファーマーズマーケット", "{area}手づくり市"],
                          venues: ["{area}広場", "駅前広場", "{area}公園"],
                          summary: "地元農家の新鮮な野菜や手づくり雑貨が並ぶマーケットです。",
                          startHours: [7, 8, 10], durationHours: [3, 4, 6], alwaysFree: true),
        .music: Template(titles: ["{area}ジャズフェスティバル", "{area}ストリートライブ", "{area}市民オーケストラ演奏会"],
                         venues: ["{area}ホール", "市民会館", "{area}駅前広場"],
                         summary: "地元ミュージシャンによるライブ演奏をお楽しみください。",
                         startHours: [13, 14, 18], durationHours: [2, 3]),
        .art: Template(titles: ["{area}アートフェア", "{area}写真展", "{area}こども絵画展", "{area}ライトアップ展"],
                       venues: ["{area}美術館", "{area}ギャラリー", "{area}文化センター"],
                       summary: "地域ゆかりの作家による作品展示です。",
                       allDay: true, maxDays: 3),
        .sports: Template(titles: ["{area}市民マラソン", "{area}ウォーキング大会", "{area}ボッチャ体験会"],
                          venues: ["{area}運動公園", "総合体育館", "{area}グラウンド"],
                          summary: "どなたでも参加・観戦できるスポーツイベントです。",
                          startHours: [8, 9], durationHours: [3, 5]),
        .kids: Template(titles: ["{area}こどもまつり", "{area}おはなし会", "{area}親子工作教室", "{area}わんぱく広場"],
                        venues: ["{area}児童館", "{area}図書館", "{area}公園"],
                        summary: "未就学児から小学生まで楽しめる子ども向けイベントです。",
                        startHours: [10, 13], durationHours: [1, 2, 3]),
        .food: Template(titles: ["{area}グルメフェス", "{area}ラーメン祭", "{area}クラフトビールフェス", "{area}食べ歩きラリー"],
                        venues: ["{area}商店街", "駅前広場", "{area}公園"],
                        summary: "地元の人気店が集まるグルメイベントです。",
                        startHours: [11], durationHours: [5, 6], maxDays: 2),
        .community: Template(titles: ["{area}防災フェア", "{area}地区運動会", "{area}清掃活動", "{area}文化祭"],
                             venues: ["{area}公民館", "{area}地区センター", "{area}小学校"],
                             summary: "{area}地区の住民どなたでも参加できる地域行事です。",
                             startHours: [9, 10], durationHours: [3, 6], alwaysFree: true),
        .other: Template(titles: ["{area}フリーマーケット", "{area}星空観察会", "{area}古本市"],
                         venues: ["{area}コミュニティプラザ", "{area}公園", "{area}駅前広場"],
                         summary: "どなたでも気軽に立ち寄れるイベントです。",
                         startHours: [10, 18], durationHours: [2, 4]),
    ]
}

/// SplitMix64。シード固定で再現可能な乱数
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private extension UUID {
    init(rng: inout SeededGenerator) {
        let a = rng.next(), b = rng.next()
        func byte(_ v: UInt64, _ i: Int) -> UInt8 { UInt8(truncatingIfNeeded: v >> (i * 8)) }
        self.init(uuid: (byte(a, 0), byte(a, 1), byte(a, 2), byte(a, 3), byte(a, 4), byte(a, 5),
                         byte(a, 6) & 0x0F | 0x40, byte(a, 7),
                         byte(b, 0) & 0x3F | 0x80, byte(b, 1), byte(b, 2), byte(b, 3),
                         byte(b, 4), byte(b, 5), byte(b, 6), byte(b, 7)))
    }
}
