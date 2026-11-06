import Foundation

public enum MacError: LocalizedError, Sendable {
    case pairing, discovery, unsafeURL, incompatible, unauthorized, http(Int, String), invalidResponse
    public var errorDescription: String? {
        switch self {
        case .pairing: "Eşleştirme bilgisi geçersiz. Mac’teki güncel QR kodunu kullanın."
        case .discovery: "Bağlantı bilgileri açılamadı. Mac’te servisi kontrol edin veya yeniden eşleştirin."
        case .unsafeURL: "Güvenli bir Mac bağlantısı bulunamadı. Mac’te servisi yeniden başlatın."
        case .incompatible: "Mac servisi güncel değil. MacCommand servisinin bu uygulamayla birlikte gelen sürümünü başlatın."
        case .unauthorized: "Mac’in erişim anahtarı değişmiş olabilir. Yeniden bağlanmayı deneyin."
        case .http(let code, let message): message.isEmpty ? "Sunucu yanıtı: \(code). Daha sonra tekrar deneyin." : message
        case .invalidResponse: "Mac’ten beklenmeyen bir yanıt geldi. Servisin sürümünü kontrol edin."
        }
    }
}

public struct Pairing: Codable, Equatable, Sendable {
    public let version: Int
    public let relay: String?
    public let deviceID: String
    public let token: String?
    public let key: String
    enum CodingKeys: String, CodingKey { case version, relay, deviceID = "device_id", token, key }

    public static func parse(_ text: String) throws -> Pairing {
        guard text.utf8.count < 4096,
              let pairing = try? JSONDecoder().decode(Pairing.self, from: Data(text.utf8)),
              [3, 4].contains(pairing.version),
              pairing.deviceID.range(of: #"\A[a-f0-9]{32}\z"#, options: .regularExpression) != nil,
              let key = Data(base64Encoded: pairing.key), key.count == 32 else { throw MacError.pairing }
        if pairing.version == 3 {
            guard pairing.token?.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil else { throw MacError.pairing }
            _ = try pairing.socketURL(requestID: String(repeating: "0", count: 32))
        } else if pairing.relay != nil || pairing.token != nil {
            throw MacError.pairing
        }
        return pairing
    }

    func socketURL(requestID: String) throws -> URL {
        guard let relay, var origin = URLComponents(string: relay),
              let host = origin.host, !host.isEmpty,
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/" else { throw MacError.unsafeURL }
        if origin.scheme == "https" {
            origin.scheme = "wss"
        } else {
            #if DEBUG || SWIFT_PACKAGE
            guard origin.scheme == "http", host == "127.0.0.1", origin.port != nil else { throw MacError.unsafeURL }
            origin.scheme = "ws"
            #else
            throw MacError.unsafeURL
            #endif
        }
        origin.path = "/v1/phone/\(deviceID)/\(requestID)"
        guard let url = origin.url else { throw MacError.unsafeURL }
        return url
    }
}

public struct Discovery: Sendable {
    public let pairing: Pairing?
    public let name: String
    public let home: String
}

public struct MacInfo: Decodable, Sendable {
    public let version: Int
    public let name: String
    public let home: String
    public let capabilities: [String]
}
public struct Metrics: Decodable, Sendable {
    public let cpuPercent: Double
    public let ram: Memory
    public let disk: Disk
    public let battery: Battery?
    enum CodingKeys: String, CodingKey { case cpuPercent = "cpu_percent", ram, disk, battery }
    public struct Memory: Decodable, Sendable { public let total, used, available: Int64; public let percent: Double }
    public struct Disk: Decodable, Sendable { public let total, used, free: Int64; public let percent: Double }
    public struct Battery: Decodable, Sendable {
        public let percent: Double
        public let charging: Bool
        public let secondsLeft: Int
        enum CodingKeys: String, CodingKey { case percent, charging, secondsLeft = "seconds_left" }
    }
}
public struct DirectoryListing: Decodable, Sendable {
    public let path: String
    public let entries: [FileEntry]
}
public struct FileEntry: Decodable, Identifiable, Sendable {
    public var id: String { path }
    public let name, path: String
    public let isDir, isSymlink: Bool
    public let size: Int64
    public let modified: Double
    enum CodingKeys: String, CodingKey { case name, path, size, modified, isDir = "is_dir", isSymlink = "is_symlink" }
}
public struct FileContent: Decodable, Sendable { public let path, content: String }
public struct CommandResult: Decodable, Sendable {
    public let stdout, stderr: String
    public let returncode: Int
    public let timedOut, truncated: Bool
    enum CodingKeys: String, CodingKey { case stdout, stderr, returncode, timedOut = "timed_out", truncated }
}
