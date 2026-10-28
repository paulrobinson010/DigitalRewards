import Foundation

/// Small Codable key/value store in Application Support. Used for offline queues,
/// last-known rules and alert bookkeeping. Not shared between iPhone and Watch.
enum LocalCache {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DigitalRewards", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func url(_ key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(key), options: .atomic)
    }

    static func remove(key: String) {
        try? FileManager.default.removeItem(at: url(key))
    }
}
