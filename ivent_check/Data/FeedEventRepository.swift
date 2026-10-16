import Foundation
import CoreLocation

/// 収集バッチが毎朝作るイベントデータを読むリポジトリ。
///
/// `EventFeedURL`（Info.plist）の指定で2通りの配信に対応する:
/// - 地域ごとのファイル（全国向け）: `https://…/feed/` → `index.json` を読み、検索範囲に重なる `tiles/*.json` だけを取得する。
///   内容のハッシュが変わっていないファイルは端末に保存したものを使う
/// - 1ファイル: `https://…/events.json`
/// 未設定・通信できないときは、前回保存したもの → アプリ同梱の events.json の順に使う。
/// 半径・期間・カテゴリの絞り込みは端末側で行う（座標はどこにも送らない）。
final class FeedEventRepository: EventRepository {
    struct Feed: Codable {
        struct Source: Codable {
            let name: String
            let url: URL
            let license: String
            let note: String
        }

        let version: Int
        let generatedAt: Date
        let sources: [Source]
        let events: [Event]
    }

    /// 地域ごとのファイルの一覧
    struct FeedIndex: Codable {
        struct Tile: Codable {
            let count: Int
            let hash: String
        }

        let version: Int
        let generatedAt: Date
        let tileSize: Double
        let sources: [Feed.Source]
        let tiles: [String: Tile]
    }

    private let remoteURL: URL?
    private let cacheURL: URL
    private let tileDirectory: URL
    private let session: URLSession
    private let refreshInterval: TimeInterval
    private let now: () -> Date
    private(set) var feed: Feed?
    private(set) var index: FeedIndex?
    private var tileEvents: [String: (hash: String, events: [Event])] = [:]
    private var lastAttempt: Date?
    private var reports: [EventIssueReport] = []

    init(remoteURL: URL? = FeedEventRepository.configuredURL,
         bundledURL: URL? = Bundle.main.url(forResource: "events", withExtension: "json"),
         cacheURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("events_feed.json"),
         session: URLSession = .shared,
         refreshInterval: TimeInterval = 30 * 60,
         now: @escaping () -> Date = { .now }) {
        self.remoteURL = remoteURL
        self.cacheURL = cacheURL
        self.tileDirectory = cacheURL.deletingLastPathComponent().appendingPathComponent("event_tiles", isDirectory: true)
        self.session = session
        self.refreshInterval = refreshInterval
        self.now = now
        // 保存済みと同梱のうち新しい方を使う
        feed = [cacheURL, bundledURL].compactMap { $0 }.compactMap { Self.load(Feed.self, from: $0) }
            .max { $0.generatedAt < $1.generatedAt }
        if isTiled {
            index = Self.load(FeedIndex.self, from: tileDirectory.appendingPathComponent("index.json"))
        }
    }

