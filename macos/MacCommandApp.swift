import AppKit
@preconcurrency import CloudKit
import CoreImage.CIFilterBuiltins
import Observation
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class Companion {
    enum Status: String, Decodable {
        case unconfigured, stopped, starting, connected, waiting, stopping, error, alreadyRunning

        var title: String {
            switch self {
            case .unconfigured: "iCloud yapılandırması bekleniyor"
            case .stopped: "Erişim kapalı"
            case .starting: "Başlatılıyor"
            case .connected: "Erişim açık"
            case .waiting: "Bağlantı bekleniyor"
            case .stopping: "Durduruluyor"
            case .error: "Uygulama başlatılamadı"
            case .alreadyRunning: "MacCommand zaten çalışıyor"
            }
        }

        var detail: String {
            switch self {
            case .unconfigured: "Bu pakete iCloud dağıtım profili henüz eklenmedi."
            case .stopped: "Bu Mac’e iPhone’dan bağlanmak için erişimi aç."
            case .starting: "MacCommand bağlantıyı hazırlıyor."
            case .connected: "Mac açık ve internete bağlıyken iPhone’undan erişebilirsin."
            case .waiting: "MacCommand bağlantıyı yeniden kurmayı deniyor."
            case .stopping: "Aktif bağlantılar kapatılıyor."
            case .error: "MacCommand’i yeniden başlatmayı dene."
            case .alreadyRunning: "MacCommand’in başka bir kopyasını veya eski servisini kapat."
            }
        }

        var color: Color {
            switch self {
            case .connected: .green
            case .waiting, .starting, .stopping: .orange
            case .error, .alreadyRunning: .red
            case .unconfigured, .stopped: .secondary
            }
        }
    }

    private struct Event: Decodable {
        let event: String
        let status: Status?
        let pairing: String?
        let registration: String?
        let device_id: String?
        let id: String?
        let paths: [String]?
    }

    private let relay = Bundle.main.object(forInfoDictionaryKey: "MacCommandRelayURL") as? String ?? ""
    private let cloudEnabled = Bundle.main.object(forInfoDictionaryKey: "MacCommandCloudEnabled") as? Bool == true
    private(set) var cloudIssue: String?
    @ObservationIgnored private var cloudPoll: Task<Void, Never>?
    @ObservationIgnored private var cloudJobs: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var cloudReplies: [String: [String]] = [:]
    @ObservationIgnored private var cloudGeneration = UUID()
    private(set) var status: Status = .stopped
    private(set) var pairing: String?
    private(set) var registration: String?
    private(set) var active = false
    private(set) var loginEnabled = SMAppService.mainApp.status == .enabled
    private(set) var loginError: String?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: Pipe?
    @ObservationIgnored private var restart = false
    @ObservationIgnored private var rotationOnly = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pending = Data()

    private var stateDirectory: URL {
        #if DEBUG
        if relay.hasPrefix("http://127.0.0.1:"), let path = ProcessInfo.processInfo.environment["MACCOMMAND_TEST_STATE"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacCommand", isDirectory: true)
    }

    private var rotationMarker: URL { stateDirectory.appendingPathComponent("rotate.pending") }

    var canRenew: Bool { (cloudEnabled || !relay.isEmpty) && ![.stopping, .starting, .unconfigured].contains(status) }

    func launch() {
        guard !started else { return }
        started = true
        let enabled = UserDefaults.standard.object(forKey: "remoteAccessEnabled") as? Bool != false
        if enabled || FileManager.default.fileExists(atPath: rotationMarker.path) { start(connect: enabled) }
    }

    func start(connect: Bool = true) {
        guard process == nil else { return }
        guard cloudEnabled || !relay.isEmpty else { status = .unconfigured; return }
        let child = Process()
        child.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MacCommandService")
        child.arguments = (cloudEnabled ? ["--cloud"] : ["--relay-url", relay]) + (connect ? [] : ["--rotate-only"])
        #if DEBUG
        if relay.hasPrefix("http://127.0.0.1:") {
            child.arguments?.append("--loopback-test")
            child.arguments?.append(contentsOf: ["--state-dir", stateDirectory.path])
        }
        #endif
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"].contains(key)
        }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        child.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice

        let (events, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(32))
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(bytes)
            }
        }
        child.terminationHandler = { [weak self] ended in
            Task { @MainActor in self?.didExit(ended) }
        }

        pending.removeAll()
        pairing = nil
        status = .starting
        do {
            try child.run()
            process = child
            input = stdin
            active = connect
            rotationOnly = !connect
            if connect { UserDefaults.standard.set(true, forKey: "remoteAccessEnabled") }
            Task { [weak self] in
                for await bytes in events {
                    guard let self, self.process === child else { break }
                    self.receive(bytes)
                }
            }
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            status = .error
        }
    }

    private func receive(_ bytes: Data) {
        guard status != .stopping else { return }
        pending.append(bytes)
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline])
            pending.removeFirst(line.count + 1)
            guard let value = try? JSONDecoder().decode(Event.self, from: line) else { continue }
            if value.event == "ready" {
                pairing = value.pairing
                registration = value.registration
                if cloudEnabled, active, let deviceID = value.device_id { startCloud(deviceID) }
            } else if value.event == "job", let id = value.id, cloudJobs[id] != nil {
                cloudReplies[id] = value.paths ?? []
            } else if value.event == "paired" {
                pairing = nil
            } else if let status = value.status {
                self.status = status
            }
        }
        if pending.count > 16_384 { pending.removeAll() }
    }

    private func didExit(_ child: Process) {
        guard process === child else { return }
        stopCloud()
        let intentional = status == .stopping
        try? input?.fileHandleForWriting.close()
        input = nil
        process = nil
        active = false
        pairing = nil
        if intentional || (rotationOnly && child.terminationStatus == 0) {
            status = .stopped
        } else if child.terminationStatus == 2 {
            status = .alreadyRunning
        } else {
            status = .error
        }
        if restart {
            restart = false
            start()
        }
    }

    func renew() {
        guard canRenew else { return }
        do {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try Data().write(to: rotationMarker, options: .atomic)
        } catch {
            status = .error
            return
        }
        if process != nil {
            restart = active
            closeChild()
        } else {
            start(connect: false)
        }
    }

    func stop(quitting: Bool = false) {
        if !quitting { UserDefaults.standard.set(false, forKey: "remoteAccessEnabled") }
        restart = false
        closeChild(quitting: quitting)
    }

    private func closeChild(quitting: Bool = false) {
        guard let child = process else { return }
        stopCloud()
        status = .stopping
        pairing = nil
        try? input?.fileHandleForWriting.close()
        if !quitting {
            Task {
                try? await Task.sleep(for: .seconds(5))
                if process === child, child.isRunning { child.terminate() }
            }
        }
    }

    private func startCloud(_ deviceID: String) {
        guard cloudPoll == nil else { return }
        let mailbox = CloudMailbox(deviceID: deviceID)
        let generation = cloudGeneration
        cloudPoll = Task { [weak self] in
            var prepared = false
            var nextPurge = ContinuousClock.now
            while !Task.isCancelled, let self, self.cloudGeneration == generation {
                do {
                    if !prepared {
                        try await mailbox.prepare()
                        prepared = true
                    }
                    let ids = try await mailbox.queued()
                    try Task.checkCancellation()
                    status = .connected
                    cloudIssue = nil
                    for id in ids where cloudJobs.count < 8 && cloudJobs[id.recordName] == nil {
                        cloudJobs[id.recordName] = Task { [weak self] in
                            await self?.processCloudJob(id, mailbox: mailbox, generation: generation)
                        }
                    }
                    if ContinuousClock.now >= nextPurge {
                        try? await mailbox.purgeExpired()
                        nextPurge = ContinuousClock.now.advanced(by: .seconds(600))
                    }
                    try await Task.sleep(for: .seconds(4))
                } catch {
                    guard !Task.isCancelled else { return }
                    prepared = false
                    status = .waiting
                    cloudIssue = CloudMailbox.explain(error).localizedDescription
                    let retry = max(4, (error as? CKError)?.retryAfterSeconds ?? 8)
                    try? await Task.sleep(for: .seconds(retry))
                }
            }
        }
    }

    private func stopCloud() {
        cloudGeneration = UUID()
        cloudPoll?.cancel()
        cloudPoll = nil
        for task in cloudJobs.values { task.cancel() }
        cloudJobs.removeAll()
        cloudReplies.removeAll()
        cloudIssue = nil
    }

    private func processCloudJob(_ recordID: CKRecord.ID, mailbox: CloudMailbox, generation: UUID) async {
        let id = recordID.recordName
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            if generation == cloudGeneration {
                cloudJobs[id] = nil
                cloudReplies[id] = nil
            }
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard let (record, files) = try await mailbox.take(recordID, folder: folder) else { return }
            try Task.checkCancellation()
            guard generation == cloudGeneration, let input else { return }
            let message: [String: Any] = ["id": id, "paths": files.map(\.path), "folder": folder.path]
            var line = try JSONSerialization.data(withJSONObject: message)
            line.append(10)
            try input.fileHandleForWriting.write(contentsOf: line)
            let deadline = ContinuousClock.now.advanced(by: .seconds(360))
            while cloudReplies[id] == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            try Task.checkCancellation()
            let expected = (0..<2).map { folder.appendingPathComponent("reply-\($0).packet") }
            let paths = (cloudReplies[id] ?? []).compactMap { path in expected.first { $0.path == path } }
            try await mailbox.finish(record, assets: paths)
        } catch {
            // A claimed job is never put back in the queue after an ambiguous failure.
        }
    }

    func setLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval {
                loginError = "Sistem Ayarları’ndan MacCommand’in oturum açma iznini onayla."
            }
        } catch {
            loginError = "Bu ayarı değiştirmek için MacCommand’i Uygulamalar klasöründen aç."
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var companion: Companion?
    func applicationWillTerminate(_ notification: Notification) {
        companion?.stop(quitting: true)
    }
}

