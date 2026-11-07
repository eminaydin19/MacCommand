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
                        Text("Your Mac,\nwithin reach.").font(.largeTitle.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                        Text("Check system status, run a command, or access your files. Pair with your Mac to get started.")
                            .font(.body).foregroundStyle(.secondary).lineSpacing(3)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Open MacCommand on your Mac.", systemImage: "desktopcomputer")
                        Label("Scan the pairing code on your Mac.", systemImage: "qrcode.viewfinder")
                        Label("Use the same iCloud account on both devices.", systemImage: "checkmark.shield")
                    }
                    .font(.subheadline)
                    VStack(spacing: 12) {
                        Button { requestCamera() } label: {
                            Label("Scan QR Code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity, minHeight: 36)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                        Button("Paste Pairing Code") { manual = true }
                            .frame(minHeight: 44)
                    }
                    if let error = error ?? session.storageError { ErrorNotice(message: error, retry: nil) }
                    Text("The pairing code grants access to your Mac. Only use a code from your own Mac and keep it private.")
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
                        Text("Place your Mac’s pairing QR code in the frame.")
                            .padding().background(.regularMaterial).clipShape(.rect(cornerRadius: 14)).padding()
                    }
                    .navigationTitle("Scan QR Code").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanner = false } } }
                }
            }
            .sheet(isPresented: $manual) {
                NavigationStack {
                    Form {
                        Section {
                            TextField("Pairing code from your Mac", text: $text, axis: .vertical)
                                .lineLimit(5...10).font(.body.monospaced())
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .privacySensitive()
                        } header: { Text("Pairing Code") }
                        footer: { Text("Paste the complete pairing code from the Mac app.") }
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
                                HStack { Text("Connect to Mac"); Spacer(); if busy { ProgressView() } }
                            }.disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .navigationTitle("Pair with Your Mac").navigationBarTitleDisplayMode(.inline)
                    .interactiveDismissDisabled(busy)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { text = ""; error = nil; manual = false }.disabled(busy) } }
                }
            }
        }
    }
    private func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                if granted { scanner = true }
                else { error = "Camera access is disabled. Allow it in Settings or paste the pairing code." }
            }
        }
    }
}