    static var configuredURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "EventFeedURL") as? String)
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    /// URL が .json ファイルでなければ地域ごとのファイルの置き場所とみなす
    private var isTiled: Bool {
        guard let remoteURL else { return false }
        return remoteURL.pathExtension != "json" || remoteURL.lastPathComponent == "index.json"
    }

    private var tiledBaseURL: URL? {
        guard isTiled, let remoteURL else { return nil }
        return remoteURL.lastPathComponent == "index.json" ? remoteURL.deletingLastPathComponent() : remoteURL
    }

    /// HTTP なら 200 のときだけ成功とみなす（file:// などそれ以外は成功）
    private static func isSuccess(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse).map { $0.statusCode == 200 } ?? true
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(type, from: data)
    }

    var dataSources: [DataSourceInfo] {
        (index?.sources ?? feed?.sources ?? []).map {
            DataSourceInfo(name: $0.name, url: $0.url, license: $0.license, note: $0.note)
        }
    }

    var generatedAt: Date? { index?.generatedAt ?? feed?.generatedAt }

    func searchEvents(_ query: EventSearchQuery) async throws -> [Event] {
        let current = now()
        if tiledBaseURL != nil, let events = await tiledEvents(for: query) {
            return events.filter { query.matches($0, now: current) }
        }
        await refreshSingleFeedIfNeeded()
        guard let feed else { throw URLError(.cannotLoadFromNetwork) }
        return feed.events.filter { query.matches($0, now: current) }
    }

    // MARK: - 地域ごとのファイル

    /// 検索円を囲む範囲に重なるファイルのキー（収集バッチの tile_key と同じ計算）
    static func tileKeys(for query: EventSearchQuery, tileSize: Double) -> [String] {
        let latDelta = query.radiusKm / 111.0
        let lonDelta = query.radiusKm / (111.0 * max(cos(query.latitude * .pi / 180), 0.1))
        let rows = Int(floor((query.latitude - latDelta) / tileSize))...Int(floor((query.latitude + latDelta) / tileSize))
        let columns = Int(floor((query.longitude - lonDelta) / tileSize))...Int(floor((query.longitude + lonDelta) / tileSize))
        return rows.flatMap { row in columns.map { "\(row)_\($0)" } }
    }

    private func tiledEvents(for query: EventSearchQuery) async -> [Event]? {
        guard let base = tiledBaseURL else { return nil }
        await refreshIndexIfNeeded(base: base)
        guard let index else { return nil }
        var events: [Event] = []
        for key in Self.tileKeys(for: query, tileSize: index.tileSize) {
            guard let tile = index.tiles[key] else { continue }  // イベントの無い地域
            if let cached = tileEvents[key], cached.hash == tile.hash {
                events += cached.events
                continue
            }
            let file = tileDirectory.appendingPathComponent("\(key)-\(tile.hash).json")
            var loaded = Self.load([Event].self, from: file)
            if loaded == nil, let (data, response) = try? await session.data(from: base.appendingPathComponent("tiles/\(key).json")),
               Self.isSuccess(response),
               let decoded = try? Self.decoder().decode([Event].self, from: data) {
                removeOldTiles(key: key)
                try? data.write(to: file, options: .atomic)
                loaded = decoded
            }
            if let loaded {
                tileEvents[key] = (tile.hash, loaded)
                events += loaded
            }
        }
        return events
    }

    private func refreshIndexIfNeeded(base: URL) async {
        let current = now()
        if index != nil, let lastAttempt, current.timeIntervalSince(lastAttempt) < refreshInterval { return }
        lastAttempt = current
        var request = URLRequest(url: base.appendingPathComponent("index.json"),
                                 cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              Self.isSuccess(response),
              let downloaded = try? Self.decoder().decode(FeedIndex.self, from: data) else { return }
        index = downloaded
        try? FileManager.default.createDirectory(at: tileDirectory, withIntermediateDirectories: true)
        try? data.write(to: tileDirectory.appendingPathComponent("index.json"), options: .atomic)
    }

    private func removeOldTiles(key: String) {
        try? FileManager.default.createDirectory(at: tileDirectory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: tileDirectory.path)) ?? []
        for name in files where name.hasPrefix("\(key)-") {
            try? FileManager.default.removeItem(at: tileDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - 1ファイル

    private func refreshSingleFeedIfNeeded() async {
        guard let remoteURL, !isTiled else { return }
        let current = now()
        if let lastAttempt, current.timeIntervalSince(lastAttempt) < refreshInterval { return }
        lastAttempt = current
        do {
            var request = URLRequest(url: remoteURL, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard Self.isSuccess(response) else { return }
            let downloaded = try Self.decoder().decode(Feed.self, from: data)
            if feed.map({ downloaded.generatedAt >= $0.generatedAt }) ?? true {
                feed = downloaded
                try? data.write(to: cacheURL, options: .atomic)
            }
        } catch {
            // 通信できないときは手元のデータで続ける（8. オフライン）
        }
    }

    /// 報告を受け付けるサーバーはまだ無いため、端末内に記録する
    func reportIssue(_ report: EventIssueReport) async throws {
        reports.append(report)
    }
}
