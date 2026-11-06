import SwiftUI

@main struct MacCommandApp: App {
    @State private var session = Session()
    var body: some Scene {
        WindowGroup { RootView().environment(session).tint(.indigo) }
    }
}

struct RootView: View {
    @Environment(Session.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = false
    var body: some View {
        @Bindable var session = session
        Group {
            if session.hasPairing {
                TabView(selection: $session.selectedTab) {
                    NavigationStack { SystemView().toolbar { settingsButton } }
                        .tabItem { Label("Sistem", systemImage: "desktopcomputer") }.tag(0)
                    NavigationStack { TerminalView().toolbar { settingsButton } }
                        .tabItem { Label("Terminal", systemImage: "terminal") }.tag(1)
                    NavigationStack { FilesView(path: session.discovery?.home ?? "~").toolbar { settingsButton } }
                        .tabItem { Label("Dosyalar", systemImage: "folder") }.tag(2)
                }
            } else {
                OnboardingView()
            }
        }
        .onChange(of: session.selectedTab) { old, new in
            if old == 1 && new != 1 { session.deviceLock.lock() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.deviceLock.lock() }
        }
        .sheet(isPresented: $settings) { SettingsView() }
        .task { await session.resumePendingPairing() }
        .task(id: "\(scenePhase)-\(session.hasPairing)-\(session.selectedTab)") {
            guard scenePhase == .active, session.hasPairing else { return }
            while !Task.isCancelled {
                if session.discovery == nil { await session.reconnect() }
                if session.selectedTab == 0 { await session.refreshMetrics() }
                else { await session.checkConnection() }
                do { try await Task.sleep(for: .seconds(session.usesCloudKit ? 20 : (session.discovery == nil || session.selectedTab != 0 ? 8 : 3))) }
                catch { return }
            }
        }
    }
    private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Ayarlar", systemImage: "gearshape") { settings = true }
        }
    }
}
