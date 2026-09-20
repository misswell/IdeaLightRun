import Foundation

/// IDEA 的 Build / Rebuild Project 与 Maven 的 clean：项目级、作用于整个 reactor。
/// 三者的区别只在 goal 序列，共用同一条工具链解析与串行构建管线。
public enum ProjectBuildKind: String, CaseIterable, Sendable {
    case build
    case rebuild
    case clean

    /// `-DskipTests` 只在会走到编译时才有意义；`clean` 不跑任何插件测试绑定。
    public var goalArguments: [String] {
        switch self {
        case .build: return ["-DskipTests", "compile"]
        case .rebuild: return ["-DskipTests", "clean", "compile"]
        case .clean: return ["clean"]
        }
    }

    /// 报错、进度与状态文案里的动作名（"仅支持 Maven 项目直接清理"）。
    public var actionName: String {
        switch self {
        case .build: return "构建"
        case .rebuild: return "重新构建"
        case .clean: return "清理"
        }
    }

    public var goalsDescription: String {
        goalArguments.filter { !$0.hasPrefix("-") }.joined(separator: " ")
    }

    public var startLogLine: String {
        switch self {
        case .build: return "[IdeaLightRun] 构建项目（增量 compile）…"
        case .rebuild: return "[IdeaLightRun] 重新构建项目（clean compile，全量）…"
        case .clean: return "[IdeaLightRun] 清理项目产物（clean：只删 target/，不编译）…"
        }
    }
}

/// IDEA 的 Build Project / Rebuild Project 与 Maven clean：
/// - Build：增量编译整个 reactor（`compile`，不清理产物）
/// - Rebuild：先清空产物再全量编译（`clean compile`）
/// - Clean：只清空产物（`clean`），不编译
///
/// 与启动流水线共用 `ProjectToolchain`（§4）与 `BuildGate`（§42）。
/// classpath 缓存不随 Rebuild / Clean 失效：clean 只删 `target/`，依赖坐标由 §57 的
/// pom/JDK/settings fingerprint 守护；缓存重解另有 §69 的 Rebuild Classpath。
public struct ProjectBuilder: Sendable {
    public init() {}

    public func build(
        projectRoot: URL,
        kind: ProjectBuildKind,
        log: @escaping LogCallback,
        progress: @escaping (ProcessState) -> Void = { _ in },
        processHandle: ProcessHandle? = nil
    ) async throws {
        // 停止可能按在解析工具链之前：那时还没有进程可终止，只能靠这个标记
        if processHandle?.isCancelled == true {
            throw IdeaLightRunError.launchCancelled(detail: "\(kind.actionName)已被用户停止。")
        }

        progress(.preparing)
        let toolchain = try ProjectToolchain.resolveMaven(
            projectRoot: projectRoot,
            context: kind.actionName,
            log: log
        )

        try await BuildGate.shared.run(projectKey: projectRoot.standardizedFileURL.path) {
            if processHandle?.isCancelled == true {
                throw IdeaLightRunError.launchCancelled(detail: "\(kind.actionName)已被用户停止。")
            }
            progress(.building)
            log(LogLine(stream: .system, text: kind.startLogLine))
            try toolchain.service.buildProject(kind: kind, handle: processHandle, log: log)
            log(LogLine(stream: .system, text: "[IdeaLightRun] \(kind.actionName)完成"))
        }
    }
}
