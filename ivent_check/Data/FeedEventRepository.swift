import Foundation

/// 収集バッチが毎朝作る events.json を読むリポジトリ。
///
/// - `EventFeedURL`（Info.plist）が設定されていればそこから取得し、端末に保存する
/// - 未設定・通信できないときは、前回保存したもの → アプリ同梱の events.json の順に使う
/// - 半径・期間・カテゴリの絞り込みは端末側で行う（座標はどこにも送らない）
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

    private let remoteURL: URL?
    private let cacheURL: URL
    private let session: URLSession
    private let refreshInterval: TimeInterval
    private let now: () -> Date
    private(set) var feed: Feed?
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
        self.session = session
        self.refreshInterval = refreshInterval
        self.now = now
        // 保存済みと同梱のうち新しい方を使う
        feed = [cacheURL, bundledURL].compactMap { $0 }.compactMap { Self.load($0) }.max { $0.generatedAt < $1.generatedAt }
    }

    static var configuredURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "EventFeedURL") as? String)
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func load(_ url: URL) -> Feed? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(Feed.self, from: data)
    }

    var dataSources: [DataSourceInfo] {
        feed?.sources.map { DataSourceInfo(name: $0.name, url: $0.url, license: $0.license, note: $0.note) } ?? []
    }

    var generatedAt: Date? { feed?.generatedAt }

    func searchEvents(_ query: EventSearchQuery) async throws -> [Event] {
        await refreshIfNeeded()
        guard let feed else { throw URLError(.cannotLoadFromNetwork) }
        let current = now()
        return feed.events.filter { query.matches($0, now: current) }
    }

    private func refreshIfNeeded() async {
        guard let remoteURL else { return }
        let current = now()
        if let lastAttempt, current.timeIntervalSince(lastAttempt) < refreshInterval { return }
        lastAttempt = current
        do {
            var request = URLRequest(url: remoteURL, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
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
