import Foundation

/// §9: 一次启动需要向构建系统问什么，在这里一次算清楚，交给上层「适配器 + 构建目标」。
/// 启动流水线因此只面对 `BuildSystemAdapter`，不需要写 `if Maven` / `if Gradle`。
public enum BuildSystemResolver {
    public struct Resolution: Sendable {
        public let adapter: any BuildSystemAdapter
        public let target: BuildTarget
        public let jdk: JDKInstallation

        public init(adapter: any BuildSystemAdapter, target: BuildTarget, jdk: JDKInstallation) {
            self.adapter = adapter
            self.target = target
            self.jdk = jdk
        }
    }

    /// - Parameter config: 只提供构建系统相关的选择：JRE 引用与是否含 Provided 依赖。
    public static func resolve(
        projectRoot: URL,
        result: ScanResult,
        config: RunConfiguration,
        module: ProjectModule,
        context: String = "启动",
        log: @escaping LogCallback
    ) throws -> Resolution {
        let toolchain = try ProjectToolchain.resolve(
            projectRoot: projectRoot,
            result: result,
            configJDKName: config.jreReference,
            context: context,
            log: log
        )
        return Resolution(
            adapter: toolchain.service,
            target: BuildTarget(
                module: module,
                variant: .maven(
                    module: module.name,
                    includeProvided: config.includeProvidedDependencies
                )
            ),
            jdk: toolchain.jdk
        )
    }
}
