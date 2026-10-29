import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import TetherCore

@Suite struct UpdatesTests {
    @Test func tagsParseWithOrWithoutV() {
        #expect(UpdateCheck.version(ofTag: "v0.4.0") == SemanticVersion("0.4"))
        #expect(UpdateCheck.version(ofTag: "0.10.0")! > SemanticVersion("0.9.9")!)
        #expect(UpdateCheck.version(ofTag: "latest") == nil)
        #expect(UpdateCheck.version(ofTag: "v") == nil)
    }

    /// Trimmed from `GET /repos/{owner}/{repo}/releases`.
    static let releasesJSON = """
    [
      {"tag_name": "v0.6.0", "name": "Tether 0.6.0", "draft": true, "prerelease": false,
       "html_url": "https://github.com/justincoleman/Tether/releases/tag/v0.6.0", "body": "",
       "assets": [{"name": "Tether-0.6.0.zip", "url": "https://api.github.com/repos/justincoleman/Tether/releases/assets/6", "size": 6}]},
      {"tag_name": "v0.5.0", "name": "Tether 0.5.0", "draft": false, "prerelease": true,
       "html_url": null, "body": null,
       "assets": [{"name": "Tether-0.5.0.zip", "url": "https://api.github.com/repos/justincoleman/Tether/releases/assets/5", "size": 5}]},
      {"tag_name": "v0.4.1", "name": "Tether 0.4.1", "draft": false, "prerelease": false,
       "html_url": "https://github.com/justincoleman/Tether/releases/tag/v0.4.1", "body": "Fixes",
       "assets": [{"name": "notes.txt", "url": "https://api.github.com/repos/justincoleman/Tether/releases/assets/40", "size": 1}]},
      {"tag_name": "v0.4.0", "name": "Tether 0.4.0", "draft": false, "prerelease": false,
       "html_url": "https://github.com/justincoleman/Tether/releases/tag/v0.4.0", "body": "Splits",
       "assets": [{"name": "Tether-0.4.0.zip", "url": "https://api.github.com/repos/justincoleman/Tether/releases/assets/4", "size": 4,
                   "browser_download_url": "https://github.com/x", "content_type": "application/zip"}]}
    ]
    """

    @Test func picksNewestPublishedReleaseWithTheApp() throws {
        let releases = try UpdateCheck.decodeReleases(Data(Self.releasesJSON.utf8))
        #expect(releases.count == 4)
        // 0.6.0 is a draft, 0.5.0 a pre-release, 0.4.1 has no app zip.
        let update = try #require(UpdateCheck.newest(in: releases, above: SemanticVersion("0.3.0")!))
        #expect(update.version == SemanticVersion("0.4.0"))
        #expect(update.asset.name == "Tether-0.4.0.zip")
        #expect(update.asset.url.absoluteString.hasSuffix("/assets/4"))
        #expect(UpdateCheck.newest(in: releases, above: SemanticVersion("0.4.0")!) == nil)
    }

    @Test func requestsCarryTokenOnlyWhenGiven() {
        let url = UpdateCheck.releasesURL()
        #expect(url.absoluteString == "https://api.github.com/repos/justincoleman/Tether-releases/releases?per_page=20")
        let authed = UpdateCheck.request(url, token: "abc", accept: "application/octet-stream")
        #expect(authed.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(authed.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
        #expect(UpdateCheck.request(url, token: "").value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func authorizationIsDroppedOnCrossHostRedirect() {
        let api = URL(string: "https://api.github.com/repos/x/y/releases/assets/1")
        #expect(UpdateCheck.keepsAuthorization(from: api, to: URL(string: "https://API.github.com/other")))
        #expect(!UpdateCheck.keepsAuthorization(
            from: api, to: URL(string: "https://objects.githubusercontent.com/github-production-release-asset")))
        #expect(!UpdateCheck.keepsAuthorization(from: nil, to: api))
    }

    @Test func installScriptQuotesPathsAndRestoresOnFailure() {
        let script = UpdateCheck.installScript(appPath: "/Applications/Justin's Tether.app",
                                               newApp: "/tmp/u/Tether.app", pid: 42)
        #expect(script.contains("kill -0 42"))
        #expect(script.contains("mv '/Applications/Justin'\\''s Tether.app' '/Applications/Justin'\\''s Tether.app.old'"))
        #expect(script.contains("&& mv '/tmp/u/Tether.app' '/Applications/Justin'\\''s Tether.app'"))
        #expect(script.contains("[ -e '/Applications/Justin'\\''s Tether.app' ] || mv"))
        #expect(script.hasSuffix("open '/Applications/Justin'\\''s Tether.app'"))
    }

    @Test func requirementPinsTheTeam() {
        #expect(UpdateCheck.codeRequirement(teamId: "ABCDE12345")
                == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }
}
