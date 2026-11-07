import UIKit
import SwiftUI
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private var temporaryFolder: URL?
    override func viewDidLoad() {
        super.viewDidLoad()
        Task {
            do {
                let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
                let providers = items.flatMap { $0.attachments ?? [] }
                guard providers.count == 1, let provider = providers.first else {
                    throw MacError.http(400,"Select one file or photo at a time.")
                }
                let file = try await sharedFile(provider)
                temporaryFolder = file.deletingLastPathComponent()
                self.presentRoot(ShareUploadView(file: file, close: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }))
            } catch {
                self.presentRoot(ShareFailure(message: error is MacError ? error.localizedDescription : "Could not open the shared file. Try sharing it again.", close: { [weak self] in
                    self?.extensionContext?.cancelRequest(withError: error)
                }))
            }
        }
    }
    deinit { if let temporaryFolder { try? FileManager.default.removeItem(at: temporaryFolder) } }
    private func presentRoot<V: View>(_ root: V) {
        let controller = UIHostingController(rootView: root.environment(\.locale, Locale(identifier: "en_US")).tint(.indigo))
        addChild(controller)
        view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor), controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        controller.didMove(toParent: self)
    }
    private func sharedFile(_ provider: NSItemProvider) async throws -> URL {
        let name = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            let receive: @Sendable (URL?, Error?) -> Void = { file, error in
                guard let file else { continuation.resume(throwing: error ?? MacError.invalidResponse); return }
                do { continuation.resume(returning: try copySharedFile(file, suggestedName: name)) }
                catch { continuation.resume(throwing: error) }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item,error in receive(item as? URL,error) }
            } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) {
                provider.loadFileRepresentation(forTypeIdentifier: type, completionHandler: receive)
            } else { continuation.resume(throwing: MacError.http(415,"This share does not contain a file.")) }
        }
    }
}

private func copySharedFile(_ file: URL, suggestedName: String?) throws -> URL {
    let scoped = file.startAccessingSecurityScopedResource()
    defer { if scoped { file.stopAccessingSecurityScopedResource() } }
    let values = try file.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey])
    guard values.isRegularFile == true, let size = values.fileSize, size <= APIClient.transferLimit else {
        throw MacError.http(413,"Select a single regular file up to 50 MiB.")
    }
    var name = ((suggestedName ?? file.lastPathComponent) as NSString).lastPathComponent
    if (name as NSString).pathExtension.isEmpty && !file.pathExtension.isEmpty { name += "." + file.pathExtension }
    guard !name.isEmpty, name != ".", name != ".." else { throw MacError.invalidResponse }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let target = folder.appendingPathComponent(name)
    do { try FileManager.default.copyItem(at: file, to: target) }
    catch { try? FileManager.default.removeItem(at: folder); throw error }
    return target
}

private struct ShareFailure: View {
    let message: String
    let close: () -> Void
    var body: some View {
        ContentUnavailableView { Label("Could not send file", systemImage:"exclamationmark.circle") }
        description: { Text(message) } actions: { Button("Close", action:close) }
    }
}

private struct ShareUploadView: View {
    let file: URL
    let close: () -> Void
    @State private var discovery: Discovery?
    @State private var directory = ""
    @State private var error: String?
    @State private var busy = false
    @State private var completed = false
    @State private var transferTask: Task<Void,Never>?
    private let api = APIClient()
    var body: some View {
        NavigationStack {
            Form {
                Section { Label(file.lastPathComponent, systemImage:"doc") }
                if let discovery {
                    Section("Destination Mac") {
                        Text(discovery.name)
                        TextField("Destination folder",text:$directory).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(busy)
                        Button("Downloads") { directory = (discovery.home as NSString).appendingPathComponent("Downloads") }.disabled(busy)
                        Button("Desktop") { directory = (discovery.home as NSString).appendingPathComponent("Desktop") }.disabled(busy)
                    }
                    Section {
                        if completed { Label("Sent to Mac",systemImage:"checkmark.circle") }
                        else {
                            Button {
                                busy=true; error=nil
                                transferTask=Task {
                                    defer { busy=false; transferTask=nil }
                                    do {
                                        try await DeviceLock.requireOwner("Verify your identity to send a file to your Mac.")
                                        try Task.checkCancellation()
                                        try await api.upload(file,directory:directory,discovery:discovery)
                                        completed=true
                                    } catch { if !Task.isCancelled { self.error=error is MacError ? error.localizedDescription : "The file could not be sent. Check the destination folder and connection, then try again." } }
                                }
                            } label: { HStack { Text("Send to Mac"); Spacer(); if busy { ProgressView() } } }.disabled(busy || !directory.hasPrefix("/"))
                        }
                    } footer: { Text("Send one file up to 50 MiB. Existing files are preserved. Face ID or your device passcode is required before sending.") }
                } else if error == nil { ProgressView("Finding your Mac…") }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Send to Mac").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button(completed ? "Done" : "Cancel") { transferTask?.cancel(); close() } } }
            .task {
                do {
                    guard let pairing = try PairingStore().load() else { throw MacError.http(401,"Open MacCommand and pair with your Mac first.") }
                    let value = try await api.discover(pairing)
                    discovery=value; directory=(value.home as NSString).appendingPathComponent("Downloads")
                } catch { self.error=error is MacError ? error.localizedDescription : "Could not connect to your Mac. Open MacCommand and check pairing." }
            }
        }
    }
}
