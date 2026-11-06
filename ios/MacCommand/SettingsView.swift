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
                    LabeledContent("Mac", value: session.discovery?.name ?? "Bağlantı bekleniyor")
                    ConnectionStatus()
                    Button("Yeniden bağlan") { Task { await session.reconnect() } }.disabled(session.connecting || session.isDemo)
                } header: { Text("Bağlantı") }
                Section {
                    Label("Terminal ve dosya aktarımları Face ID veya cihaz parolasıyla korunur.", systemImage: "faceid")
                    Label("Anahtar bu iPhone’un güvenli deposunda saklanır.", systemImage: "lock.shield")
                    Text("Mac’ine erişim, Mac’teki kullanıcı hesabının izinleriyle sınırlıdır. Mac uyurken veya internete bağlı değilken bağlantı kurulamaz.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } header: { Text("Erişim") }
                Section {
                    Button("Eşleştirmeyi kaldır", role: .destructive) { confirm = true }
                } footer: {
                    Text("Bu işlem yalnızca bu iPhone’daki anahtarı kaldırır. Kayıp bir telefonun erişimini iptal etmek için Mac’te eşleştirme anahtarını yenile.")
                }
                if let error { Section { ErrorNotice(message: error, retry: nil) } }
                Section { LabeledContent("MacCommand", value: "3.1") }
            }
            .navigationTitle("Ayarlar").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } } }
            .confirmationDialog("Bu iPhone’un eşleştirmesi kaldırılsın mı?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Eşleştirmeyi kaldır", role: .destructive) {
                    do { try session.forget(); dismiss() }
                    catch { self.error = Session.describe(error) }
                }
                Button("Vazgeç", role: .cancel) {}
            }
        }
    }
}
