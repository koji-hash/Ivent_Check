import Foundation

/// 8. オフライン：直近の検索結果をファイルに保存し、通信できないときに表示する
struct SearchCache {
    struct Snapshot: Codable {
        let events: [Event]
        let latitude: Double
        let longitude: Double
        let savedAt: Date
    }

    let fileURL: URL

    init(fileURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("last_search.json")) {
        self.fileURL = fileURL
    }

    func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
