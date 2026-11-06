import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @Environment(Session.self) private var session
    @State private var text = ""
    @State private var scanner = false
    @State private var scannedText: String?
    @State private var manual = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 64, weight: .light)).padding(.top, 40).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Mac’in,\nelinin altında.").font(.largeTitle.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                        Text("Sistemini kontrol et, bir komut çalıştır veya dosyalarına ulaş. İlk bağlantı için Mac’inle bir kez eşleştir.")
                            .font(.body).foregroundStyle(.secondary).lineSpacing(3)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Mac’te MacCommand uygulamasını aç.", systemImage: "desktopcomputer")
                        Label("Mac’teki eşleştirme kodunu tara.", systemImage: "qrcode.viewfinder")
                        Label("Mac ve iPhone’da aynı iCloud hesabını kullan.", systemImage: "checkmark.shield")
                    }
                    .font(.subheadline)
                    VStack(spacing: 12) {
                        Button { requestCamera() } label: {
                            Label("QR kodu tara", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity, minHeight: 36)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                        Button("Eşleştirme bilgisini yapıştır") { manual = true }
                            .frame(minHeight: 44)
                    }
                    if let error = error ?? session.storageError { ErrorNotice(message: error, retry: nil) }
                    Text("Eşleştirme kodu Mac’ine yönetim erişimi verir. Yalnızca kendi Mac’indeki kodu kullan ve kimseyle paylaşma.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28).padding(.bottom, 32)
            }
            .navigationTitle("MacCommand").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $scanner, onDismiss: {
                if let scannedText {
                    text = scannedText
                    self.scannedText = nil
                    manual = true
                }
            }) {
                NavigationStack {
                    ScannerView { value in
                        scannedText = value
                        scanner = false
                    }
                    .overlay(alignment: .bottom) {
                        Text("Mac’teki eşleştirme QR kodunu çerçeveye al.")
                            .padding().background(.regularMaterial).clipShape(.rect(cornerRadius: 14)).padding()
                    }
                    .navigationTitle("QR kodu tara").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { scanner = false } } }
                }
            }
            .sheet(isPresented: $manual) {
                NavigationStack {
                    Form {
                        Section {
                            TextField("Mac’teki eşleştirme metni", text: $text, axis: .vertical)
                                .lineLimit(5...10).font(.body.monospaced())
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .privacySensitive()
                        } header: { Text("Eşleştirme bilgisi") }
                        footer: { Text("Mac uygulamasındaki eşleştirme metninin tamamını yapıştır.") }
                        if let error { Section { ErrorNotice(message: error, retry: nil) } }
                        Section {
                            Button {
                                busy = true
                                error = nil
                                Task {
                                    defer { busy = false }
                                    do { try await session.pair(text); text = ""; manual = false }
                                    catch { self.error = Session.describe(error) }
                                }
                            } label: {
                                HStack { Text("Mac’e bağlan"); Spacer(); if busy { ProgressView() } }
                            }.disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .navigationTitle("Mac’inle eşleştir").navigationBarTitleDisplayMode(.inline)
                    .interactiveDismissDisabled(busy)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { text = ""; error = nil; manual = false }.disabled(busy) } }
                }
            }
        }
    }
    private func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                if granted { scanner = true }
                else { error = "Kamera izni kapalı. Ayarlar’dan izin verebilir veya eşleştirme bilgisini yapıştırabilirsin." }
            }
        }
    }
}
