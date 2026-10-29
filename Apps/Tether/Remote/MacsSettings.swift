import AppKit
import SwiftUI
import TetherProtocol

/// Settings → Macs: pair another Mac running Tether and see, per Mac,
/// whether it's reachable right now.
struct MacsSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var link = ""
    @State private var error: String?

    var body: some View {
        let remote = model.remote
        Form {
            Section {
                TextField("tether://pair?…", text: $link)
                    .onSubmit(start)
                HStack {
                    Button("Paste and Pair") {
                        if let text = NSPasteboard.general.string(forType: .string) { link = text }
                        start()
                    }
                    Button("Pair", action: start)
                        .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if remote.pairing != nil {
                        Button("Cancel") { remote.cancelPairing() }
                    }
                }
                result(remote)
            } header: {
                Text("Add a Mac")
            } footer: {
                Text("On the other Mac: Tether → Settings → iPhone → Pair iPhone or Mac…, then Copy Link. "
                     + "Paste it here within two minutes. Both Macs need Tailscale on the same tailnet.")
            }
            Section("Paired Macs") {
                if remote.connections.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(remote.connections) { connection in
                    MacRow(connection: connection) { remote.remove(connection.id) }
                }
                if !remote.connections.isEmpty {
                    Button("Open Remote Macs") { openWindow(id: "remote-macs") }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            remote.retain()
            if link.isEmpty, let text = NSPasteboard.general.string(forType: .string),
               text.hasPrefix("tether://pair") {
                link = text
            }
        }
        .onDisappear { remote.release() }
    }

    @ViewBuilder
    private func result(_ remote: RemoteStore) -> some View {
        if let error {
            failure(error)
        } else if let pairing = remote.pairing {
            let place = "\(pairing.mac.host):\(pairing.mac.port)"
            switch pairing.status {
            case .rejected(let reason):
                failure("\(reason) Copy a new link on \(pairing.mac.name) and try again.")
            case .offline(let reason):
                failure("Couldn't reach \(pairing.mac.name) at \(place): \(reason). "
                        + "Check that Tether is open there and Tailscale is on for both Macs.")
            case .updateNeeded:
                failure("\(pairing.mac.name) runs a different version of Tether. Update both Macs, then try again.")
            case .connecting, .online:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to \(pairing.mac.name) at \(place)…")
                }
            }
        } else if let name = remote.lastPairedName {
            Label("Paired with \(name). It's connected.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private func failure(_ text: String) -> some View {
        Label(text, systemImage: "xmark.circle.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func start() {
        error = model.remote.pair(text: link, ownName: model.companion.macName)
        if error == nil { link = "" }
    }
}

private struct MacRow: View {
    let connection: MacConnection
    let forget: () -> Void
    @State private var confirmForget = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.mac.name)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(connection.status == .online ? Color.secondary : color)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(connection.mac.host):\(connection.mac.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Test") {
                connection.disconnect()
                connection.connect()
            }
            Button("Forget…", role: .destructive) { confirmForget = true }
        }
        .confirmationDialog("Forget \(connection.mac.name)?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive, action: forget)
        } message: {
            Text("To pair again, copy a new link from that Mac.")
        }
    }

    private var icon: String {
        switch connection.status {
        case .online: "checkmark.circle.fill"
        case .connecting: "circle.dotted"
        case .offline, .updateNeeded, .rejected: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch connection.status {
        case .online: .green
        case .connecting: .secondary
        case .offline, .updateNeeded, .rejected: .red
        }
    }

    private var detail: String {
        switch connection.status {
        case .online:
            let count = connection.snapshot?.sessions.count ?? 0
            return "Connected. \(count) Claude tab\(count == 1 ? "" : "s") open."
        case .connecting:
            return "Connecting…"
        case .offline(let reason):
            return "Can't reach it: \(reason). Is Tether open there and Tailscale on?"
        case .updateNeeded:
            return "Update Tether on both Macs to the same version."
        case .rejected(let reason):
            return "\(reason) Forget it and pair again."
        }
    }
}
