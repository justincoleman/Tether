import AppKit
import SwiftUI
import TetherCore

/// Settings → Updates: status, a check button, and the GitHub token for the
/// private repo's releases.
struct UpdatesSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("checkForUpdates") private var checkForUpdates = true
    @State private var token = ""
    @State private var tokenSaved = Updater.savedToken() != nil

    var body: some View {
        let updater = model.updater
        Form {
            LabeledContent("This version", value: updater.currentVersion.description)
            if updater.canInstall {
                Toggle("Check for updates automatically", isOn: $checkForUpdates)
                    .onChange(of: checkForUpdates) { _, on in
                        if on { updater.startAutomaticChecks() } else { updater.stopAutomaticChecks() }
                    }
                HStack {
                    Button("Check Now") { Task { await updater.check() } }
                        .disabled(updater.status == .checking || updater.status == .installing)
                    UpdateStatusText(updater: updater)
                }
                if let update = updater.available {
                    Button("Install \(update.version.description) and Relaunch") {
                        UpdatePrompt.confirmInstall(update, updater: updater)
                    }
                }
                Section("GitHub access") {
                    SecureField(tokenSaved ? "Saved. Paste a new one to replace it." : "Token with read access to the repo",
                                text: $token)
                    HStack {
                        Button("Save Token") {
                            Updater.saveToken(token)
                            token = ""
                            tokenSaved = Updater.savedToken() != nil
                        }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                        if tokenSaved {
                            Button("Remove") {
                                Updater.saveToken("")
                                tokenSaved = false
                            }
                        }
                    }
                    Text("The repo is private, so reading its releases needs a token. Without one, Tether uses gh auth token "
                         + "if the GitHub CLI is signed in. A fine-grained token with Contents: read on the repo is enough.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("This is a development build, so it doesn't update itself. Update with git pull && make dev. "
                     + "Builds made by scripts/release.sh are signed and check GitHub for new releases.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

struct UpdateStatusText: View {
    let updater: Updater

    var body: some View {
        switch updater.status {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Text("Tether is up to date.").font(.caption).foregroundStyle(.secondary)
        case .available(let update):
            Text("Tether \(update.version.description) is available.").font(.caption)
        case .installing:
            Text("Downloading…").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
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
