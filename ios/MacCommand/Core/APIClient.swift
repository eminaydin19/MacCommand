import Foundation
import CryptoKit

final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private actor RelayReader {
    private let receive: @Sendable () async throws -> Data
    private var cipher: RelayCipher
    private var count = 0
    private var finished = false
    private var length: Int?

    init(cipher: RelayCipher, receive: @escaping @Sendable () async throws -> Data) {
        self.receive = receive
        self.cipher = cipher
    }

    private func frame() async throws -> RelayFrame {
        try Task.checkCancellation()
        let value = try await cipher.open(receive())
        if value.kind == "error" { throw MacError.http(502, value.message ?? "") }
        return value
    }

    func status() async throws -> Int {
        let head = try await frame()
        guard head.kind == "head", let status = head.status, (100...599).contains(status),
              head.length.map({ $0 >= 0 }) ?? true else { throw MacError.invalidResponse }
        length = head.length
        return status
    }

    func chunk(limit: Int) async throws -> Data? {
        guard !finished, length.map({ $0 <= limit }) ?? true else { throw MacError.invalidResponse }
        let value = try await frame()
        if value.kind == "end" {
            guard length == nil || length == count else { throw MacError.invalidResponse }
            finished = true
            return nil
        }
        guard value.kind == "data", let encoded = value.data,
              let chunk = Data(base64Encoded: encoded), !chunk.isEmpty,
              chunk.count <= RelayCipher.chunkSize else { throw MacError.invalidResponse }
        count += chunk.count
        guard count <= limit, count <= (length ?? limit) else { throw MacError.invalidResponse }
        return chunk
    }

    func data(limit: Int) async throws -> Data {
        var body = Data()
        while let chunk = try await chunk(limit: limit) { body.append(chunk) }
        return body
    }
}

