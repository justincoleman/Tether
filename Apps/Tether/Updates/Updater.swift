import AppKit
import Foundation
import Observation
import OSLog
import Security
import TetherCore

/// Checks GitHub releases for a newer Tether, and installs one by swapping
/// the app bundle and relaunching. Rules live in `UpdateCheck` (TetherCore);
/// this moves bytes. Only a Developer ID build can update itself: a `make
/// dev` build has no team to check a download against, and comes from git.
@MainActor
@Observable
final class Updater {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case installing
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var lastChecked: Date?
    /// The running app's signing team; nil for an unsigned development build.
    let teamId: String? = Updater.runningTeamId()
    let currentVersion = SemanticVersion(
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") ?? SemanticVersion("0")!

    @ObservationIgnored private var timer: Timer?
    private static let log = Logger(subsystem: "app.tether", category: "updates")

    var canInstall: Bool { teamId != nil }

    var available: AvailableUpdate? {
        if case .available(let update) = status { return update }
        return nil
    }

    /// Checks at launch and every six hours, when this build can install.
    func startAutomaticChecks() {
        guard canInstall, UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true else { return }
        Task { await check() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.check() }
            }
        }
    }

    func stopAutomaticChecks() {
        timer?.invalidate()
        timer = nil
    }

    func check() async {
        if status == .checking || status == .installing { return }
        status = .checking
        do {
            // The releases repo is public: no login, no token.
            let (data, response) = try await URLSession.shared.data(
                for: UpdateCheck.request(UpdateCheck.releasesURL(), token: nil))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                throw UpdateError(code == 403
                    ? "GitHub is limiting requests from this network. Try again in an hour."
                    : "GitHub answered \(code).")
            }
            let releases = try UpdateCheck.decodeReleases(data)
            lastChecked = Date()
            if let update = UpdateCheck.newest(in: releases, above: currentVersion) {
                status = .available(update)
            } else {
                status = .upToDate
            }
        } catch {
            Self.log.error("Update check failed: \(error, privacy: .public)")
            status = .failed("\(error)")
        }
    }

    /// Downloads, checks the signature against this app's team, swaps the
    /// bundle once Tether quits, and relaunches.
    func install(_ update: AvailableUpdate) async {
        guard let teamId else { status = .failed("This build isn't signed, so it can't update itself."); return }
        let appURL = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            status = .failed("Tether can't write to \(appURL.deletingLastPathComponent().path).")
            return
        }
        status = .installing
        do {
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("tether-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = try await download(update.asset, to: work)
            let unpacked = work.appendingPathComponent("unpacked")
            try await Task.detached { try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) }.value
            let newApp = unpacked.appendingPathComponent("Tether.app")
            guard FileManager.default.fileExists(atPath: newApp.path) else {
                throw UpdateError("The download has no Tether.app inside.")
            }
            try Self.verify(newApp, teamId: teamId)
            // Strip quarantine so Gatekeeper doesn't ask about an app we checked.
            try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
            let script = UpdateCheck.installScript(appPath: appURL.path, newApp: newApp.path,
                                                   pid: ProcessInfo.processInfo.processIdentifier)
            let swap = Process()
            swap.executableURL = URL(fileURLWithPath: "/bin/sh")
            swap.arguments = ["-c", script]
            try swap.run()
            NSApp.terminate(nil)
        } catch {
            Self.log.error("Update install failed: \(error, privacy: .public)")
            status = .failed("\(error)")
        }
    }

    private func download(_ asset: GitHubRelease.Asset, to dir: URL) async throws -> URL {
        let request = UpdateCheck.request(asset.url, token: nil, accept: "application/octet-stream")
        let (temp, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("The download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let zip = dir.appendingPathComponent(asset.name)
        try FileManager.default.moveItem(at: temp, to: zip)
        return zip
    }

    private nonisolated static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) failed (\(p.terminationStatus)).")
        }
    }

    // MARK: Signing

    private nonisolated static func runningTeamId() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The new app must be validly signed, nested code included, by the same team.
    private nonisolated static func verify(_ app: URL, teamId: String) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { throw UpdateError("Couldn't read the new app's signature.") }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(UpdateCheck.codeRequirement(teamId: teamId) as CFString, [],
                                             &requirement) == errSecSuccess else {
            throw UpdateError("Couldn't build the signing requirement.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError("The download isn't signed by your team (\(status)). Not installing it.")
        }
    }
}

struct UpdateError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
