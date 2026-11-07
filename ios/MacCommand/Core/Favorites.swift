import Foundation

public struct FavoriteFolder: Codable, Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public init(name: String, path: String) { self.name = name; self.path = path }
}

public struct FavoriteStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load(macID: String, home: String) -> [FavoriteFolder] {
        if let data = defaults.data(forKey: "favorites.\(macID)"),
           let saved = try? JSONDecoder().decode([FavoriteFolder].self, from: data) {
            let legacyNames = ["Projeler": "Projects", "Masaüstü": "Desktop", "İndirilenler": "Downloads"]
            return saved.map { folder in
                guard let name = legacyNames[folder.name],
                      folder.path == (home as NSString).appendingPathComponent(name) else { return folder }
                return FavoriteFolder(name: name, path: folder.path)
            }
        }
        return [("Projects", "Projects"), ("Desktop", "Desktop"), ("Downloads", "Downloads")]
            .map { FavoriteFolder(name: $0.0, path: (home as NSString).appendingPathComponent($0.1)) }
    }
    func migrate(from oldID: String, to deviceID: String) {
        guard defaults.data(forKey: "favorites.\(deviceID)") == nil,
              let data = defaults.data(forKey: "favorites.\(oldID)"),
              let folders = try? JSONDecoder().decode([FavoriteFolder].self, from: data) else { return }
        try? save(folders, macID: deviceID)
    }
    public func save(_ folders: [FavoriteFolder], macID: String) throws {
        var seen = Set<String>()
        let unique = folders.filter { $0.path.hasPrefix("/") && seen.insert($0.path).inserted }
        defaults.set(try JSONEncoder().encode(unique), forKey: "favorites.\(macID)")
    }
}

public struct CommandEvent: Decodable, Sendable {
    public let type: String
    public let id: String?
    public let text: String?
    public let returncode: Int?
    public let timedOut: Bool?
    public let truncated: Bool?
    public let cancelled: Bool?
    enum CodingKeys: String, CodingKey { case type, id, text, returncode, timedOut = "timed_out", truncated, cancelled }
    public static func parse(_ data: Data) throws -> CommandEvent {
        guard data.count <= 65536 else { throw MacError.invalidResponse }
        let event: CommandEvent
        do { event = try JSONDecoder().decode(CommandEvent.self, from: data) }
        catch { throw MacError.invalidResponse }
        switch event.type {
        case "started": guard event.id != nil else { throw MacError.invalidResponse }
        case "stdout", "stderr", "error": guard event.text != nil else { throw MacError.invalidResponse }
        case "exit": guard event.returncode != nil else { throw MacError.invalidResponse }
        default: throw MacError.invalidResponse
        }
        return event
    }
}