private struct CompanionView: View {
    let companion: Companion
    @State private var showCode = false
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 31, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 56, height: 56)
                    .background(.tint.opacity(0.10), in: .rect(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MacCommand").font(.title2.weight(.semibold))
                    Text(Host.current().localizedName ?? "Bu Mac")
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Label(companion.status.title, systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.headline)
                    .foregroundStyle(companion.status.color)
                Text(companion.cloudIssue ?? companion.status.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if companion.active {
                    if companion.status == .connected && companion.pairing == nil {
                        Label("iPhone eşleşti", systemImage: "checkmark.iphone")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("iPhone eşleştir", systemImage: "qrcode") { showCode = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(companion.status != .connected || companion.pairing == nil)
                    }
                    Button("Erişimi kapat") { companion.stop() }
                        .disabled(companion.status == .stopping)
                } else {
                    Button("Erişimi aç") { companion.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled([.unconfigured, .starting, .stopping].contains(companion.status))
                }
                Spacer(minLength: 0)
            }
            HStack {
                if companion.status == .waiting, let registration = companion.registration {
                    Button("Beta kayıt bilgisini kopyala") { copy(registration) }
                }
                Spacer()
                Menu {
                    Button("Eşleştirmeyi yenile…") { confirmReset = true }
                        .disabled(!companion.canRenew)
                    SettingsLink { Text("Ayarlar…") }
                } label: {
                    Label("Seçenekler", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("MacCommand seçenekleri")
            }
        }
        .padding(26)
        .frame(width: 424)
        .sheet(isPresented: $showCode) {
            if let code = companion.pairing {
                PairingView(code: code) { showCode = false }
            }
        }
        .onChange(of: companion.pairing) { _, code in
            if code == nil { showCode = false }
        }
        .confirmationDialog("Eşleştirme yenilensin mi?", isPresented: $confirmReset) {
            Button("Yenile", role: .destructive) { companion.renew() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Eski iPhone’un erişimi kapanır. iPhone’da yeni QR kodunu taraman gerekir.")
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct PairingView: View {
    let code: String
    let dismiss: () -> Void

    private var qr: CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8)
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("iPhone’unu eşleştir").font(.title2.weight(.semibold))
            Text("iPhone’da MacCommand’i aç ve QR kodunu tara.")
                .foregroundStyle(.secondary)
            if let qr {
                Image(decorative: qr, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 236, height: 236)
                    .padding(12)
                    .background(.white, in: .rect(cornerRadius: 12))
                    .accessibilityLabel("MacCommand eşleştirme kodu")
                    .privacySensitive()
            }
            Text("Bu kod tek kullanımlıktır ve Mac’ine erişim verir.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Eşleştirme metnini kopyala") { copy(code) }
                Button("Bitti", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 424)
    }
}

@main
struct MacCommandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @State private var companion = Companion()

    var body: some Scene {
        Window("MacCommand", id: "main") {
            CompanionView(companion: companion)
                .task {
                    delegate.companion = companion
                    companion.launch()
                }
        }
        .windowResizability(.contentSize)
        MenuBarExtra("MacCommand", systemImage: "desktopcomputer") {
            Text(companion.status.title)
            Button("MacCommand’i aç") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            if companion.active {
                Button("Erişimi kapat") { companion.stop() }.disabled(companion.status == .stopping)
            } else if companion.status != .unconfigured {
                Button("Erişimi aç") { companion.start() }
            }
            Divider()
            Button("Çıkış") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        Settings {
            Form {
                Toggle("Oturum açınca MacCommand’i başlat",
                       isOn: Binding(get: { companion.loginEnabled }, set: { companion.setLogin($0) }))
                if let error = companion.loginError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
                LabeledContent("Sürüm", value: "3.1")
            }
            .formStyle(.grouped)
            .frame(width: 410)
        }
    }
}
