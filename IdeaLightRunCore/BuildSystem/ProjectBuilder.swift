import Foundation

/// IDEA 的 Build Project / Rebuild Project：
/// - Build：增量编译整个 reactor（`compile`，不清理产物）
/// - Rebuild：先清空产物再全量编译（`clean compile`）
///
/// 与启动流水线共用 `ProjectToolchain`（§4）与 `BuildGate`（§42）。
/// classpath 缓存不随 Rebuild 失效：clean 只删 `target/`，依赖坐标由 §57 的
/// pom/JDK/settings fingerprint 守护；缓存重解另有 §69 的 Rebuild Classpath。
public struct ProjectBuilder: Sendable {
    public init() {}

    public func build(
        projectRoot: URL,
        rebuild: Bool,
        log: @escaping LogCallback,
        progress: @escaping (ProcessState) -> Void = { _ in },
        processHandle: ProcessHandle? = nil
    ) async throws {
        // 停止可能按在解析工具链之前：那时还没有进程可终止，只能靠这个标记
        if processHandle?.isCancelled == true {
            throw IdeaLightRunError.launchCancelled(detail: "构建已被用户停止。")
        }

        progress(.preparing)
        let toolchain = try ProjectToolchain.resolveMaven(
            projectRoot: projectRoot,
            context: "构建",
            log: log
        )

        try await BuildGate.shared.run(projectKey: projectRoot.standardizedFileURL.path) {
            if processHandle?.isCancelled == true {
                throw IdeaLightRunError.launchCancelled(detail: "构建已被用户停止。")
            }
            progress(.building)
            log(LogLine(
                stream: .system,
                text: rebuild
                    ? "[IdeaLightRun] 重新构建项目（clean compile，全量）…"
                    : "[IdeaLightRun] 构建项目（增量 compile）…"
            ))
            try toolchain.service.buildProject(rebuild: rebuild, handle: processHandle, log: log)
            log(LogLine(stream: .system, text: "[IdeaLightRun] 构建完成"))
        }
    }
}
