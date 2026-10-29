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
    @State private var justPaired: String?
    @State private var linkCopied = false

    var body: some View {
        let remote = model.remote
        let hub = model.companion
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
                Text("On the other Mac: Tether → Settings → Macs → Copy Pairing Link. "
                     + "Paste it here within two minutes. Both Macs need Tailscale on the same tailnet.")
            }
            Section {
                if let window = hub.pairing {
                    VStack(alignment: .leading, spacing: 6) {
                        if linkCopied {
                            Label("Link copied. Paste it on the other Mac: Settings → Macs → Paste and Pair.",
                                  systemImage: "doc.on.clipboard")
                        }
                        Text(window.link.url.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let left = max(0, Int(window.expires.timeIntervalSince(context.date)))
                            Text(left > 0 ? "Expires in \(left)s" : "Expired. Create a new link.")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Copy Again") { copy(window.link.url.absoluteString) }
                            Button("Done") {
                                hub.cancelPairing()
                                linkCopied = false
                            }
                        }
                    }
                } else {
                    Button("Copy Pairing Link") {
                        justPaired = nil
                        Task {
                            await hub.beginPairing()
                            if let window = hub.pairing {
                                copy(window.link.url.absoluteString)
                                linkCopied = true
                            }
                        }
                    }
                    .disabled(hub.tailnetAddress == nil || hub.problem != nil)
                }
                if let justPaired {
                    Label("\(justPaired) paired.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if let problem = hub.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if let address = hub.tailnetAddress {
                    Text("Other Macs reach this one over Tailscale at \(address):\(hub.port).")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Tailscale isn't running on this Mac.", systemImage: "network.slash")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Let another Mac pair with this one")
            } footer: {
                Text("Copies a one-time link. On the other Mac open Settings → Macs and click Paste and Pair within two minutes.")
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
            hub.refreshAddress()
            remote.retain()
            if link.isEmpty, let text = NSPasteboard.general.string(forType: .string),
               text.hasPrefix("tether://pair") {
                link = text
            }
        }
        .onDisappear { remote.release() }
        .onChange(of: hub.devices.count) { old, new in
            if hub.pairing != nil, new > old { justPaired = hub.devices.last?.name }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
