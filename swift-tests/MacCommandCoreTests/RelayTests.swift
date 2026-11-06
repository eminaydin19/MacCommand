import Foundation
import Testing
#if canImport(MacCommandCore)
@testable import MacCommandCore
#else
@testable import MacCommand
#endif

@Test func relayDecryptsPythonAndRejectsReplayAndDirectionChanges() throws {
    let frame = Data(base64Encoded: "AAAAAAAAAAAAAQIDBAUGBwgJCgs8IL1yq4HgIa8l9v/Qy1RP57fzVdJBfR1/MZbnWlE9kHwpKkiGkWiL2vsmZeL4Qpda")!
    var reader = try RelayCipher(key: Data(0..<32), requestID: String(repeating:"a",count:32), direction:"response")
    #expect(try reader.open(frame).data == "aGVsbG8=")
    #expect(throws: Error.self) { try reader.open(frame) }
    var wrong = try RelayCipher(key: Data(0..<32), requestID: String(repeating:"a",count:32), direction:"request")
    #expect(throws: Error.self) { try wrong.open(frame) }
    var other = try RelayCipher(key: Data(0..<32), requestID: String(repeating:"b",count:32), direction:"response")
    #expect(throws: Error.self) { try other.open(frame) }
}

@Test func relayRoundtripAndSizeLimit() throws {
    var writer = try RelayCipher(key: Data(repeating:42,count:32),requestID:String(repeating:"c",count:32),direction:"request")
    var reader = try RelayCipher(key: Data(repeating:42,count:32),requestID:String(repeating:"c",count:32),direction:"request")
    let frame = try writer.seal(RelayFrame(kind:"data",data:"Türkçe"))
    #expect(try reader.open(frame).data == "Türkçe")
    #expect(throws: Error.self) { try writer.seal(RelayFrame(kind:"data",data:String(repeating:"a",count:100000))) }
    var changed = frame
    changed[changed.count-1] ^= 1
    var clean = try RelayCipher(key: Data(repeating:42,count:32),requestID:String(repeating:"c",count:32),direction:"request")
    #expect(throws: Error.self) { try clean.open(changed) }
}

@Test func relayPairingAcceptsSecureOriginsAndRejectsLegacyCodes() throws {
    let id = String(repeating: "a", count: 32)
    let token = String(repeating: "b", count: 64)
    let key = Data(repeating: 42, count: 32).base64EncodedString()
    func code(_ relay: String) -> String {
        """
        {"version":3,"relay":"\(relay)","device_id":"\(id)","token":"\(token)","key":"\(key)"}
        """
    }
    #expect(try Pairing.parse(code("https://relay.example")).deviceID == id)
    for origin in ["http://relay.example","https://user@relay.example","https://relay.example/x","https://relay.example?x=1"] {
        #expect(throws: Error.self) { try Pairing.parse(code(origin)) }
    }
    #expect(throws: Error.self) { try Pairing.parse(#"{"version":1,"gist_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"#) }
}

func testPairing(relay: String, key: String = Data(0..<32).base64EncodedString()) -> String {
    """
    {"version":3,"relay":"\(relay)","device_id":"\(String(repeating: "d", count: 32))","token":"\(String(repeating: "2", count: 64))","key":"\(key)"}
    """
}

@Test func cancelledStreamDoesNotOpenSocket() async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await APIClient().stream("pwd", cwd: "/", id: "test",
            discovery: Discovery(pairing: nil, name: "", home: "/")) { _ in }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func relayRedirectGuardDiscardsNewRequest() {
    let source = URL(string: "https://relay.example")!
    let session = URLSession(configuration: .ephemeral)
    let response = HTTPURLResponse(url: source, statusCode: 307, httpVersion: nil, headerFields: nil)!
    RedirectGuard().urlSession(session, task: session.dataTask(with: source), willPerformHTTPRedirection: response,
        newRequest: URLRequest(url: URL(string: "https://other.example")!)) { request in
        #expect(request == nil)
    }
}

