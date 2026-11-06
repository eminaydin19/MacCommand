import SwiftUI
import Observation
import CryptoKit

@MainActor @Observable final class Session {
    var pairing: Pairing?
    var discovery: Discovery?
    var metrics: Metrics?
    var lastUpdated: Date?
    var connecting = false
    var message: String?
    var storageError: String?
    var selectedTab = 0
    var isDemo = false
    let deviceLock: DeviceLock
    var favoriteFolders: [FavoriteFolder] = []
    private let api: APIClient
    private let store = PairingStore()
    private let pendingPairing = PairingStore(account: "pending-pairing-v3")
    private var generation = UUID()

    init(api: APIClient = APIClient(), deviceLock: DeviceLock = DeviceLock()) {
        self.api = api
        self.deviceLock = deviceLock
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            isDemo = true
            discovery = Discovery(pairing: nil, name: "Emin’in Mac’i", home: "/Users/emin")
            metrics = try? JSONDecoder().decode(Metrics.self, from: Data(#"{"cpu_percent":18,"ram":{"total":17179869184,"used":9878424780,"available":7301444404,"percent":57.5},"disk":{"total":500107862016,"used":214794731520,"free":285313130496,"percent":43},"battery":{"percent":84,"charging":false,"seconds_left":18420}}"#.utf8))
            loadFavorites()
            lastUpdated = .now
            if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--tab"), ProcessInfo.processInfo.arguments.count > i+1 {
                selectedTab = Int(ProcessInfo.processInfo.arguments[i+1]) ?? 0
            }
            return
        }
        #endif
        do { pairing = try store.load() }
        catch { storageError = error.localizedDescription }
    }
    var usesCloudKit: Bool { pairing?.version == 4 }
    var hasPairing: Bool { pairing != nil || isDemo }
    var status: String {
        if isDemo { return "Önizleme · örnek veriler" }
        if connecting { return "Bağlanıyor…" }
        return discovery == nil ? "Çevrimdışı" : "Bağlı"
    }
    func pair(_ text: String) async throws {
        let code = try Pairing.parse(text)
        let staged = try pendingPairing.load()
        let canResume = staged?.deviceID == code.deviceID && staged?.relay == code.relay && staged?.token == code.token
        let new: Pairing
        if canResume, let staged {
            new = staged
        } else {
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
            new = Pairing(version: code.version, relay: code.relay, deviceID: code.deviceID, token: code.token, key: key)
            try pendingPairing.save(new)
        }
        let candidate: Discovery
        if canResume, let recovered = try? await api.discover(new) {
            candidate = recovered
        } else {
            try Task.checkCancellation()
            try await api.claim(code, phone: new)
            candidate = try await api.discover(new)
        }
        try completePairing(new, discovery: candidate)
    }

    func resumePendingPairing() async {
        guard pairing == nil, let pending = try? pendingPairing.load(),
              let candidate = try? await api.discover(pending),
              pairing == nil, (try? pendingPairing.load()) == pending else { return }
        try? completePairing(pending, discovery: candidate)
    }

