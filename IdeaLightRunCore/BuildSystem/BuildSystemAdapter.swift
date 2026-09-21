import Foundation

/// §9: 构建目标——启动一个运行配置时，需要向构建系统问的全部内容。
///
/// 这里刻意只放项目无关的信息（模块 + 缓存身份），Maven 的 `reactor` / `-pl`、
/// Gradle 的 project path 都由各适配器自己推导，不再泄漏到调用方。
public struct BuildTarget: Sendable {
    public var module: ProjectModule
    /// classpath 缓存身份（模块 + 构建系统 + 是否含 Provided，§6.1）。
    public var variant: ClasspathVariant

    public init(module: ProjectModule, variant: ClasspathVariant) {
        self.module = module
        self.variant = variant
    }
}

/// §9: 构建系统对启动流水线提供的能力。`ExecutionCoordinator` 只通过这个协议工作，
/// 因此接入 Gradle 不需要在启动流水线里加 `if Gradle`。
public protocol BuildSystemAdapter: Sendable {
    /// Make / Build：编译目标模块及其构建范围内的依赖（§3.3）。
    func buildModule(
        _ target: BuildTarget,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws

    /// IDEA 的 Build / Rebuild / Clean Project：作用于整个项目。
    func buildProject(
        kind: ProjectBuildKind,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws

    /// Before Launch 里配置的构建任务（Maven goal / Gradle task），原文逐项传递（§3.2）。
    func runTasks(
        _ tasks: [String],
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws

    /// 缓存里的 classpath 现在是否可用。冷启动前问一次，
    /// 决定 Build 是单独跑还是合并进 `runtimeClasspath` 那一次调用（§3.1）。
    func hasFreshClasspathCache(for target: BuildTarget) -> Bool

    /// 运行时 classpath（已归一化，可直接拼进 `-cp`）。缓存新鲜时直接复用，否则重新解析并存回。
    /// - Parameter withBuild: 配置里真的有 Build 任务。为 true 时适配器必须保证目标模块被编译过——
    ///   未 install 的兄弟模块只有在同一次构建会话里编译过才能被解析到，
    ///   因此冷解析会把编译合进同一次调用；缓存命中时单独编译。
    ///   为 false 时一次都不编译（"Do not build before run"，§3.3）。
    ///   是否合并 Provided 依赖取自 `target.variant`，缓存才不会互相污染（§6.1）。
    func runtimeClasspath(
        _ target: BuildTarget,
        withBuild: Bool,
        handle: ProcessHandle?,
        log: @escaping LogCallback
    ) throws -> [String]
}
