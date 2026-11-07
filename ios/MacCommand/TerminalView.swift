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
                    Label("Terminal locked", systemImage: "lock.shield")
                } description: {
                    Text(authError ?? "Verify your identity to access commands and output.")
                } actions: {
                    Button { unlock() } label: { Label("Unlock with Face ID", systemImage: "faceid") }
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
                Form { TextField("Working Directory", text: $cwd).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    .navigationTitle("Working Directory").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDirectory = false } } }
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
                            Text("Start with a command.").font(.title2.weight(.semibold))
                            Text(session.usesCloudKit ? "Output appears when the command finishes. Stop requests may take time to reach your Mac." : "See output as it arrives and stop a command when needed.").foregroundStyle(.secondary)
                            Text("Commands run under your Mac account with a five-minute limit. Interactive input is unavailable.")
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
                                Text("The command may have run on your Mac. Check before sending it again.").font(.footnote).foregroundStyle(.secondary)
                            }
                            if entry.id == activeID { HStack { ProgressView(); Text(session.usesCloudKit ? "Waiting for results from Mac…" : "Running…").foregroundStyle(.secondary) } }
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
                Button("Clear History", systemImage: "eraser") { history.removeAll() }.disabled(history.isEmpty || running)
            }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { showDirectory = true } label: {
                    Label(cwd.isEmpty ? "Working Directory" : cwd, systemImage: "folder")
                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).frame(minHeight: 44)
                }.disabled(running)
                Spacer()
                if running { Button(session.usesCloudKit ? "Request Stop" : "Stop", systemImage: "stop.fill", role: .destructive) { stop() }.frame(minHeight: 44) }
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Enter a command", text: $command, axis: .vertical)
                    .font(.body.monospaced()).lineLimit(1...5).focused($editing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 12)).disabled(running)
                Button { run() } label: { Image(systemName: "arrow.up").font(.headline).frame(width: 44, height: 44) }
                    .buttonStyle(.borderedProminent).clipShape(.circle).accessibilityLabel("Run Command")
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
                            history[index].summary = event.cancelled == true ? "Command stopped." : event.timedOut == true ? "The five-minute time limit was reached." : event.truncated == true ? "The output limit was reached. The command was stopped." : "Exit code: \(event.returncode ?? -1)"
                        default: break
                        }
                    }
                }
            } catch {
                if let index = history.firstIndex(where: { $0.id == id }) {
                    if stopRequested || Task.isCancelled { history[index].summary = "Stopped waiting for results. Check the command’s status on your Mac." }
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
                if let index = history.firstIndex(where: { $0.id == id }) { history[index].error = "The stop request could not be confirmed. " + Session.describe(error) }
            }
        }
    }
}
