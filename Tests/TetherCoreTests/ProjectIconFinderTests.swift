import Foundation
import Testing
@testable import TetherCore

@Suite struct ProjectIconFinderTests {
    func project(_ files: [String: String]) throws -> String {
        let root = NSTemporaryDirectory() + "tether-icons-\(UUID().uuidString)"
        for (rel, content) in files {
            let path = root + "/" + rel
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        // macOS temp folders sit behind /var -> /private/var; the folder walk reports real paths.
        return URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    }

    let iosSet = #"""
    {"images":[
      {"filename":"light.png","idiom":"universal","platform":"ios","size":"1024x1024"},
      {"filename":"dark.png","idiom":"universal","platform":"ios","size":"1024x1024",
       "appearances":[{"appearance":"luminosity","value":"dark"}]}
    ]}
    """#

    @Test func explicitIconWins() throws {
        let root = try project([".tether/icon.png": "x", "icon.png": "y",
                                "App/Assets.xcassets/AppIcon.appiconset/Contents.json": iosSet,
                                "App/Assets.xcassets/AppIcon.appiconset/light.png": "z"])
        #expect(ProjectIconFinder.find(in: root) == root + "/.tether/icon.png")
    }

    @Test func xcodeIconPicksDefaultAppearanceAndLargest() throws {
        let mac = #"""
        {"images":[
          {"filename":"a.png","size":"16x16","scale":"1x"},
          {"filename":"b.png","size":"512x512","scale":"2x"},
          {"filename":"c.png","size":"256x256","scale":"2x"}
        ]}
        """#
        let root = try project(["Apps/T/Assets.xcassets/AppIcon.appiconset/Contents.json": mac,
                                "Apps/T/Assets.xcassets/AppIcon.appiconset/a.png": "1",
                                "Apps/T/Assets.xcassets/AppIcon.appiconset/b.png": "2",
                                "Apps/T/Assets.xcassets/AppIcon.appiconset/c.png": "3"])
        #expect(ProjectIconFinder.find(in: root)?.hasSuffix("/AppIcon.appiconset/b.png") == true)

        let ios = try project(["X/Assets.xcassets/AppIcon.appiconset/Contents.json": iosSet,
                               "X/Assets.xcassets/AppIcon.appiconset/light.png": "1",
                               "X/Assets.xcassets/AppIcon.appiconset/dark.png": "2"])
        #expect(ProjectIconFinder.find(in: ios)?.hasSuffix("/light.png") == true)
    }

    @Test func prefersAppIconNameAndSkipsBuildFolders() throws {
        let one = #"{"images":[{"filename":"i.png","size":"64x64"}]}"#
        let root = try project(["build/Assets.xcassets/AppIcon.appiconset/Contents.json": one,
                                "build/Assets.xcassets/AppIcon.appiconset/i.png": "1",
                                "node_modules/x/AppIcon.appiconset/Contents.json": one,
                                "node_modules/x/AppIcon.appiconset/i.png": "1",
                                "A/Assets.xcassets/Other.appiconset/Contents.json": one,
                                "A/Assets.xcassets/Other.appiconset/i.png": "1",
                                "B/Assets.xcassets/AppIcon.appiconset/Contents.json": one,
                                "B/Assets.xcassets/AppIcon.appiconset/i.png": "1"])
        #expect(ProjectIconFinder.find(in: root) == root + "/B/Assets.xcassets/AppIcon.appiconset/i.png")
    }

    @Test func fallsBackToWebIconsThenNil() throws {
        let web = try project(["public/favicon.png": "x"])
        #expect(ProjectIconFinder.find(in: web) == web + "/public/favicon.png")
        let empty = try project(["README.md": "hi", "src/main.swift": ""])
        #expect(ProjectIconFinder.find(in: empty) == nil)
        // An icon set whose image file is missing doesn't count.
        let broken = try project(["A/Assets.xcassets/AppIcon.appiconset/Contents.json": iosSet])
        #expect(ProjectIconFinder.find(in: broken) == nil)
    }

    @Test func pixelMath() {
        #expect(ProjectIconFinder.pixels(size: "60x60", scale: "3x") == 180)
        #expect(ProjectIconFinder.pixels(size: "1024x1024", scale: nil) == 1024)
        #expect(ProjectIconFinder.pixels(size: nil, scale: "2x") == 0)
    }
}
