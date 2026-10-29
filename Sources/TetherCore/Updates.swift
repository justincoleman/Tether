import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The fields Tether reads from GitHub's releases API.
public struct GitHubRelease: Decodable, Sendable, Equatable {
    public struct Asset: Decodable, Sendable, Equatable {
        public var name: String
        /// API URL; with `Accept: application/octet-stream` it serves the
        /// file, which is how a private repo's assets are downloaded.
        public var url: URL
        public var size: Int

        public init(name: String, url: URL, size: Int) {
            self.name = name
            self.url = url
            self.size = size
        }
    }

    public var tagName: String
    public var name: String?
    public var draft: Bool
    public var prerelease: Bool
    public var htmlURL: URL?
    public var body: String?
    public var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", name, draft, prerelease, htmlURL = "html_url", body, assets
    }

    public init(tagName: String, name: String? = nil, draft: Bool = false, prerelease: Bool = false,
                htmlURL: URL? = nil, body: String? = nil, assets: [Asset] = []) {
        self.tagName = tagName
        self.name = name
        self.draft = draft
        self.prerelease = prerelease
        self.htmlURL = htmlURL
        self.body = body
        self.assets = assets
    }
}

/// An update Tether can install: a published release newer than the running
/// app, with the zipped app attached.
public struct AvailableUpdate: Sendable, Equatable {
    public var version: SemanticVersion
    public var release: GitHubRelease
    public var asset: GitHubRelease.Asset
}

/// Update rules. Releases come from GitHub (`scripts/release.sh` publishes
/// them); see docs/RELEASING.md.
public enum UpdateCheck {
    /// A public repo that holds only signed release zips and notes, so
    /// installed copies update without a GitHub login. The source repo can
    /// stay private. `scripts/release.sh` publishes to the same name.
    public static let repository = "justincoleman/Tether-releases"

    public static func releasesURL(repository: String = repository) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!
    }

    /// A release tag's version: `v0.4.0` is 0.4.0.
    public static func version(ofTag tag: String) -> SemanticVersion? {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        return SemanticVersion(s)
    }

    /// The zipped app `scripts/release.sh` attaches: `Tether-<version>.zip`.
    public static func appAsset(in release: GitHubRelease) -> GitHubRelease.Asset? {
        release.assets.first { $0.name.hasPrefix("Tether-") && $0.name.hasSuffix(".zip") }
    }

    /// The newest published release above `current` that has the app
    /// attached. Drafts and pre-releases are skipped.
    public static func newest(in releases: [GitHubRelease], above current: SemanticVersion) -> AvailableUpdate? {
        releases
            .filter { !$0.draft && !$0.prerelease }
            .compactMap { release -> AvailableUpdate? in
                guard let version = Self.version(ofTag: release.tagName), version > current,
                      let asset = appAsset(in: release) else { return nil }
                return AvailableUpdate(version: version, release: release, asset: asset)
            }
            .max { $0.version < $1.version }
    }

    public static func decodeReleases(_ data: Data) throws -> [GitHubRelease] {
        try JSONDecoder().decode([GitHubRelease].self, from: data)
    }

    /// A GitHub API request. A public releases repo needs no token; one is
    /// sent only if the user saved one or `gh` is signed in.
    public static func request(_ url: URL, token: String?, accept: String = "application/vnd.github+json") -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Whether a redirected request should keep the Authorization header.
    /// GitHub sends asset downloads to a pre-signed storage URL that rejects
    /// a second credential, so it's dropped when the host changes.
    public static func keepsAuthorization(from original: URL?, to redirect: URL?) -> Bool {
        guard let a = original?.host?.lowercased(), let b = redirect?.host?.lowercased() else { return false }
        return a == b
    }

    /// The code requirement a downloaded app must meet: signed by Apple's
    /// chain for the same team as the running app.
    public static func codeRequirement(teamId: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamId)\""
    }

    /// A shell script that waits for `pid` to exit, swaps `newApp` in at
    /// `appPath` (keeping the old copy until the move succeeds) and opens it.
    public static func installScript(appPath: String, newApp: String, pid: Int32) -> String {
        let app = shellQuote(appPath)
        let old = shellQuote(appPath + ".old")
        let new = shellQuote(newApp)
        return """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(old)
        if mv \(app) \(old) && mv \(new) \(app); then
          rm -rf \(old)
        else
          [ -e \(app) ] || mv \(old) \(app)
        fi
        open \(app)
        """
    }

    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
