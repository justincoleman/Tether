import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import TetherCore

/// Settings → iPhone: pair a phone with a QR code, see and revoke paired phones.
struct PhoneSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hub = model.companion
        VStack(alignment: .leading, spacing: 14) {
            status(hub)
            if let pairing = hub.pairing {
                PairingCard(window: pairing) { hub.cancelPairing() }
            } else {
                Button("Pair iPhone…") { Task { await hub.beginPairing() } }
                    .disabled(hub.tailnetAddress == nil || hub.problem != nil)
            }
            Divider()
            Text("Paired iPhones").font(.headline)
            if hub.devices.isEmpty {
                Text("None yet.").foregroundStyle(.secondary)
            } else {
                ForEach(hub.devices) { device in
                    HStack {
                        Circle()
                            .fill(hub.connectedDeviceIds.contains(device.id) ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(device.lastSeen.map { "Last seen \($0.formatted(.relative(presentation: .named)))" }
                                 ?? "Never connected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { hub.revoke(device.id) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .onAppear { hub.refreshAddress() }
    }

    @ViewBuilder
    private func status(_ hub: CompanionHub) -> some View {
        if let problem = hub.problem {
            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        } else if let address = hub.tailnetAddress {
            Label("Phones connect over Tailscale at \(address):\(hub.port).", systemImage: "checkmark.shield")
                .foregroundStyle(.secondary)
        } else {
            Label("Tailscale isn't running on this Mac. Install it on the Mac and the iPhone and sign both into the same tailnet, then reopen this tab.",
                  systemImage: "network.slash")
                .foregroundStyle(.orange)
        }
    }
}

private struct PairingCard: View {
    let window: CompanionHub.PairingWindow
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let image = Self.qrImage(window.link.url.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Scan with the iPhone's Camera or the Tether app.")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(window.expires.timeIntervalSince(context.date)))
                    Text(left > 0 ? "Expires in \(left)s" : "Expired. Close and try again.")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(window.link.url.absoluteString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                Button("Done", action: cancel)
            }
        }
    }

    static func qrImage(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
