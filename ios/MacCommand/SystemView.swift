import SwiftUI

struct SystemView: View {
    @Environment(Session.self) private var session
    var body: some View {
        List {
            Section {
                HStack(alignment: .center, spacing: 18) {
                    Image(systemName: "desktopcomputer").font(.largeTitle)
                        .foregroundStyle(.primary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.discovery?.name ?? "Mac’in").font(.headline)
                        ConnectionStatus()
                    }
                    Spacer(minLength: 0)
                    if session.connecting { ProgressView().accessibilityLabel("Mac’e bağlanılıyor") }
                }
                .padding(.vertical, 12)
            }
            if let message = session.message {
                Section { ErrorNotice(message: message, retry: { Task { await session.reconnect() } }) }
            }
            if let metrics = session.metrics {
                Section {
                    MeterRow(title: "İşlemci", value: metrics.cpuPercent,
                             detail: "Anlık CPU kullanımı", symbol: "cpu")
                    MeterRow(title: "Bellek", value: metrics.ram.percent,
                             detail: "\(metrics.ram.used.byteLabel) / \(metrics.ram.total.byteLabel)", symbol: "memorychip")
                } header: { Text("Etkinlik") }
                Section {
                    MeterRow(title: "Mac diski", value: metrics.disk.percent,
                             detail: "\(metrics.disk.free.byteLabel) boş · \(metrics.disk.total.byteLabel) toplam", symbol: "internaldrive")
                } header: { Text("Depolama") }
                if let battery = metrics.battery {
                    Section {
                        LabeledContent {
                            Text(battery.percent / 100, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().foregroundStyle(.primary)
                        } label: {
                            Label(battery.charging ? "Şarj oluyor" : "Pille çalışıyor",
                                  systemImage: battery.charging ? "battery.100percent.bolt" : "battery.75percent")
                        }
                        if battery.secondsLeft > 0 && !battery.charging {
                            LabeledContent("Tahmini kalan", value: Duration.seconds(battery.secondsLeft)
                                .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        }
                    } header: { Text("Pil") }
                }
                Section {
                    if let date = session.lastUpdated {
                        Text("Son güncelleme: \(date.formatted(date: .omitted, time: .standard))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if session.isDemo { Text("Örnek veriler gösteriliyor. Bu ekran Mac’ine bağlı değil.").font(.footnote).foregroundStyle(.secondary) }
                }
                .listRowBackground(Color.clear)
            } else if session.connecting {
                Section { HStack { ProgressView(); Text("Mac’in bilgileri alınıyor…").foregroundStyle(.secondary) } }
            } else {
                Section {
                    ContentUnavailableView("Mac’ine bağlan", systemImage: "network",
                        description: Text("Sistem bilgileri bağlantı kurulduğunda burada görünecek."))
                    Button("Yeniden bağlan") { Task { await session.reconnect() } }
                }
            }
        }
        .navigationTitle("Sistem")
        .refreshable { await session.reconnect(); await session.refreshMetrics() }
    }
}

private struct MeterRow: View {
    let title: String
    let value: Double
    let detail: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol).font(.body)
                Spacer()
                Text(value / 100, format: .percent.precision(.fractionLength(0)))
                    .font(.headline).monospacedDigit()
            }
            ProgressView(value: min(max(value, 0), 100), total: 100)
                .tint(value >= 90 ? .orange : .indigo).accessibilityHidden(true)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