#if SWIFT_PACKAGE
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACCOMMAND_TEST_RELAY"] != nil))
func swiftClientWorksThroughPythonRelay() async throws {
    let env = ProcessInfo.processInfo.environment
    let origin = try #require(env["MACCOMMAND_TEST_RELAY"])
    let directory = try #require(env["MACCOMMAND_TEST_DIRECTORY"])
    let api = APIClient()
    let code = try Pairing.parse(testPairing(relay: origin))
    let phone = Pairing(version: code.version, relay: code.relay, deviceID: code.deviceID,
                        token: code.token, key: Data(repeating: 27, count: 32).base64EncodedString())
    try await api.claim(code, phone: phone)
    let discovery = try await api.discover(phone)
    await #expect(throws: Error.self) { _ = try await api.discover(code) }
    let file = URL(fileURLWithPath: directory).appendingPathComponent("Türkçe + &.bin")
    let bytes = Data(repeating: 255, count: 48 * 1024) + Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
    try bytes.write(to: file)
    let destination = URL(fileURLWithPath: directory).appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    try await api.upload(file, directory: destination.path, discovery: discovery)
    let downloaded = try await api.download(destination.appendingPathComponent(file.lastPathComponent).path, discovery: discovery)
    defer { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) }
    #expect(try Data(contentsOf: downloaded) == bytes)
    let id = String(repeating: "a", count: 32)
    try await api.stream("printf live; sleep 20", cwd: directory, id: id, discovery: discovery) { event in
        if event.text == "live" { try await api.stop(id, discovery: discovery) }
        if event.type == "exit" { #expect(event.cancelled == true) }
    }
    let previewFile = URL(fileURLWithPath: directory).appendingPathComponent("escaped.txt")
    let previewBytes = Data(repeating: 1, count: 2 * 1024 * 1024)
    try previewBytes.write(to: previewFile)
    let preview: FileContent = try await api.get("files/read", discovery: discovery,
        query: [.init(name: "path", value: previewFile.path)])
    #expect(preview.content.utf8.count == previewBytes.count)
}
#endif

@Test func cloudKitPairingUsesNoRelayAddress() throws {
    let id = String(repeating: "d", count: 32)
    let key = Data(repeating: 42, count: 32).base64EncodedString()
    let code = """
    {"version":4,"device_id":"\(id)","key":"\(key)"}
    """
    let pairing = try Pairing.parse(code)
    #expect(pairing.version == 4 && pairing.deviceID == id && pairing.relay == nil && pairing.token == nil)
    #expect(throws: Error.self) {
        try Pairing.parse(code.replacingOccurrences(of: "\"version\":4", with: "\"version\":4,\"relay\":\"https://relay.example\""))
    }
}

@Test func cloudPacketSpoolsFullTransferAcrossTwoAssets() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let job = String(repeating: "a", count: 32)
    let writer = CloudPacketWriter(folder: folder)
    var cipher = try RelayCipher(key: Data(repeating: 42, count: 32), requestID: job, direction: "request")
    let data = Data(repeating: 255, count: RelayCipher.chunkSize)
    let length = APIClient.transferLimit
    var remaining = length
    while remaining > 0 {
        let size = min(remaining, data.count)
        try writer.append(cipher.seal(RelayFrame(kind: "data", data: data.prefix(size).base64EncodedString())))
        remaining -= size
    }
    try writer.append(cipher.seal(RelayFrame(kind: "end")))
    try writer.close()
    #expect(writer.urls.count == 2)
    let reader = try CloudPacketReader(urls: writer.urls)
    var opening = try RelayCipher(key: Data(repeating: 42, count: 32), requestID: job, direction: "request")
    var decoded = 0
    while true {
        let frame = try await reader.next()
        let value = try opening.open(frame)
        if value.kind == "end" { break }
        let chunk = try #require(value.data.flatMap { Data(base64Encoded: $0) })
        decoded += chunk.count
        #expect(chunk.first == 255 && chunk.last == 255)
    }
    #expect(decoded == length)
}
