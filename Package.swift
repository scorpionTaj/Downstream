// swift-tools-version: 6.0
import PackageDescription

// Builds with the Command Line Tools alone (no Xcode). That rules out the
// @State, @Model, @Test and #Preview macros; see README.md › Building.
let package = Package(
    name: "Downstream",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "DownstreamCore"),
        .executableTarget(name: "Downstream", dependencies: ["DownstreamCore"]),
        // Fixtures are read from disk by path, not bundled as resources.
        .executableTarget(name: "DownstreamChecks", dependencies: ["DownstreamCore"], exclude: ["Fixtures"]),
    ]
)
