import SwiftUI

struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Mac", value: session.discovery?.name ?? "Waiting for connection")
                    ConnectionStatus()
                    Button("Reconnect") { Task { await session.reconnect() } }.disabled(session.connecting || session.isDemo)
                } header: { Text("Connection") }
                Section {
                    Label("The terminal and file transfers require Face ID or your device passcode.", systemImage: "faceid")
                    Label("Your key is kept in this iPhone’s secure storage.", systemImage: "lock.shield")
                    Text("Access uses the permissions of your Mac user account. Your Mac must be awake and online.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } header: { Text("Access") }
                Section {
                    Button("Remove Pairing", role: .destructive) { confirm = true }
                } footer: {
                    Text("This removes the key from this iPhone. To revoke a lost phone’s access, reset pairing on your Mac.")
                }
                if let error { Section { ErrorNotice(message: error, retry: nil) } }
                Section { LabeledContent("MacCommand", value: "3.1.1") }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Remove pairing from this iPhone?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Remove Pairing", role: .destructive) {
                    do { try session.forget(); dismiss() }
                    catch { self.error = Session.describe(error) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
