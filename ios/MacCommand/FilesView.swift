import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @Environment(Session.self) private var session
    let path: String
    @State private var listing: DirectoryListing?
    @State private var error: String?
    @State private var loading = false
    @State private var trashTarget: FileEntry?
    @State private var trashing = false
    @State private var query = ""
    @State private var importing = false
    @State private var transferStatus: String?
    @State private var transferTask: Task<Void, Never>?
    @State private var downloadURL: URL?
    @State private var showingShare = false
    @Environment(\.scenePhase) private var scenePhase
    private var isHome: Bool { path == session.discovery?.home || path == "~" }
    private var visible: [FileEntry] {
        (listing?.entries ?? []).filter { query.isEmpty || $0.name.localizedStandardContains(query) }
    }
    var body: some View {
        List {
            Section {
                ConnectionStatus()
                Text(listing?.path ?? path).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .listRowBackground(Color.clear)
            if let error { Section { ErrorNotice(message: error, retry: { Task { await load() } }) } }
            if loading && listing == nil {
                HStack { ProgressView(); Text("Loading folder…").foregroundStyle(.secondary) }
            }
            if isHome && !session.favoriteFolders.isEmpty {
                Section("Favorites") {
                    ForEach(session.favoriteFolders) { folder in
                        NavigationLink { FilesView(path: folder.path) } label: {
                            Label(folder.name, systemImage: "star").foregroundStyle(.primary)
                        }
                        .contextMenu { Button("Remove from Favorites", systemImage: "star.slash") { toggleFavorite(folder.path, name: folder.name) } }
                    }
                }
            }
            Section {
                ForEach(visible) { file in
                    Group {
                        if file.isDir {
                            NavigationLink { FilesView(path: file.path) } label: { FileRow(file: file) }
                        } else {
                            NavigationLink { FilePreview(path: file.path, download: { startDownload(file.path) }) } label: { FileRow(file: file) }
                        }
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Trash", systemImage: "trash", role: .destructive) { trashTarget = file }
                            .disabled(trashing || session.isDemo)
                    }
                    .contextMenu {
                        if file.isDir {
                            Button(session.favoriteFolders.contains(where: { $0.path == file.path }) ? "Remove from Favorites" : "Add to Favorites", systemImage: "star") { toggleFavorite(file.path, name: file.name) }
                        } else {
                            Button("Download to iPhone", systemImage: "arrow.down.to.line") { startDownload(file.path) }
                                .disabled(session.isDemo || transferStatus != nil)
                        }
                        ShareLink(item: file.path) { Label("Share Path", systemImage: "square.and.arrow.up") }
                        Button("Move to Trash", systemImage: "trash", role: .destructive) { trashTarget = file }
                            .disabled(trashing || session.isDemo)
                    }
                }
                if listing != nil && visible.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "This folder is empty" : "No results",
                        systemImage: query.isEmpty ? "folder" : "magnifyingglass",
                        description: Text(query.isEmpty ? "There are no files or folders to show." : "Try another file name."))
                }
            } header: { if let listing { Text("\(listing.entries.count) items") } }
        }
        .searchable(text: $query, prompt: "Search this folder")
        .navigationTitle(isHome ? "Files" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(isHome ? .large : .inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Toggle Favorite", systemImage: session.favoriteFolders.contains(where: { $0.path == listing?.path }) ? "star.fill" : "star") {
                    if let listing { toggleFavorite(listing.path, name: (listing.path as NSString).lastPathComponent) }
                }.disabled(listing == nil)
                Button("Send File to Mac", systemImage: "square.and.arrow.up") { importing = true }
                    .disabled(session.isDemo || listing == nil || transferStatus != nil)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let file): startUpload(file)
            case .failure(let error): self.error = Session.describe(error)
            }
        }
        .sheet(isPresented: $showingShare, onDismiss: {
            if let downloadURL { try? FileManager.default.removeItem(at: downloadURL.deletingLastPathComponent()) }
            downloadURL = nil
        }) {
            if let downloadURL { TransferSheet(file: downloadURL) }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { transferTask?.cancel() } }
        .refreshable { await load() }
        .task(id: "\(session.discovery?.pairing?.deviceID ?? "")-\(path)") { await load() }
        .confirmationDialog("Move to Trash?", isPresented: Binding(get: { trashTarget != nil }, set: { if !$0 { trashTarget = nil } }), titleVisibility: .visible) {
            if let target = trashTarget {
                Button("Move “\(target.name)”", role: .destructive) { Task { await trash(target) } }
            }
            Button("Cancel", role: .cancel) { trashTarget = nil }
        } message: { Text("You can restore it from the Trash on your Mac.") }
        .overlay {
            if trashing || transferStatus != nil {
                VStack(spacing: 12) {
                    ProgressView(transferStatus ?? "Moving to Trash…")
                    if transferStatus != nil { Button("Cancel") { transferTask?.cancel() }.frame(minHeight: 44) }
                }.padding(24).background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
        }
    }
    private func toggleFavorite(_ path: String, name: String) {
        do { try session.toggleFavorite(path, name: name) }
        catch { self.error = Session.describe(error) }
    }
    private func startUpload(_ file: URL) {
        guard let directory = listing?.path, transferStatus == nil else { return }
        transferStatus = "Sending to Mac…"
        transferTask = Task {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() }; transferStatus = nil; transferTask = nil }
            do { try await session.upload(file, directory: directory); await load() }
            catch { if !Task.isCancelled { self.error = "The transfer did not finish. Check the destination folder. " + Session.describe(error) } }
        }
    }
    private func startDownload(_ path: String) {
        guard transferStatus == nil else { return }
        transferStatus = "Downloading to iPhone…"
        transferTask = Task {
            defer { transferStatus = nil; transferTask = nil }
            do {
                let url = try await session.download(path)
                if Task.isCancelled { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()); return }
                downloadURL = url; showingShare = true
            } catch { if !Task.isCancelled { self.error = Session.describe(error) } }
        }
    }
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let value = try await session.files(path)
            try Task.checkCancellation()
            listing = value; error = nil
        } catch {
            if !Task.isCancelled { self.error = Session.describe(error) }
        }
    }
    private func trash(_ file: FileEntry) async {
        trashing = true
        defer { trashing = false; trashTarget = nil }
        do { try await session.trash(file.path); await load() }
        catch { self.error = Session.describe(error) }
    }
}

private struct FileRow: View {
    let file: FileEntry
    @ScaledMetric(relativeTo: .title3) private var iconWidth = 28
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: file.isSymlink ? "link" : file.isDir ? "folder.fill" : "doc.text")
                .font(.title3).foregroundStyle(file.isDir ? Color.indigo : .secondary).frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name).foregroundStyle(.primary).lineLimit(2)
                Text(file.isDir ? "Folder" : file.size.byteLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).accessibilityElement(children: .combine)
    }
}

private struct FilePreview: View {
    @Environment(Session.self) private var session
    let path: String
    let download: () -> Void
    @State private var content: String?
    @State private var error: String?
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            if let content {
                Text(content.isEmpty ? "The file is empty." : content).font(.callout.monospaced())
                    .textSelection(.enabled).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            } else if let error { ErrorNotice(message: error, retry: nil).padding(20) }
            else { ProgressView("Opening preview…").padding(20) }
        }
        .navigationTitle((path as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Download to iPhone", systemImage: "arrow.down.to.line", action: download).disabled(session.isDemo) } }
        .task {
            do { content = try await session.read(path).content }
            catch { if !Task.isCancelled { self.error = Session.describe(error) } }
        }
    }
}
