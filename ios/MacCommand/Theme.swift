import SwiftUI

extension Int64 {
    var byteLabel: String { formatted(.byteCount(style: .binary).locale(Locale(identifier: "en_US"))) }
}

struct ConnectionStatus: View {
    @Environment(Session.self) private var session
    var body: some View {
        Label {
            Text(session.status)
        } icon: {
            Circle().fill(session.discovery == nil ? Color.secondary : Color.green)
                .frame(width: 7, height: 7)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

struct ErrorNotice: View {
    let message: String
    let retry: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.subheadline).foregroundStyle(.primary)
            if let retry { Button("Try Again", action: retry).frame(minHeight: 44) }
        }
        .accessibilityElement(children: .contain)
    }
}
