// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tether",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "TetherProtocol", targets: ["TetherProtocol"]),
        .library(name: "TetherCore", targets: ["TetherCore"]),
    ],
    targets: [
        // Wire types shared by the Mac app and the iPhone app. Foundation only.
        .target(name: "TetherProtocol"),
        // Mac-side services with no UI framework imports, so they test on any platform.
        .target(name: "TetherCore", dependencies: ["TetherProtocol"]),
        .testTarget(name: "TetherCoreTests", dependencies: ["TetherCore", "TetherProtocol"]),
    ],
    swiftLanguageModes: [.v6]
)
