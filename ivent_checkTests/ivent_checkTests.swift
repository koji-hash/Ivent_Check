//
//  ivent_checkTests.swift
//  ivent_checkTests
//
//  Created by 片山皓仁 on 2026/10/15.
//

import Foundation
import CoreLocation
import MapKit
import Testing
@testable import ivent_check

@MainActor
struct ivent_checkTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }()

    /// 2026/10/15(木) 12:00 JST
    private var thursdayNoon: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
    }

    private func makeEvent(start: Date, end: Date, lat: Double = 35.68, lon: Double = 139.76,
                           confidence: Double = 0.9) -> Event {
        Event(id: UUID(), title: "テスト", summary: nil, categories: [.festival], startAt: start, endAt: end,
              isAllDay: false, recurrence: nil, venueName: "会場", address: nil, latitude: lat, longitude: lon,
              price: nil, isFree: true, organizer: nil, officialUrl: nil, imageUrl: nil, iconKey: nil,
              sourceName: "test", sourceUrl: URL(string: "https://example.com")!, license: "CC BY",
              confidence: confidence, fetchedAt: .now, updatedAt: .now)
    }

    // MARK: 期間フィルタ

    @Test func weekendStartsOnSaturday() {
        let saturday = DatePeriod.weekendStart(now: thursdayNoon, calendar: calendar)
        #expect(calendar.component(.weekday, from: saturday) == 7)
        #expect(calendar.component(.day, from: saturday) == 17)
    }

    @Test func weekendOnSundayIncludesToday() {
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 10))!
        let interval = DatePeriod.weekend.interval(now: sunday, calendar: calendar)
        #expect(interval.start == sunday)
        #expect(calendar.component(.day, from: interval.end) == 19)
    }

    @Test func tomorrowInterval() {
        let interval = DatePeriod.tomorrow.interval(now: thursdayNoon, calendar: calendar)
        #expect(calendar.component(.day, from: interval.start) == 16)
        #expect(interval.duration == 86_400)
    }

    // MARK: ステータス

    @Test func statusBadges() {
        let now = thursdayNoon
        #expect(EventStatus.of(makeEvent(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(3600)), now: now, calendar: calendar) == .ongoing)
        #expect(EventStatus.of(makeEvent(start: now.addingTimeInterval(1800), end: now.addingTimeInterval(7200)), now: now, calendar: calendar) == .startingSoon)
        #expect(EventStatus.of(makeEvent(start: now.addingTimeInterval(3 * 3600), end: now.addingTimeInterval(4 * 3600)), now: now, calendar: calendar) == .today)
        #expect(EventStatus.of(makeEvent(start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(90_000)), now: now, calendar: calendar) == .tomorrow)
        #expect(EventStatus.of(makeEvent(start: now.addingTimeInterval(2 * 86_400), end: now.addingTimeInterval(2 * 86_400 + 3600)), now: now, calendar: calendar) == .weekend)
        #expect(EventStatus.of(makeEvent(start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-60)), now: now, calendar: calendar) == .ended)
    }

    // MARK: 並び順

    @Test func recommendedSortPutsOngoingFirst() {
        let now = Date.now
        let soon = EventHit(event: makeEvent(start: now.addingTimeInterval(600), end: now.addingTimeInterval(3600)), distance: 100)
        let ongoingFar = EventHit(event: makeEvent(start: now.addingTimeInterval(-600), end: now.addingTimeInterval(3600)), distance: 5000)
        let ongoingNear = EventHit(event: makeEvent(start: now.addingTimeInterval(-600), end: now.addingTimeInterval(3600)), distance: 500)
        let sorted = EventStore.sorted([soon, ongoingFar, ongoingNear], by: .recommended, now: now)
        #expect(sorted.map(\.id) == [ongoingNear.id, ongoingFar.id, soon.id])
        #expect(EventStore.sorted([soon, ongoingFar, ongoingNear], by: .distance).first?.id == soon.id)
    }

    // MARK: プライバシー（座標の丸め）

    @Test func queryRoundsCoordinatesToAbout1km() {
        let query = EventSearchQuery(center: CLLocationCoordinate2D(latitude: 35.681236, longitude: 139.767125),
                                     radiusKm: 5, interval: DateInterval(start: .now, duration: 3600))
        #expect(query.latitude == 35.68)
        #expect(query.longitude == 139.77)
    }

    // MARK: モックリポジトリ

    @Test func mockRepositoryIsDeterministicAndRespectsFilters() async throws {
        let now = thursdayNoon
        let repository = MockEventRepository(latency: .zero, calendar: calendar, now: { now })
        let center = CLLocationCoordinate2D(latitude: 35.68, longitude: 139.76)
        let interval = DatePeriod.week.interval(now: now, calendar: calendar)
        let query = EventSearchQuery(center: center, radiusKm: 5, interval: interval)

        let first = try await repository.searchEvents(query)
        let second = try await repository.searchEvents(query)
        #expect(!first.isEmpty)
        #expect(first.map(\.id) == second.map(\.id))

        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        for event in first {
            #expect(origin.distance(from: event.location) <= 5000)
            #expect(event.endAt > now)
            #expect(event.overlaps(interval))
        }

        let festivals = try await repository.searchEvents(
            EventSearchQuery(center: center, radiusKm: 5, interval: interval, categories: [.festival], freeOnly: true))
        #expect(festivals.allSatisfy { $0.categories.contains(.festival) && $0.isFree == true })
    }

    // MARK: クラスタリング

    @Test func clustersMergeNearbyPins() {
        let now = Date.now
        let near1 = EventHit(event: makeEvent(start: now, end: now.addingTimeInterval(3600), lat: 35.6801, lon: 139.7601), distance: 0)
        let near2 = EventHit(event: makeEvent(start: now, end: now.addingTimeInterval(3600), lat: 35.6802, lon: 139.7602), distance: 0)
        let far = EventHit(event: makeEvent(start: now, end: now.addingTimeInterval(3600), lat: 35.75, lon: 139.85), distance: 0)
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 35.7, longitude: 139.8),
                                        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2))
        let clusters = ClusterEngine.clusters(for: [near1, near2, far], in: region)
        #expect(clusters.count == 2)
        #expect(clusters.contains { $0.hits.count == 2 })
        #expect(ClusterEngine.clusters(for: [near1, near2, far], in: nil).count == 3)
    }

    // MARK: 実データ（同梱の events.json）

    @Test func bundledFeedDecodesAndFilters() async throws {
        let url = try #require(Bundle.main.url(forResource: "events", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let feed = try FeedEventRepository.decoder().decode(FeedEventRepository.Feed.self, from: data)
        #expect(!feed.events.isEmpty)
        #expect(!feed.sources.isEmpty)
        // 収集バッチが付けたアイコンはすべてアプリ側に用意されている
        #expect(feed.events.allSatisfy { $0.iconKey.flatMap(EventIcon.init(rawValue:)) != nil })

        let generated = feed.generatedAt
        let repository = FeedEventRepository(remoteURL: nil, bundledURL: url,
                                             cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json"),
                                             now: { generated })
        let takarazukaStation = CLLocationCoordinate2D(latitude: 34.8116, longitude: 135.3402)
        let hits = try await repository.searchEvents(
            EventSearchQuery(center: takarazukaStation, radiusKm: 5, interval: DatePeriod.week.interval(now: generated)))
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.endAt > generated })
    }

    @Test func iconFallsBackToCategory() {
        var event = makeEvent(start: .now, end: .now.addingTimeInterval(60))
        #expect(event.icon == .festival)
        event.iconKey = "lecture"
        #expect(event.icon == .lecture)
        event.iconKey = "unknown"
        #expect(event.icon == .festival)
    }

    // MARK: 静音時間

    @Test func quietHoursWrapAroundMidnight() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        settings.quietHoursEnabled = true
        settings.quietStartHour = 22
        settings.quietEndHour = 7
        #expect(settings.isQuiet(hour: 23))
        #expect(settings.isQuiet(hour: 3))
        #expect(!settings.isQuiet(hour: 8))
        #expect(!settings.isQuiet(hour: 19))
    }

    @Test func reminderInQuietHoursMovesToQuietEnd() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        let scheduler = NotificationScheduler(calendar: calendar)
        let fire = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 23))!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 10))!
        let adjusted = scheduler.adjustForQuietHours(fire, before: start, settings: settings)
        #expect(adjusted == calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 7)))

        let earlyStart = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 6))!
        #expect(scheduler.adjustForQuietHours(fire, before: earlyStart, settings: settings) == nil)
    }
}
