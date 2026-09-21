// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IdeaLightRun",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "IdeaLightRunCore", path: "IdeaLightRunCore"),
        // 在线更新的共享内核：App 侧与更新助手侧共用同一份版本比较、
        // 产物校验与参数契约，避免两处实现漂移。
        .target(name: "IdeaLightRunUpdate", path: "IdeaLightRunUpdate"),
        .executableTarget(name: "IdeaLightRunCLI", dependencies: ["IdeaLightRunCore"], path: "IdeaLightRunCLI"),
        .executableTarget(name: "IdeaLightRunApp", dependencies: ["IdeaLightRunCore", "IdeaLightRunUpdate"], path: "IdeaLightRunApp"),
        // 进程外安装助手：主 app 退出后由它替换 bundle 并重启。
        .executableTarget(name: "IdeaLightRunUpdater", dependencies: ["IdeaLightRunUpdate"], path: "IdeaLightRunUpdater"),
        .testTarget(name: "IdeaLightRunCoreTests", dependencies: ["IdeaLightRunCore"], path: "Tests/IdeaLightRunCoreTests"),
        .testTarget(name: "IdeaLightRunUpdateTests", dependencies: ["IdeaLightRunUpdate"], path: "Tests/IdeaLightRunUpdateTests")
    ],
    swiftLanguageVersions: [.v5]
)
