import Foundation
import Testing
#if canImport(MacCommandCore)
@testable import MacCommandCore
#else
import LocalAuthentication
@testable import MacCommand
#endif

@Test func commandAndMetricsDecodeBackendContract() throws {
    let result = try JSONDecoder().decode(CommandResult.self, from: Data(#"{"stdout":"hello","stderr":"","returncode":0,"timed_out":false,"truncated":false}"#.utf8))
    #expect(result.stdout == "hello" && result.returncode == 0)
    let metrics = try JSONDecoder().decode(Metrics.self, from: Data(#"{"cpu_percent":12.5,"ram":{"total":100,"used":50,"available":50,"percent":50},"disk":{"total":200,"used":50,"free":150,"percent":25},"battery":null}"#.utf8))
    #expect(metrics.cpuPercent == 12.5 && metrics.battery == nil)
}

#if canImport(MacCommand)
@MainActor @Test func keychainRoundtripAndRemoval() throws {
    let store = PairingStore(account: "test-\(UUID().uuidString)")
    let key = Data(repeating: 42, count: 32).base64EncodedString()
    let pairing = try Pairing.parse(testPairing(relay: "https://relay.example", key: key))
    #expect(try store.load() == nil)
    try store.save(pairing)
    defer { try? store.delete() }
    #expect(try store.load()?.key == key)
    try store.save(pairing)
    try store.delete()
    #expect(try store.load() == nil)
}
#endif

@Test func favoritesPersistPerMacWithoutDuplicates() throws {
    let defaults = UserDefaults(suiteName: "test-\(UUID())")!
    let store = FavoriteStore(defaults: defaults)
    let original = store.load(macID: "mac-a", home: "/Users/emin")
    #expect(original.map(\.name) == ["Projects", "Desktop", "Downloads"])
    #expect(original[0].path == "/Users/emin/Projects")
    try store.save([original[0], original[0]], macID: "mac-a")
    #expect(store.load(macID: "mac-a", home: "/other").count == 1)
    #expect(store.load(macID: "mac-b", home: "/other").count == 3)
    store.migrate(from: "mac-a", to: "migrated")
    #expect(store.load(macID: "migrated", home: "/other") == [original[0]])
    try store.save([], macID: "mac-a")
    #expect(store.load(macID: "mac-a", home: "/other").isEmpty)
}

@Test func legacyFavoriteLabelsUseEnglishWithoutChangingCustomFolders() throws {
    let defaults = UserDefaults(suiteName: "test-\(UUID())")!
    let store = FavoriteStore(defaults: defaults)
    let custom = FavoriteFolder(name: "Masaüstü", path: "/Users/emin/Custom")
    try store.save([
        FavoriteFolder(name: "Projeler", path: "/Users/emin/Projects"),
        FavoriteFolder(name: "Masaüstü", path: "/Users/emin/Desktop"),
        FavoriteFolder(name: "İndirilenler", path: "/Users/emin/Downloads"),
        custom,
    ], macID: "legacy")
    let loaded = store.load(macID: "legacy", home: "/Users/emin")
    #expect(loaded.map(\.name) == ["Projects", "Desktop", "Downloads", custom.name])
    #expect(loaded.map(\.path) == ["/Users/emin/Projects", "/Users/emin/Desktop", "/Users/emin/Downloads", custom.path])
}

@Test func commandEventParserRejectsUnknownAndOversizedEvents() throws {
    #expect(try CommandEvent.parse(Data(#"{"type":"stdout","text":"Türkçe"}"#.utf8)).text == "Türkçe")
    #expect(throws: Error.self) { try CommandEvent.parse(Data(#"{"type":"unknown"}"#.utf8)) }
    #expect(throws: Error.self) { try CommandEvent.parse(Data(repeating: 65, count: 65537)) }
}

#if canImport(MacCommand)
@MainActor @Test func deniedLocalAuthenticationNeverUnlocksTerminal() async {
    let lock = DeviceLock(authenticate: { _ in throw MacError.unauthorized })
    await #expect(throws: Error.self) { try await lock.unlockTerminal() }
    #expect(!lock.terminalUnlocked)
}
@MainActor @Test func systemErrorsUseEnglishAndKeepAppGuidance() {
    #expect(Session.describe(URLError(.notConnectedToInternet)) == "No internet connection. Check your connection and try again.")
    #expect(Session.describe(LAError(.biometryLockout)) == "Unlock your iPhone with your passcode, then try again.")
    #expect(Session.describe(NSError(domain: "Custom", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bir hata oluştu"])) == "The operation could not be completed. Check your connection and try again.")
    #expect(Session.describe(MacError.http(403, "Check the folder permissions.")) == "Check the folder permissions.")
}
@MainActor @Test func terminalRelocksAndFileOperationsAlwaysAuthenticate() async throws {
    var calls = 0
    let lock = DeviceLock(authenticate: { _ in calls += 1 })
    try await lock.unlockTerminal()
    #expect(lock.terminalUnlocked)
    lock.lock()
    #expect(!lock.terminalUnlocked)
    try await lock.authorizeFileOperation()
    try await lock.authorizeFileOperation()
    #expect(calls == 3)
}
#endif

#if canImport(MacCommand)
@Test func packagedShareExtensionUsesSameKeychainGroup() throws {
    let appGroup = try #require(Bundle.main.object(forInfoDictionaryKey: "MacCommandKeychainGroup") as? String)
    let info = try #require(Bundle.main.builtInPlugInsURL?.appendingPathComponent("MacCommandShare.appex/Info.plist"))
    let dictionary = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String:Any])
    #expect(dictionary["MacCommandKeychainGroup"] as? String == appGroup)
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String] == ["en"])
    #expect(dictionary["CFBundleLocalizations"] as? [String] == ["en"])
    #expect(dictionary["CFBundleDisplayName"] as? String == "Send to Mac")
    #expect(!appGroup.contains("$("))
}
#endif
