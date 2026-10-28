import SwiftUI
import TetherProtocol
import VisionKit

/// Scan the Mac's pairing QR (or paste its link), then wait for the Mac to
/// accept. Also shown when the Camera app opens a tether:// link.
struct PairView: View {
    @Environment(PhoneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let pairing = store.pairing {
                    progress(pairing)
                } else {
                    scanner
                    pasteField
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.cancelPairing()
                        dismiss()
                    }
                }
            }
            .onChange(of: store.pairedCount) {
                // Pairing succeeded.
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var scanner: some View {
        if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
            QRScanner { value in
                guard let url = URL(string: value), let link = PairingLink(url: url) else { return }
                store.pair(link)
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Text("Point the camera at the QR code in Tether → Settings → iPhone on your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            Text("Scan the QR code on your Mac with the Camera app, or paste its link below.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var pasteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("tether://pair?…", text: $pasted)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("Pair") {
                    guard let url = URL(string: pasted.trimmingCharacters(in: .whitespacesAndNewlines)),
                          let link = PairingLink(url: url) else {
                        invalid = true
                        return
                    }
                    invalid = false
                    store.pair(link)
                }
                .disabled(pasted.isEmpty)
            }
            if invalid {
                Text("That isn't a Tether pairing link.").font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func progress(_ pairing: MacConnection) -> some View {
        VStack(spacing: 12) {
            switch pairing.status {
            case .rejected(let reason):
                Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.red)
                Text(reason).multilineTextAlignment(.center)
                Button("Try Again") { store.cancelPairing() }
            case .offline(let reason):
                Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.orange)
                Text("Couldn't reach \(pairing.mac.name) at \(pairing.mac.host).")
                    .multilineTextAlignment(.center)
                Text("Check that Tailscale is connected on this iPhone and the Mac. (\(reason))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { store.cancelPairing() }
            case .updateNeeded:
                Image(systemName: "exclamationmark.arrow.circlepath").font(.largeTitle).foregroundStyle(.orange)
                Text("Tether on the Mac and this iPhone are different versions. Update both.")
                    .multilineTextAlignment(.center)
            case .connecting, .online:
                ProgressView()
                Text("Pairing with \(pairing.mac.name)…")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

/// VisionKit's live QR scanner. Reports each recognized payload once.
private struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var seen: Set<String> = []

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode(let barcode) = item, let value = barcode.payloadStringValue,
                      seen.insert(value).inserted else { continue }
                onCode(value)
            }
        }
    }
}
