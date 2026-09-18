// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IdeaLightRun",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "IdeaLightRunCore", path: "IdeaLightRunCore"),
        .executableTarget(name: "IdeaLightRunCLI", dependencies: ["IdeaLightRunCore"], path: "IdeaLightRunCLI"),
        .executableTarget(name: "IdeaLightRunApp", dependencies: ["IdeaLightRunCore"], path: "IdeaLightRunApp"),
        .testTarget(name: "IdeaLightRunCoreTests", dependencies: ["IdeaLightRunCore"], path: "Tests/IdeaLightRunCoreTests")
    ],
    swiftLanguageVersions: [.v5]
)