    private func completePairing(_ new: Pairing, discovery candidate: Discovery) throws {
        try Task.checkCancellation()
        try store.save(new)
        try? pendingPairing.delete()
        let legacy = PairingStore(account: "pairing-v1")
        if let oldID = try? legacy.legacyFavoritesID() {
            FavoriteStore().migrate(from: oldID, to: new.deviceID)
            try? legacy.delete()
        }
        storageError = nil
        generation = UUID()
        pairing = new
        discovery = candidate
        loadFavorites()
        message = nil
    }
    func reconnect() async {
        guard !isDemo, !connecting, let pairing else { return }
        let current = generation
        connecting = true
        defer { if current == generation { connecting = false } }
        do {
            let candidate = try await api.discover(pairing)
            try Task.checkCancellation()
            guard current == generation else { return }
            discovery = candidate
            loadFavorites()
            message = nil
        } catch {
            guard !Task.isCancelled, current == generation else { return }
            discovery = nil
            message = Self.describe(error)
        }
    }
    func refreshMetrics() async {
        guard !isDemo, let discovery else { return }
        let current = generation
        do {
            let value: Metrics = try await api.get("metrics", discovery: discovery)
            try Task.checkCancellation()
            guard current == generation else { return }
            metrics = value
            lastUpdated = .now
            message = nil
        } catch {
            guard !Task.isCancelled, current == generation else { return }
            self.discovery = nil
            message = Self.describe(error)
        }
    }
    func files(_ path: String) async throws -> DirectoryListing {
        #if DEBUG
        if isDemo {
            return try JSONDecoder().decode(DirectoryListing.self, from: Data(#"{"path":"/Users/emin","entries":[{"name":"Belgeler","path":"/Users/emin/Belgeler","is_dir":true,"is_symlink":false,"size":128,"modified":1793872800},{"name":"Masaüstü","path":"/Users/emin/Masaüstü","is_dir":true,"is_symlink":false,"size":128,"modified":1793872800},{"name":"Projeler","path":"/Users/emin/Projeler","is_dir":true,"is_symlink":false,"size":128,"modified":1793872800},{"name":"notlar.md","path":"/Users/emin/notlar.md","is_dir":false,"is_symlink":false,"size":2480,"modified":1793872800}]}"#.utf8))
        }
        #endif
        guard let discovery else { throw MacError.http(503, "Mac çevrimdışı. Önce yeniden bağlanın.") }
        do { return try await api.get("files", discovery: discovery, query: [.init(name: "path", value: path)]) }
        catch { connectionFailed(error, attempted: discovery); throw error }
    }
    func read(_ path: String) async throws -> FileContent {
        guard !isDemo, let discovery else { throw MacError.http(503, "Canlı Mac bağlantısı gerekiyor.") }
        do { return try await api.get("files/read", discovery: discovery, query: [.init(name: "path", value: path)]) }
        catch { connectionFailed(error, attempted: discovery); throw error }
    }
    func trash(_ path: String) async throws {
        guard !isDemo, let discovery else { throw MacError.http(503, "Canlı Mac bağlantısı gerekiyor.") }
        try await deviceLock.authorizeFileOperation()
        do { try await api.trash(path, discovery: discovery) }
        catch { connectionFailed(error, attempted: discovery); throw error }
    }
    private var macID: String { pairing?.deviceID ?? "demo" }
    private func loadFavorites() {
        if let discovery { favoriteFolders = FavoriteStore().load(macID: macID, home: discovery.home) }
    }
    func toggleFavorite(_ path: String, name: String) throws {
        var folders = favoriteFolders
        if folders.contains(where: { $0.path == path }) { folders.removeAll { $0.path == path } }
        else { folders.append(.init(name: name, path: path)) }
        try FavoriteStore().save(folders, macID: macID)
        favoriteFolders = folders
    }
    func upload(_ file: URL, directory: String) async throws {
        guard !isDemo, let discovery else { throw MacError.http(503,"Canlı Mac bağlantısı gerekiyor.") }
        try await deviceLock.authorizeFileOperation()
        do { try await api.upload(file, directory: directory, discovery: discovery) }
        catch { connectionFailed(error, attempted: discovery); throw error }
    }
    func download(_ path: String) async throws -> URL {
        guard !isDemo, let discovery else { throw MacError.http(503,"Canlı Mac bağlantısı gerekiyor.") }
        try await deviceLock.authorizeFileOperation()
        do { return try await api.download(path, discovery: discovery) }
        catch { connectionFailed(error, attempted: discovery); throw error }
    }
    func stream(_ command: String, cwd: String, id: String,
                onEvent: @escaping @Sendable (CommandEvent) async throws -> Void) async throws {
        guard deviceLock.terminalUnlocked else { throw MacError.http(403,"Önce terminalin kilidini açın.") }
        guard !isDemo, let discovery else { throw MacError.http(503,"Canlı Mac bağlantısı gerekiyor.") }
        do { try await api.stream(command, cwd: cwd, id: id, discovery: discovery, onEvent: onEvent) }
        catch { connectionFailed(error, attempted: discovery); throw error }
    }
    func stop(_ id: String) async throws {
        guard !isDemo, let discovery else { throw MacError.http(503,"Canlı Mac bağlantısı gerekiyor.") }
        try await api.stop(id, discovery: discovery)
    }
    func checkConnection() async {
        guard !isDemo, let discovery else { return }
        do {
            let info: MacInfo = try await api.get("info", discovery: discovery)
            guard info.version == 2 else { throw MacError.incompatible }
        } catch { connectionFailed(error, attempted: discovery) }
    }
    private func connectionFailed(_ error: Error, attempted: Discovery) {
        guard discovery?.pairing == attempted.pairing else { return }
        let shouldReconnect: Bool
        if let urlError = error as? URLError {
            shouldReconnect = urlError.code != .cancelled
        } else if let error = error as? MacError {
            switch error {
            case .unauthorized, .invalidResponse, .incompatible: shouldReconnect = true
            case .http(let status, _): shouldReconnect = status >= 500
            default: shouldReconnect = false
            }
        } else { shouldReconnect = false }
        if shouldReconnect {
            discovery = nil
            message = Self.describe(error)
        }
    }
    func forget() throws {
        try store.delete()
        try? pendingPairing.delete()
        storageError = nil
        generation = UUID()
        deviceLock.lock()
        favoriteFolders = []
        pairing = nil
        discovery = nil
        metrics = nil
        lastUpdated = nil
        message = nil
        connecting = false
        selectedTab = 0
        isDemo = false
    }
    static func describe(_ error: Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet: return "İnternet bağlantısı yok. Bağlantını kontrol edip tekrar dene."
            case .timedOut: return "Mac zamanında yanıt vermedi. Açık ve internete bağlı olduğundan emin ol."
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost:
                return "Mac’e ulaşılamıyor. Mac’in açık ve servisin çalışıyor olduğunu kontrol et."
            default: return "Bağlantı kurulamadı. İnternetini ve Mac servisini kontrol et."
            }
        }
        return error.localizedDescription
    }
}
