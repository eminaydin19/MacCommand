import SwiftUI

private struct CommandEntry: Identifiable {
    let id: String
    let command: String
    var stdout = ""
    var stderr = ""
    var summary: String?
    var error: String?
    let date = Date()
}

struct TerminalView: View {
    @Environment(Session.self) private var session
    @State private var command = ""
    @State private var cwd = ""
    @State private var history: [CommandEntry] = []
    @State private var activeID: String?
    @State private var stopRequested = false
    @State private var runningTask: Task<Void, Never>?
    @State private var showDirectory = false
    @State private var authenticating = false
    @State private var authError: String?
    @FocusState private var editing: Bool
    private var running: Bool { activeID != nil }
    var body: some View {
        Group {
            if session.deviceLock.terminalUnlocked { terminal }
            else {
                ContentUnavailableView {
                    Label("Terminal kilitli", systemImage: "lock.shield")
                } description: {
                    Text(authError ?? "Komutlarına ve çıktılara erişmek için kimliğini doğrula.")
                } actions: {
                    Button { unlock() } label: { Label("Face ID ile aç", systemImage: "faceid") }
                        .buttonStyle(.borderedProminent).disabled(authenticating)
                    if authenticating { ProgressView() }
                }
            }
        }
        .navigationTitle("Terminal")
        .onAppear { if cwd.isEmpty { cwd = session.discovery?.home ?? "~" } }
        .onChange(of: session.deviceLock.terminalUnlocked) { _, unlocked in
            if !unlocked { runningTask?.cancel() }
        }
        .onDisappear { runningTask?.cancel() }
        .sheet(isPresented: $showDirectory) {
            NavigationStack {
                Form { TextField("Çalışma dizini", text: $cwd).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    .navigationTitle("Çalışma dizini").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Bitti") { showDirectory = false } } }
            }.presentationDetents([.medium])
        }
    }
    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ConnectionStatus()
                    if history.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Image(systemName: "terminal").font(.largeTitle).accessibilityHidden(true)
                            Text("Bir komutla başla.").font(.title2.weight(.semibold))
                            Text("Çıktıyı anında gör. Gerektiğinde çalışan komutu durdur.").foregroundStyle(.secondary)
                            Text("Komutlar kendi Mac hesabınla çalışır. En fazla 5 dakika; etkileşimli terminal oturumu değildir.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }.padding(.top, 24)
                    }
                    ForEach(history) { entry in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.command).font(.body.monospaced().weight(.medium)).textSelection(.enabled)
                                Spacer(minLength: 12)
                                Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                            if !entry.stdout.isEmpty { Text(entry.stdout).font(.callout.monospaced()).textSelection(.enabled) }
                            if !entry.stderr.isEmpty { Text(entry.stderr).font(.callout.monospaced()).foregroundStyle(.red).textSelection(.enabled) }
                            if let summary = entry.summary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                            if let error = entry.error {
                                Text(error).font(.subheadline).foregroundStyle(.red)
                                Text("Komut Mac’te çalışmış olabilir. Kontrol etmeden yeniden gönderme.").font(.footnote).foregroundStyle(.secondary)
                            }
                            if entry.id == activeID { HStack { ProgressView(); Text(session.usesCloudKit ? "Mac’ten sonuç bekleniyor…" : "Çalışıyor…").foregroundStyle(.secondary) } }
                            Divider().padding(.top, 8)
                        }.id(entry.id)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            .onChange(of: history.last?.stdout.count) { _, _ in if let id = activeID { proxy.scrollTo(id, anchor: .bottom) } }
            .safeAreaInset(edge: .bottom) { composer }
        }
        .privacySensitive()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Geçmişi temizle", systemImage: "eraser") { history.removeAll() }.disabled(history.isEmpty || running)
            }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { showDirectory = true } label: {
                    Label(cwd.isEmpty ? "Çalışma dizini" : cwd, systemImage: "folder")
                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).frame(minHeight: 44)
                }.disabled(running)
                Spacer()
                if running { Button(session.usesCloudKit ? "Durdurma isteği" : "Durdur", systemImage: "stop.fill", role: .destructive) { stop() }.frame(minHeight: 44) }
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Komut yaz", text: $command, axis: .vertical)
                    .font(.body.monospaced()).lineLimit(1...5).focused($editing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 12)).disabled(running)
                Button { run() } label: { Image(systemName: "arrow.up").font(.headline).frame(width: 44, height: 44) }
                    .buttonStyle(.borderedProminent).clipShape(.circle).accessibilityLabel("Komutu çalıştır")
                    .disabled(running || session.discovery == nil || session.isDemo || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(.horizontal, 20).padding(.bottom, 12).background(.bar)
    }
    private func unlock() {
        authenticating = true; authError = nil
        Task {
            defer { authenticating = false }
            do { try await session.deviceLock.unlockTerminal() }
            catch { authError = Session.describe(error) }
        }
    }
    private func run() {
        let value = command
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        command = ""; editing = false; stopRequested = false; activeID = id
        if history.count >= 30 { history.removeFirst() }
        history.append(.init(id: id, command: value))
        runningTask = Task {
            defer { activeID = nil; runningTask = nil }
            do {
                try await session.stream(value, cwd: cwd, id: id) { event in
                    await MainActor.run {
                        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
                        switch event.type {
                        case "stdout": history[index].stdout += event.text ?? ""
                        case "stderr": history[index].stderr += event.text ?? ""
                        case "exit":
                            history[index].summary = event.cancelled == true ? "Komut durduruldu." : event.timedOut == true ? "5 dakikalık süre sınırı aşıldı." : event.truncated == true ? "Çıktı sınırına ulaşıldı; komut durduruldu." : "Çıkış kodu: \(event.returncode ?? -1)"
                        default: break
                        }
                    }
                }
            } catch {
                if let index = history.firstIndex(where: { $0.id == id }) {
                    if stopRequested || Task.isCancelled { history[index].summary = "Sonuç bekleme durdu. Komutun durumunu Mac’te kontrol et." }
                    else { history[index].error = Session.describe(error) }
                }
            }
        }
    }
    private func stop() {
        guard let id = activeID else { return }
        stopRequested = true
        runningTask?.cancel()
        Task {
            do { try await session.stop(id) }
            catch MacError.http(let status, _) where status == 404 { }
            catch {
                if let index = history.firstIndex(where: { $0.id == id }) { history[index].error = "Durdurma onayı alınamadı. " + Session.describe(error) }
            }
        }
    }
}
