import Foundation

/// §3.2: IDEA 的 Before Launch 在这里真正执行。
///
/// Core 默认 fail closed：不认识的任务、没有保存 goal 的 Maven 任务、需要 Gradle 的任务，
/// 一律阻止启动并给明确错误（§10）——"偷偷跳过然后照常跑"会让用户以为构建发生了。
/// 具体动作为什么做、怎么做由调用方注入，执行器只管顺序、引用解析与循环检测。
public struct BeforeLaunchExecutor: Sendable {
    public struct Actions: Sendable {
        /// §3.3: Make / Build = 编译当前模块（Maven: `-pl <module> -am -DskipTests compile`）。
        public var build: @Sendable () async throws -> Void
        /// §3.4: Build Project = 整个 reactor 增量编译。
        public var buildProject: @Sendable () async throws -> Void
        /// §3.5: Maven.BeforeRunTask = 原样执行 IDEA 保存的 goal。
        public var runMavenGoals: @Sendable (_ goals: [String]) async throws -> Void
        /// §3.7: Run Another Configuration = 先跑完被引用的配置；chain 为当前引用链，用于循环检测。
        public var runReferenced: @Sendable (_ config: RunConfiguration, _ chain: [String]) async throws -> Void

        public init(
            build: @escaping @Sendable () async throws -> Void,
            buildProject: @escaping @Sendable () async throws -> Void,
            runMavenGoals: @escaping @Sendable ([String]) async throws -> Void,
            runReferenced: @escaping @Sendable (RunConfiguration, [String]) async throws -> Void
        ) {
            self.build = build
            self.buildProject = buildProject
            self.runMavenGoals = runMavenGoals
            self.runReferenced = runReferenced
        }
    }

    public init() {}

    public func run(
        for config: RunConfiguration,
        configurations: [RunConfiguration],
        actions: Actions,
        visiting: [String] = [],
        handle: ProcessHandle? = nil,
        log: @escaping LogCallback
    ) async throws {
        // 引用链里都是配置名：同一项目的同名配置在 IDEA 里本就是同一个运行入口。
        let chain = visiting + [config.name]
        let tasks = config.beforeLaunchTasks.filter(\.isEnabled)
        guard !tasks.isEmpty else { return }

        for task in tasks {
            // 停止可能按在两个任务之间：没有进程要终止，也要在这里落住。
            if handle?.isCancelled == true {
                throw IdeaLightRunError.launchCancelled(detail: "Before Launch 已被用户停止。")
            }
            switch task.kind {
            case .build:
                log(LogLine(stream: .system, text: "[IdeaLightRun] Before Launch：Build（编译当前模块）…"))
                try await actions.build()
            case .buildProject:
                log(LogLine(stream: .system, text: "[IdeaLightRun] Before Launch：Build Project（整个项目）…"))
                try await actions.buildProject()
            case .mavenGoal(let goal):
                let goals = CommandLineTokenizer.tokenize(goal)
                guard !goals.isEmpty else {
                    throw IdeaLightRunError.unsupportedBeforeLaunch(
                        detail: "配置 “\(config.name)” 的 Maven.BeforeRunTask 没有保存任何 goal，"
                            + "无法确定要执行什么。请在 IDEA 中填写 Command line 后重试。"
                    )
                }
                log(LogLine(stream: .system, text: "[IdeaLightRun] Before Launch：mvn \(goals.joined(separator: " "))…"))
                try await actions.runMavenGoals(goals)
            case .gradleTask(let gradleTask):
                throw IdeaLightRunError.unsupportedBeforeLaunch(
                    detail: "配置 “\(config.name)” 的 Before Launch 需要执行 Gradle 任务“\(gradleTask)”；"
                        + "当前版本只支持 Maven 项目启动，Gradle 支持在 Milestone 4 提供。"
                )
            case .runConfiguration(let name, let type):
                let referenced = try Self.resolveReference(
                    name: name,
                    type: type,
                    in: configurations,
                    from: config.name
                )
                if chain.contains(referenced.name) {
                    throw IdeaLightRunError.beforeLaunchCycle(chain: chain + [referenced.name])
                }
                log(LogLine(stream: .system, text: "[IdeaLightRun] Before Launch：先运行 “\(referenced.name)”…"))
                try await actions.runReferenced(referenced, chain)
            case .unknown(let raw):
                throw IdeaLightRunError.unsupportedBeforeLaunch(
                    detail: "配置 “\(config.name)” 的 Before Launch 任务“\(raw)”暂不支持执行。"
                        + "IdeaLightRun 不会跳过它照常启动，请在 IDEA 中移除该任务或改用项目级构建。"
                )
            }
        }
    }

    // MARK: - 内部

    /// §3.7: 被引用的配置必须存在。type 用于同名配置的消歧，缺失时按名字兜底。
    static func resolveReference(
        name: String,
        type: String?,
        in configurations: [RunConfiguration],
        from sourceName: String
    ) throws -> RunConfiguration {
        let sameName = configurations.filter { $0.name == name }
        if let type, !type.isEmpty,
           let typed = sameName.first(where: { $0.type.ideaTypeRaw == type }) {
            return typed
        }
        guard let found = sameName.first else {
            throw IdeaLightRunError.referencedConfigurationNotFound(
                detail: "配置 “\(sourceName)” 的 Before Launch 引用了 “\(name)”，但当前项目里没有这个运行配置。"
            )
        }
        return found
    }
}
