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
                        Text(session.discovery?.name ?? "Your Mac").font(.headline)
                        ConnectionStatus()
                    }
                    Spacer(minLength: 0)
                    if session.connecting { ProgressView().accessibilityLabel("Connecting to Mac") }
                }
                .padding(.vertical, 12)
            }
            if let message = session.message {
                Section { ErrorNotice(message: message, retry: { Task { await session.reconnect() } }) }
            }
            if let metrics = session.metrics {
                Section {
                    MeterRow(title: "CPU", value: metrics.cpuPercent,
                             detail: "Current CPU usage", symbol: "cpu")
                    MeterRow(title: "Memory", value: metrics.ram.percent,
                             detail: "\(metrics.ram.used.byteLabel) / \(metrics.ram.total.byteLabel)", symbol: "memorychip")
                } header: { Text("Activity") }
                Section {
                    MeterRow(title: "Mac disk", value: metrics.disk.percent,
                             detail: "\(metrics.disk.free.byteLabel) free · \(metrics.disk.total.byteLabel) total", symbol: "internaldrive")
                } header: { Text("Storage") }
                if let battery = metrics.battery {
                    Section {
                        LabeledContent {
                            Text(battery.percent / 100, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().foregroundStyle(.primary)
                        } label: {
                            Label(battery.charging ? "Charging" : "On battery",
                                  systemImage: battery.charging ? "battery.100percent.bolt" : "battery.75percent")
                        }
                        if battery.secondsLeft > 0 && !battery.charging {
                            LabeledContent("Estimated time remaining", value: Duration.seconds(battery.secondsLeft)
                                .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated).locale(Locale(identifier: "en_US"))))
                        }
                    } header: { Text("Battery") }
                }
                Section {
                    if let date = session.lastUpdated {
                        Text("Last updated: \(date.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(Locale(identifier: "en_US"))))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if session.isDemo { Text("Showing sample data. This screen is not connected to your Mac.").font(.footnote).foregroundStyle(.secondary) }
                }
                .listRowBackground(Color.clear)
            } else if session.connecting {
                Section { HStack { ProgressView(); Text("Loading Mac information…").foregroundStyle(.secondary) } }
            } else {
                Section {
                    ContentUnavailableView("Connect to Your Mac", systemImage: "network",
                        description: Text("System information will appear here once connected."))
                    Button("Reconnect") { Task { await session.reconnect() } }
                }
            }
        }
        .navigationTitle("System")
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