public struct APIClient: Sendable {
    public static let transferLimit = 50 * 1024 * 1024
    private struct Ready: Decodable { let type: String; let challenge: String }
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 330
        config.timeoutIntervalForResource = 360
        config.urlCache = nil
        config.httpCookieStorage = nil
        session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }

    func claim(_ code: Pairing, phone: Pairing) async throws {
        let body = try JSONEncoder().encode(["key": phone.key])
        try await exchange("POST", "pair", Discovery(pairing: code, name: "", home: "/"), body: body) { status, reader in
            try await requireStatus(status, 201, reader)
            _ = try await reader.data(limit: 16384)
        }
    }

    public func discover(_ pairing: Pairing) async throws -> Discovery {
        let info: MacInfo = try await get("info", discovery: Discovery(pairing: pairing, name: "", home: "/"))
        guard info.version == 2, info.home.hasPrefix("/"),
              Set(info.capabilities).isSuperset(of: ["trash", "transfer", "terminal_stream"]) else {
            throw MacError.incompatible
        }
        return Discovery(pairing: pairing, name: info.name, home: info.home)
    }

    public func get<T: Decodable & Sendable>(_ path: String, discovery: Discovery,
                                             query: [URLQueryItem] = []) async throws -> T {
        try decode(await data("GET", path, discovery, query: query))
    }

    public func trash(_ path: String, discovery: Discovery) async throws {
        _ = try await data("DELETE", "files", discovery, body: JSONEncoder().encode(["path": path]))
    }

    public func stop(_ id: String, discovery: Discovery) async throws {
        _ = try await data("DELETE", "terminal/" + id, discovery)
    }

    public func stream(_ command: String, cwd: String, id: String, discovery: Discovery,
                       onEvent: @Sendable (CommandEvent) async throws -> Void) async throws {
        let body = try JSONEncoder().encode(["command": command, "cwd": cwd, "id": id])
        try await exchange("POST", "terminal/stream", discovery, body: body) { status, reader in
            try await requireStatus(status, 200, reader)
            var pending = Data()
            var exited = false
            while let chunk = try await reader.chunk(limit: 8 * 1024 * 1024) {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeFirst(line.count + 1)
                    if line.isEmpty { continue }
                    guard !exited else { throw MacError.invalidResponse }
                    let event = try CommandEvent.parse(line)
                    try await onEvent(event)
                    if event.type == "exit" { exited = true }
                    if event.type == "error" { throw MacError.http(400, event.text ?? "Komut çalıştırılamadı.") }
                }
                guard pending.count <= 65536 else { throw MacError.invalidResponse }
            }
            guard exited, pending.isEmpty else { throw MacError.invalidResponse }
        }
    }

    public func upload(_ file: URL, directory: String, discovery: Discovery) async throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let length = values.fileSize, (0...Self.transferLimit).contains(length) else {
            throw MacError.http(413, "Yalnızca 50 MB veya daha küçük normal dosyalar aktarılabilir.")
        }
        try await exchange("PUT", "files/upload", discovery,
            query: [.init(name: "directory", value: directory), .init(name: "name", value: file.lastPathComponent)],
            file: file, fileLength: length) { status, reader in
            try await requireStatus(status, 201, reader)
            _ = try await reader.data(limit: 16384)
        }
    }

    public func download(_ path: String, discovery: Discovery) async throws -> URL {
        try await exchange("GET", "files/download", discovery, query: [.init(name: "path", value: path)]) { status, reader in
            try await requireStatus(status, 200, reader)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let name = (path as NSString).lastPathComponent
            let target = folder.appendingPathComponent(name.isEmpty || [".", "..", "/"].contains(name) ? "MacCommand-download" : name)
            do {
                guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                while let chunk = try await reader.chunk(limit: Self.transferLimit) { try handle.write(contentsOf: chunk) }
                try handle.synchronize()
                return target
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
    }

    private func requireStatus(_ status: Int, _ expected: Int, _ reader: RelayReader) async throws {
        guard status != expected else { return }
        if status == 401 { throw MacError.unauthorized }
        struct Detail: Decodable { let detail: String }
        let body = try await reader.data(limit: 16384)
        throw MacError.http(status, (try? JSONDecoder().decode(Detail.self, from: body))?.detail ?? "")
    }

    private func data(_ method: String, _ path: String, _ discovery: Discovery,
                      query: [URLQueryItem] = [], body: Data = Data()) async throws -> Data {
        try await exchange(method, path, discovery, query: query, body: body) { status, reader in
            try await requireStatus(status, 200, reader)
            let limit = path == "files/read" ? 30 * 1024 * 1024 + 65536 : 8 * 1024 * 1024
            return try await reader.data(limit: limit)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw MacError.invalidResponse }
    }

    private func exchange<T: Sendable>(_ method: String, _ path: String, _ discovery: Discovery,
                                       query: [URLQueryItem] = [], body: Data = Data(), file: URL? = nil,
                                       fileLength: Int? = nil,
                                       consume: (Int, RelayReader) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard let pairing = discovery.pairing, let key = Data(base64Encoded: pairing.key) else { throw MacError.pairing }
        if pairing.version == 4 {
            return try await cloudExchange(method, path, pairing: pairing, key: key, query: query,
                body: body, file: file, fileLength: fileLength, consume: consume)
        }
        guard let token = pairing.token else { throw MacError.pairing }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var request = URLRequest(url: try pairing.socketURL(requestID: id), timeoutInterval: 330)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = RelayCipher.maxPlaintext + 36
        return try await withTaskCancellationHandler {
            defer { socket.cancel(with: .normalClosure, reason: nil) }
            try Task.checkCancellation()
            socket.resume()
            guard case .string(let text) = try await socket.receive(), text.utf8.count <= 256,
                  let ready = try? JSONDecoder().decode(Ready.self, from: Data(text.utf8)),
                  ready.type == "ready" else { throw MacError.invalidResponse }
            let channel = try RelayCipher.channelKey(key, requestID: id, challenge: ready.challenge)
            var writer = try RelayCipher(key: channel, requestID: id, direction: "request")
            func send(_ frame: RelayFrame) async throws {
                try Task.checkCancellation()
                try await socket.send(.data(writer.seal(frame)))
            }
            try await sendRequest(method, path, query: query, body: body, file: file, fileLength: fileLength, emit: send)
            let reader = RelayReader(cipher: try RelayCipher(key: channel, requestID: id, direction: "response")) {
                guard case .data(let bytes) = try await socket.receive() else { throw MacError.invalidResponse }
                return bytes
            }
            let status = try await reader.status()
            return try await consume(status, reader)
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }
}
    private func cloudExchange<T: Sendable>(_ method: String, _ path: String, pairing: Pairing, key: Data,
        query: [URLQueryItem], body: Data, file: URL?, fileLength: Int?,
        consume: (Int, RelayReader) async throws -> T) async throws -> T {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let mailbox = CloudMailbox(deviceID: pairing.deviceID)
        let channel = try RelayCipher.channelKey(key, requestID: id, challenge: pairing.deviceID)
        let writer = CloudPacketWriter(folder: folder)
        var cipher = try RelayCipher(key: channel, requestID: id, direction: "request")
        let lifetime = method == "PUT" ? 280 : 45
        try await sendRequest(method, path, query: query, body: body, file: file, fileLength: fileLength,
            deadline: Int(Date().timeIntervalSince1970) + lifetime) { frame in
            try Task.checkCancellation()
            try writer.append(cipher.seal(frame))
        }
        try writer.close()
        do {
            try Task.checkCancellation()
            try await mailbox.submit(id, assets: writer.urls)
            let timeout: Duration = path == "terminal/stream" || path == "files/upload" || path == "files/download"
                ? .seconds(370) : .seconds(50)
            let reply = try await mailbox.awaitReply(id, timeout: timeout)
            defer { withExtendedLifetime(reply) {} }
            let packet = try CloudPacketReader(urls: mailbox.assetURLs(reply))
            let reader = RelayReader(cipher: try RelayCipher(key: channel, requestID: id, direction: "response")) {
                try await packet.next()
            }
            let status = try await reader.status()
            let result = try await consume(status, reader)
            try? await mailbox.delete(id)
            return result
        } catch {
            // Deleting a queued job prevents it from being claimed later.
            try? await mailbox.delete(id)
            if Task.isCancelled { throw CancellationError() }
            throw CloudMailbox.explain(error)
        }
    }

    private func sendRequest(_ method: String, _ path: String, query: [URLQueryItem], body: Data,
        file: URL?, fileLength: Int?, deadline: Int? = nil, emit: (RelayFrame) async throws -> Void) async throws {
        var components = URLComponents()
            components.queryItems = query
            let length = fileLength ?? body.count
            try await emit(RelayFrame(kind: "head", method: method, path: "/" + path,
                                      query: components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? "", length: length, deadline: deadline))
            if let file {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                var remaining = length
                while remaining > 0 {
                    guard let chunk = try handle.read(upToCount: min(remaining, RelayCipher.chunkSize)),
                          !chunk.isEmpty else { throw MacError.invalidResponse }
                    remaining -= chunk.count
                    try await emit(RelayFrame(kind: "data", data: chunk.base64EncodedString()))
                }
                guard try handle.read(upToCount: 1)?.isEmpty != false else { throw MacError.invalidResponse }
            } else {
                for offset in stride(from: 0, to: body.count, by: RelayCipher.chunkSize) {
                    let chunk = body[offset..<min(offset + RelayCipher.chunkSize, body.count)]
                    try await emit(RelayFrame(kind: "data", data: chunk.base64EncodedString()))
                }
            }
            try await emit(RelayFrame(kind: "end"))
    }
