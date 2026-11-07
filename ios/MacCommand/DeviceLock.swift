import LocalAuthentication
import Observation
import Foundation

@MainActor @Observable final class DeviceLock {
    private(set) var terminalUnlocked = false
    private var generation = UUID()
    private let authenticate: @MainActor (String) async throws -> Void
    init(authenticate: @escaping @MainActor (String) async throws -> Void = DeviceLock.requireOwner) {
        self.authenticate = authenticate
    }
    func lock() { terminalUnlocked = false; generation = UUID() }
    func unlockTerminal() async throws {
        let current = generation
        try await authenticate("Verify your identity to open the terminal on your Mac.")
        try Task.checkCancellation()
        guard current == generation else { throw CancellationError() }
        terminalUnlocked = true
    }
    func authorizeFileOperation() async throws {
        let current = generation
        try await authenticate("Authorize a file transfer or move on your Mac.")
        try Task.checkCancellation()
        guard current == generation else { throw CancellationError() }
    }
    static func requireOwner(_ reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if let error { throw error }
            throw MacError.http(403, "Set up Face ID or a device passcode on your iPhone.")
        }
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
            throw MacError.unauthorized
        }
    }
}
