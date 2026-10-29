import AppKit
import SwiftUI
import TetherCore

/// Settings → Updates: the running version, a check button and the switch
/// for automatic checks.
struct UpdatesSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("checkForUpdates") private var checkForUpdates = true

    var body: some View {
        let updater = model.updater
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tether").font(.title2.weight(.semibold))
                        Text(updater.canInstall ? "Version \(updater.currentVersion.description)"
                                                : "Version \(updater.currentVersion.description) (development build)")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            if updater.canInstall {
                Section {
                    Toggle("Check for updates automatically", isOn: $checkForUpdates)
                        .onChange(of: checkForUpdates) { _, on in
                            if on { updater.startAutomaticChecks() } else { updater.stopAutomaticChecks() }
                        }
                    LabeledContent {
                        Button("Check Now") { Task { await updater.check() } }
                            .disabled(updater.status == .checking || updater.status == .installing)
                    } label: {
                        UpdateStatusText(updater: updater)
                    }
                    if let update = updater.available {
                        Button("Install \(update.version.description) and Relaunch") {
                            UpdatePrompt.confirmInstall(update, updater: updater)
                        }
                    }
                } footer: {
                    Text("Checks every six hours and asks before installing.")
                }
            } else {
                Section {
                    Text("This is a development build, so it doesn't update itself. Update with git pull && make dev. "
                         + "Builds made by make release are signed and check for new releases.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct UpdateStatusText: View {
    let updater: Updater

    var body: some View {
        switch updater.status {
        case .idle:
            Text("Not checked yet.").foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Label("Tether is up to date.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .available(let update):
            Text("Tether \(update.version.description) is available.")
        case .installing:
            Text("Downloading…").foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }
}

/// The alerts behind Tether → Check for Updates… and the sidebar notice.
@MainActor
enum UpdatePrompt {
    static func checkFromMenu(_ updater: Updater) {
        guard updater.canInstall else {
            alert("This is a development build.",
                  "It doesn't update itself. Update with git pull && make dev.")
            return
        }
        Task {
            await updater.check()
            switch updater.status {
            case .available(let update):
                confirmInstall(update, updater: updater)
            case .upToDate:
                alert("Tether is up to date.", "You have \(updater.currentVersion.description), the newest release.")
            case .failed(let message):
                alert("Couldn't check for updates.", message)
            default:
                break
            }
        }
    }

    static func confirmInstall(_ update: AvailableUpdate, updater: Updater) {
        let a = NSAlert()
        a.messageText = "Install Tether \(update.version.description)?"
        a.informativeText = "Tether quits, replaces itself and opens again. Claude tabs restart and pick their "
            + "conversations back up. Anything Claude is in the middle of stops."
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        if update.release.htmlURL != nil { a.addButton(withTitle: "Release Notes") }
        switch a.runModal() {
        case .alertFirstButtonReturn:
            Task { await updater.install(update) }
        case .alertThirdButtonReturn:
            if let url = update.release.htmlURL { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        _ = a.runModal()
    }
}
