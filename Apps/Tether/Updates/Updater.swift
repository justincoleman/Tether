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
    private static let tokenService = "app.tether.github-token"

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
            let token = await Self.token()
            let (data, response) = try await URLSession.shared.data(
                for: UpdateCheck.request(UpdateCheck.releasesURL(), token: token))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                // A private repo answers 404, not 401, without a token; a bad token answers 401.
                throw UpdateError(code == 404 || code == 401
                    ? "GitHub didn't let Tether read the releases (\(code)). If you saved a token in Settings → Updates, remove it or replace it."
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
        let token = await Self.token()
        let request = UpdateCheck.request(asset.url, token: token, accept: "application/octet-stream")
        let (temp, response) = try await URLSession.shared.download(for: request, delegate: RedirectGuard())
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

    // MARK: Token

    /// A token from Settings, else the GitHub CLI's.
    static func token() async -> String? {
        if let saved = savedToken() { return saved }
        return await Task.detached { ghToken() }.value
    }

    static func savedToken() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tokenService,
                                    kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    /// Saves the token, or deletes it when `token` is empty.
    static func saveToken(_ token: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: tokenService]
        SecItemDelete(base as CFDictionary)
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(clean.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private nonisolated static func ghToken() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        guard let gh = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = ["auth", "token"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

struct UpdateError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Drops the GitHub token when an asset download is redirected to storage.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var next = request
        if !UpdateCheck.keepsAuthorization(from: task.originalRequest?.url, to: request.url) {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return next
    }
}
