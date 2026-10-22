import Foundation

public enum BuildSystemKind: String, Codable, Sendable {
    case maven
    case gradle

    public var displayName: String {
        switch self {
        case .maven: return "Maven"
        case .gradle: return "Gradle"
        }
    }
}

public struct BuildSystemSelection: Equatable, Sendable {
    public var kind: BuildSystemKind?
    /// 项目同时存在 Maven 与 Gradle、且没有足够证据判定模块归属。
    /// 此时仍给出确定结果（不是随机挑一个），但必须让用户看到歧义。
    public var isAmbiguous: Bool
    public var reason: String

    public init(kind: BuildSystemKind?, isAmbiguous: Bool = false, reason: String) {
        self.kind = kind
        self.isAmbiguous = isAmbiguous
        self.reason = reason
    }
}

/// 项目级构建系统选择。Maven 与 Gradle 同时存在时，先按模块目录里的构建脚本
/// 判断归属；仍然无法判断时固定回退 Maven，并标记歧义。
///
/// 这里必须是一条可解释的规则，而不是依赖调用点的 if/else 顺序：
/// Maven 运行配置永远不会落到 Gradle，反之亦然。
public enum BuildSystemSelector {
    public static func select(
        config: RunConfiguration?,
        detection: BuildSystemDetection,
        modules: [ProjectModule] = []
    ) -> BuildSystemSelection {
        let hasMaven = detection.maven != nil
        let hasGradle = detection.gradle != nil

        switch config?.type {
        case .maven:
            return hasMaven
                ? BuildSystemSelection(kind: .maven, reason: "Maven 运行配置")
                : BuildSystemSelection(kind: nil, reason: "Maven 运行配置要求项目根存在 pom.xml。")
        case .gradle:
            return hasGradle
                ? BuildSystemSelection(kind: .gradle, reason: "Gradle 运行配置")
                : BuildSystemSelection(kind: nil, reason: "Gradle 运行配置要求项目根存在 settings.gradle(.kts) 或 build.gradle(.kts)。")
        default:
            break
        }

        guard hasMaven || hasGradle else {
            return BuildSystemSelection(
                kind: nil,
                reason: "项目根未找到 pom.xml、settings.gradle(.kts) 或 build.gradle(.kts)，无法确定构建系统。"
            )
        }
        if hasMaven, !hasGradle {
            return BuildSystemSelection(kind: .maven, reason: "仅检测到 Maven")
        }
        if hasGradle, !hasMaven {
            return BuildSystemSelection(kind: .gradle, reason: "仅检测到 Gradle")
        }

        if let module = module(for: config, in: modules),
           let owner = buildSystem(owning: module.directory) {
            return BuildSystemSelection(
                kind: owner,
                reason: "模块 “\(module.name)” 的目录由 \(owner.displayName) 构建"
            )
        }

        return BuildSystemSelection(
            kind: .maven,
            isAmbiguous: true,
            reason: "项目同时存在 Maven 与 Gradle 构建文件，且模块归属不明确；按固定策略使用 Maven。"
        )
    }

    private static func module(for config: RunConfiguration?, in modules: [ProjectModule]) -> ProjectModule? {
        guard let name = config?.moduleName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        if let exact = modules.first(where: { $0.name == name }) {
            return exact
        }
        if let folded = modules.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return folded
        }
        if name.contains(":") {
            let last = name.split(separator: ":").last.map(String.init) ?? name
            return modules.first { module in
                module.gradlePath == name
                    || module.gradlePath?.hasSuffix(":" + last) == true
                    || module.name == last
                    || module.artifactId == last
            }
        }
        return nil
    }

    private static func buildSystem(owning directory: URL) -> BuildSystemKind? {
        let fm = FileManager.default
        let hasPom = fm.fileExists(atPath: directory.appendingPathComponent("pom.xml").path)
        let hasGroovyBuild = fm.fileExists(atPath: directory.appendingPathComponent("build.gradle").path)
        let hasKotlinBuild = fm.fileExists(atPath: directory.appendingPathComponent("build.gradle.kts").path)
        let hasGradleBuild = hasGroovyBuild || hasKotlinBuild

        if hasPom, !hasGradleBuild { return .maven }
        if hasGradleBuild, !hasPom { return .gradle }
        return nil
    }
}
