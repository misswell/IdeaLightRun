import Foundation
import IdeaLightRunCore

@main
struct IdeaLightRunCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            exit(2)
        }

        switch command {
        case "scan", "list":
            do {
                try runScan(arguments: Array(arguments.dropFirst()))
            } catch {
                printError(error)
                exit(1)
            }
        case "run":
            do {
                try runLaunch(arguments: Array(arguments.dropFirst()))
            } catch {
                printError(error)
                exit(1)
            }
        case "build":
            do {
                try runBuild(arguments: Array(arguments.dropFirst()), defaultKind: .build)
            } catch {
                printError(error)
                exit(1)
            }
        case "clean":
            do {
                try runBuild(arguments: Array(arguments.dropFirst()), defaultKind: .clean)
            } catch {
                printError(error)
                exit(1)
            }
        case "help", "--help", "-h":
            printUsage()
        default:
            FileHandle.standardError.write("未知命令：\(command)\n".data(using: .utf8)!)
            printUsage()
            exit(2)
        }
        exit(0)
    }

    // MARK: - scan

    static func runScan(arguments: [String]) throws {
        var json = false
        var showSecrets = false
        var path: String?

        for argument in arguments {
            switch argument {
            case "--json":
                json = true
            case "--show-secrets":
                showSecrets = true
            case "-h", "--help":
                printUsage()
                exit(0)
            default:
                if argument.hasPrefix("-") {
                    FileHandle.standardError.write("未知选项：\(argument)\n".data(using: .utf8)!)
                    printUsage()
                    exit(2)
                }
                if path == nil {
                    path = argument
                }
            }
        }

        guard let path else {
            FileHandle.standardError.write("缺少项目路径。用法：idealightrun scan <project>\n".data(using: .utf8)!)
            exit(2)
        }

        let expanded = (path as NSString).expandingTildeInPath
        let projectRoot = URL(fileURLWithPath: expanded, isDirectory: true)

        // §48: 项目根目录至少有 .idea / pom.xml / build.gradle(.kts) 之一。
        guard BuildSystemDetector.isValidProjectRoot(projectRoot) else {
            throw IdeaLightRunError.invalidProjectRoot(path: projectRoot.path)
        }

        let scanner = IntelliJProjectScanner()
        let result = try scanner.scan(projectRoot: projectRoot)

        if json {
            printJSON(result)
        } else {
            printHuman(result, showSecrets: showSecrets)
        }
    }

    // MARK: - 输出

    static func printJSON(_ result: ScanResult) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(result)) ?? Data("{}".utf8)
        print(String(data: data, encoding: .utf8) ?? "{}")
    }

    static func printHuman(_ result: ScanResult, showSecrets: Bool) {
        print("Project: \(result.projectRoot.path)")

        var buildDescriptions: [String] = []
        if let maven = result.buildSystem.maven {
            buildDescriptions.append("Maven \(maven.wrapperURL != nil ? "(./mvnw)" : "(系统 mvn)")")
        }
        if let gradle = result.buildSystem.gradle {
            let dsl = gradle.usesKotlinDSL ? " Kotlin DSL" : ""
            buildDescriptions.append("Gradle \(gradle.wrapperURL != nil ? "(./gradlew)" : "(系统 gradle)")\(dsl)")
        }
        print("Build System: \(buildDescriptions.isEmpty ? "未知" : buildDescriptions.joined(separator: " + "))")

        if let jdkName = result.projectJDKName {
            print("Project JDK: \(jdkName)（来自 .idea/misc.xml）")
        }
        print("Modules (\(result.modules.count)): \(result.modules.map(\.name).joined(separator: ", "))")
        if result.ignoredDuplicateCount > 0 {
            print("已按来源优先级去重，忽略 \(result.ignoredDuplicateCount) 个重复配置")
        }
        if !result.diagnostics.isEmpty {
            print("扫描诊断（\(result.diagnostics.count)）：")
            for diagnostic in result.diagnostics {
                print("  [\(diagnostic.severity.rawValue.uppercased())] \(diagnostic.file.path)：\(diagnostic.message)")
                if let remediation = diagnostic.remediation, !remediation.isEmpty {
                    print("      建议：\(remediation)")
                }
            }
        }
        print("")

        let jdkResolution = JDKResolver().resolve(
            configJDKName: nil,
            projectJDKName: result.projectJDKName
        )

        print("Run Configurations (\(result.configurations.count)):")
        print("")
        for config in result.configurations {
            let capability = ConfigurationCapabilityResolver.resolve(config, scan: result)
            print("  [\(statusLabel(for: capability.readiness))] \(config.name) · \(config.type.displayName)")
            if let reason = capability.primaryReason {
                print("      Reason:   \(reason)")
            }
            if let mainClass = config.mainClass, config.type != .junit {
                print("      Main:     \(mainClass)")
            }
            if let moduleName = config.moduleName {
                print("      Module:   \(moduleName)")
            }
            if config.type == .compound {
                print("      Members:  \(config.compoundMembers.map(\.name).joined(separator: ", "))")
            }
            if let mavenOptions = config.mavenOptions {
                if !mavenOptions.goals.isEmpty {
                    print("      Goals:    \(mavenOptions.goals.joined(separator: " "))")
                }
                if !mavenOptions.profiles.isEmpty {
                    print("      Profiles: \(mavenOptions.profiles.joined(separator: ","))")
                }
                if !mavenOptions.selectedProjects.isEmpty {
                    print("      Projects: \(mavenOptions.selectedProjects.joined(separator: ","))")
                }
                if !mavenOptions.commandLineOptions.isEmpty {
                    print("      Command:  \(mavenOptions.commandLineOptions)")
                }
            }
            if let junitOptions = config.junitOptions {
                print("      Test:     \(junitOptions.target.displayText)")
            }
            if let vmOptions = config.vmOptions {
                print("      VM:       \(vmOptions)")
            }
            if let programArguments = config.programArguments {
                print("      Args:     \(programArguments)")
            }
            if !config.springProfiles.isEmpty {
                print("      Profiles: \(config.springProfiles.joined(separator: ","))")
            }
            if !config.environmentVariables.isEmpty {
                let entries = config.environmentVariables
                    .keys
                    .sorted()
                    .map { key -> String in
                        let value = showSecrets ? (config.environmentVariables[key] ?? "") : "******"
                        return "\(key)=\(value)"
                    }
                print("      Env:      \(entries.joined(separator: "  "))")
            }
            if let rawWorkingDirectory = config.workingDirectory {
                let moduleDirectory = resolvedModuleDirectory(for: config, result: result)
                let resolution = MacroResolver(
                    projectDir: result.projectRoot,
                    moduleDir: moduleDirectory
                ).resolve(rawWorkingDirectory)
                print("      WorkDir:  \(resolution.value)")
            }
            if let jre = config.jreReference {
                print("      JRE:      \(jre)")
            }
            if !config.beforeLaunchTasks.isEmpty {
                let tasks = config.beforeLaunchTasks
                    .filter(\.isEnabled)
                    .map(\.displayName)
                    .joined(separator: ", ")
                if !tasks.isEmpty {
                    print("      Before:   \(tasks)")
                }
            }
            print("      Source:   \(config.source.kind.displayName) → \(config.source.file.lastPathComponent)")
            for warning in config.warnings {
                print("      ⚠ \(warning.title)：\(warning.detail)")
            }
            print("")
        }

        if let jdk = jdkResolution.installation {
            let version = jdk.majorVersion.map(String.init) ?? "?"
            let name = jdk.displayName ?? jdk.home.lastPathComponent
            print("Resolved Project JDK: \(name) (major \(version)) @ \(jdk.home.path)")
        } else {
            for warning in jdkResolution.warnings {
                print("⚠ \(warning.title)：\(warning.detail)")
            }
        }
    }

    static func statusLabel(for readiness: Readiness) -> String {
        switch readiness {
        case .ready: return "READY"
        case .warning: return "WARNING"
        case .planned: return "PLANNED"
        case .unsupported: return "UNSUPPORTED"
        }
    }

    static func resolvedModuleDirectory(for config: RunConfiguration, result: ScanResult) -> URL? {
        let resolution = ModuleResolver.resolveModule(
            named: config.moduleName,
            // JUnit 的 MAIN_CLASS_NAME 是测试类，不是应用入口，不能拿来定位模块。
            mainClass: config.type == .junit ? nil : config.mainClass,
            projectRoot: result.projectRoot,
            knownModules: result.modules
        )
        return resolution.module?.directory
    }

    // MARK: - run

    final class RunControl: @unchecked Sendable {
        private let lock = NSLock()
        private var _runtime: ExecutionRuntime?
        private var _buildHandle: ProcessHandle?
        private var _restartRequested = false
        private var _interrupted = false

        var runtime: ExecutionRuntime? {
            get { lock.lock(); defer { lock.unlock() }; return _runtime }
            set { lock.lock(); _runtime = newValue; lock.unlock() }
        }

        var buildHandle: ProcessHandle? {
            get { lock.lock(); defer { lock.unlock() }; return _buildHandle }
            set { lock.lock(); _buildHandle = newValue; lock.unlock() }
        }

        func requestRestart() {
            lock.lock()
            _restartRequested = true
            lock.unlock()
        }

        /// 取出并清除重启请求：一次停止只对应一次重启。
        func takeRestartRequest() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let value = _restartRequested
            _restartRequested = false
            return value
        }

        var isInterrupted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _interrupted
        }

        /// Ctrl-C：构建期终止编译器，运行期停止 JVM；绝不触发自动重启。
        func interrupt() {
            lock.lock()
            _interrupted = true
            _restartRequested = false
            let handle = _buildHandle
            let runtime = _runtime
            lock.unlock()
            handle?.terminate()
            runtime?.stop()
        }
    }

    static func runLaunch(arguments: [String]) throws {
        var path: String?
        var name: String?
        var hotReloadEnabled = false
        var provider: HotReloadProviderKind = .automatic
        var autoCompile = true
        var watchCompiledOutputs = true
        var watchResources = true
        var restartPolicy: HotReloadRestartPolicy = .ask
        var debounceMilliseconds = 800
        var ignoredPaths: [String] = []
        var externalAgentPath: String?
        var externalAgentArguments = ""

        var index = 0
        func requireValue(_ flag: String) -> String {
            index += 1
            guard index < arguments.count else {
                FileHandle.standardError.write("选项 \(flag) 缺少取值\n".data(using: .utf8)!)
                exit(2)
            }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--hot-reload":
                hotReloadEnabled = true
            case "--hot-reload-provider":
                let value = requireValue(argument)
                guard let parsed = Self.hotReloadProvider(from: value) else {
                    FileHandle.standardError.write(
                        "未知热更新后端：\(value)（可选 automatic / standard / devtools / hotswap-agent / jrebel）\n"
                            .data(using: .utf8)!
                    )
                    exit(2)
                }
                provider = parsed
                hotReloadEnabled = true
            case "--hot-reload-no-auto-compile":
                autoCompile = false
                hotReloadEnabled = true
            case "--hot-reload-no-watch-outputs":
                watchCompiledOutputs = false
                hotReloadEnabled = true
            case "--hot-reload-no-watch-resources":
                watchResources = false
                hotReloadEnabled = true
            case "--hot-reload-restart":
                let value = requireValue(argument)
                guard let parsed = Self.hotReloadRestartPolicy(from: value) else {
                    FileHandle.standardError.write(
                        "未知回退策略：\(value)（可选 notify / ask / automatic）\n".data(using: .utf8)!
                    )
                    exit(2)
                }
                restartPolicy = parsed
                hotReloadEnabled = true
            case "--hot-reload-debounce":
                let value = requireValue(argument)
                guard let parsed = Int(value), (200...10_000).contains(parsed) else {
                    FileHandle.standardError.write("去抖必须是 200–10000 毫秒的整数：\(value)\n".data(using: .utf8)!)
                    exit(2)
                }
                debounceMilliseconds = parsed
                hotReloadEnabled = true
            case "--hot-reload-ignore":
                ignoredPaths.append(requireValue(argument))
                hotReloadEnabled = true
            case "--hot-reload-agent-path":
                externalAgentPath = requireValue(argument)
                hotReloadEnabled = true
            case "--hot-reload-agent-args":
                externalAgentArguments = requireValue(argument)
                hotReloadEnabled = true
            case "-h", "--help":
                printUsage()
                exit(0)
            default:
                if argument.hasPrefix("-") {
                    FileHandle.standardError.write("未知选项：\(argument)\n".data(using: .utf8)!)
                    printUsage()
                    exit(2)
                }
                if path == nil {
                    path = argument
                } else if name == nil {
                    name = argument
                } else {
                    FileHandle.standardError.write("多余的参数：\(argument)\n".data(using: .utf8)!)
                    exit(2)
                }
            }
            index += 1
        }

        guard let path, let name else {
            FileHandle.standardError.write(
                "用法：idealightrun run [--hot-reload] <project> <configuration-name>\n".data(using: .utf8)!
            )
            exit(2)
        }

        let expanded = (path as NSString).expandingTildeInPath
        let projectRoot = URL(fileURLWithPath: expanded, isDirectory: true)
        guard BuildSystemDetector.isValidProjectRoot(projectRoot) else {
            throw IdeaLightRunError.invalidProjectRoot(path: projectRoot.path)
        }

        let result = try IntelliJProjectScanner().scan(projectRoot: projectRoot)
        guard let config = result.configurations.first(where: { $0.name == name }) else {
            let names = result.configurations.map(\.name).joined(separator: ", ")
            FileHandle.standardError.write("找不到配置 “\(name)”。可用：\(names)\n".data(using: .utf8)!)
            exit(2)
        }

        // §22: CLI 不自己判断类型，交给 ExecutionCoordinator；不支持的配置会明确报错。
        let logLock = NSLock()
        let emit: (String) -> Void = { text in
            logLock.lock()
            print(text)
            logLock.unlock()
        }

        let hotReloadConfiguration = hotReloadEnabled
            ? HotReloadConfiguration(
                enabled: true,
                provider: provider,
                autoCompileOnChange: autoCompile,
                watchCompiledOutputs: watchCompiledOutputs,
                watchResources: watchResources,
                restartPolicy: restartPolicy,
                debounceMilliseconds: debounceMilliseconds,
                ignoredPaths: ignoredPaths,
                externalAgentPath: externalAgentPath,
                externalAgentArguments: externalAgentArguments
            )
            : nil

        // 显式 `--hot-reload` 对本次启动的所有 JVM 生效；Compound 成员因此各自拥有
        // 独立的监听会话与状态。未加该选项时 provider 恒为 nil，绝不注入 Agent。
        let hotReloadConfigurationFor: HotReloadConfigurationProvider = { _ in hotReloadConfiguration }

        func emitSnapshot(_ label: String, _ snapshot: HotReloadSnapshot) {
            let providerName = snapshot.provider?.displayName ?? "-"
            emit("[HotReload]\(label) \(snapshot.state.displayText) · \(providerName)：\(snapshot.detail)")
            guard let summary = snapshot.summary else { return }
            emit("[HotReload]\(label) \(summary.consoleLine)")
            for failure in summary.failedClasses.prefix(10) {
                emit("[HotReload]\(label) 失败 \(failure.className)（\(failure.kind.displayText)）：\(failure.message)")
            }
            for skipped in summary.skippedClasses.prefix(10) {
                emit("[HotReload]\(label) 跳过 \(skipped.className)：\(skipped.message)")
            }
            for note in summary.notes.prefix(6) {
                emit("[HotReload]\(label) 说明：\(note)")
            }
        }

        let control = RunControl()
        let coordinator = ExecutionCoordinator()
        let exitCode = ExitCodeBox()
        let finished = DispatchSemaphore(value: 0)

        // Ctrl-C → 终止构建或停止 JVM（§33）；同时清掉自动重启请求。
        // 信号源不能挂在 main：下面的 finished.wait() 会阻塞主线程，Ctrl-C 将永远不生效。
        signal(SIGINT, SIG_IGN)
        let interruptSource = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: DispatchQueue(label: "com.misswell.IdeaLightRun.cli-interrupt", qos: .userInitiated)
        )
        interruptSource.setEventHandler { control.interrupt() }
        interruptSource.resume()

        Task.detached(priority: .userInitiated) {
            var code: Int32 = 1
            while true {
                let handle = ProcessHandle()
                control.buildHandle = handle
                do {
                    let execution = try await coordinator.prepare(
                        config: config,
                        projectRoot: projectRoot,
                        hotReloadConfigurationFor: hotReloadConfigurationFor,
                        log: { line in emit(line.text) },
                        progress: { state in emit("[IdeaLightRun] \(state.displayText)…") },
                        processHandle: handle
                    )
                    if control.isInterrupted {
                        code = 130
                        break
                    }
                    let runtime = try ExecutionRuntime(
                        configKey: config.uniqueKey,
                        configName: config.name,
                        execution: execution
                    )
                    runtime.setHandlers(
                        onState: { state in
                            emit("[IdeaLightRun] \(state.displayText)")
                        },
                        onLogLines: { batch in
                            for line in batch { emit(line.text) }
                        },
                        onCompoundMember: { event in
                            switch event.kind {
                            case .started(let pid):
                                emit("[IdeaLightRun] 成员 “\(event.memberName)” 已启动（PID \(pid)）")
                            case .state(let state):
                                emit("[IdeaLightRun] 成员 “\(event.memberName)”：\(state.displayText)")
                            case .logLines(let lines):
                                for line in lines { emit("[\(event.memberName)] \(line.text)") }
                            case .hotReload(let snapshot):
                                emitSnapshot(" [\(event.memberName)]", snapshot)
                            case .hotReloadRestartRequested(let reason):
                                emit("[IdeaLightRun] 成员 “\(event.memberName)” 热更新需要重启：\(reason)")
                            }
                        },
                        onHotReload: { snapshot in
                            emitSnapshot("", snapshot)
                        },
                        onHotReloadRestart: { reason in
                            emit("[IdeaLightRun] 热更新需要重启：\(reason)；按自动重启策略重新准备。")
                            control.requestRestart()
                            control.runtime?.stop()
                            return true
                        }
                    )
                    control.runtime = runtime
                    runtime.start()
                    while runtime.isRunning {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    control.runtime = nil
                    if control.isInterrupted {
                        code = 130
                        break
                    }
                    if control.takeRestartRequest() {
                        emit("[IdeaLightRun] 旧进程已退出，重新编译并启动…")
                        continue
                    }
                    if case .exited(let status) = runtime.state {
                        code = status == 0 ? 0 : 1
                    } else {
                        code = 1
                    }
                    break
                } catch {
                    let message = (error as? IdeaLightRunError)?.localizedDescription
                        ?? error.localizedDescription
                    emit("[IdeaLightRun] 错误：\(message)")
                    code = (error as? IdeaLightRunError).map(isCancelled) == true ? 130 : 1
                    break
                }
            }
            control.buildHandle = nil
            exitCode.value = code
            finished.signal()
        }
        finished.wait()
        interruptSource.cancel()
        exit(exitCode.value)
    }

    // MARK: - build（IDEA 的 Build Project / Rebuild Project）

    final class ExitCodeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Int32 = 1
        var value: Int32 {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }

    static func runBuild(arguments: [String], defaultKind: ProjectBuildKind) throws {
        var requestedKind = defaultKind
        var path: String?
        for argument in arguments {
            switch argument {
            case "--rebuild" where defaultKind != .clean:
                requestedKind = .rebuild
            case "-h", "--help":
                printUsage()
                exit(0)
            default:
                if argument.hasPrefix("-") {
                    FileHandle.standardError.write("未知选项：\(argument)\n".data(using: .utf8)!)
                    printUsage()
                    exit(2)
                }
                if path == nil { path = argument }
            }
        }
        guard let path else {
            let usage = defaultKind == .clean
                ? "用法：idealightrun clean <project>\n"
                : "用法：idealightrun build [--rebuild] <project>\n"
            FileHandle.standardError.write(usage.data(using: .utf8)!)
            exit(2)
        }
        let kind = requestedKind
        let expanded = (path as NSString).expandingTildeInPath
        let projectRoot = URL(fileURLWithPath: expanded, isDirectory: true)
        guard BuildSystemDetector.isValidProjectRoot(projectRoot) else {
            throw IdeaLightRunError.invalidProjectRoot(path: projectRoot.path)
        }

        let logLock = NSLock()
        let emit: (String) -> Void = { text in
            logLock.lock()
            print(text)
            logLock.unlock()
        }

        let handle = ProcessHandle()
        let code = ExitCodeBox()
        let finished = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                try await ProjectBuilder().build(
                    projectRoot: projectRoot,
                    kind: kind,
                    log: { line in emit(line.text) },
                    progress: { state in emit("[IdeaLightRun] \(state.displayText)…") },
                    processHandle: handle
                )
                code.value = 0
            } catch let error as IdeaLightRunError {
                emit("[IdeaLightRun] \(error.title)：\(error.reason)")
                // 130 = 128 + SIGINT，与被 Ctrl-C 终止的命令行工具一致
                code.value = isCancelled(error) ? 130 : 1
            } catch {
                emit("[IdeaLightRun] 错误：\(error.localizedDescription)")
                code.value = 1
            }
            finished.signal()
        }

        // Ctrl-C → 终止正在进行的构建（对齐 IDEA 的 Stop Build）
        signal(SIGINT, SIG_IGN)
        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global())
        interruptSource.setEventHandler { handle.terminate() }
        interruptSource.resume()
        finished.wait()
        exit(code.value)
    }

    private static func isCancelled(_ error: IdeaLightRunError) -> Bool {
        if case .launchCancelled = error { return true }
        return false
    }

    private static func hotReloadProvider(from value: String) -> HotReloadProviderKind? {
        switch value.lowercased() {
        case "auto", "automatic": return .automatic
        case "standard", "hotswap": return .standard
        case "devtools", "spring-boot-devtools", "springbootdevtools": return .springBootDevTools
        case "hotswap-agent", "hotswapagent": return .hotswapAgent
        case "jrebel": return .jrebel
        default: return nil
        }
    }

    private static func hotReloadRestartPolicy(from value: String) -> HotReloadRestartPolicy? {
        switch value.lowercased() {
        case "notify": return .notify
        case "ask": return .ask
        case "auto", "automatic": return .automatic
        default: return nil
        }
    }

    // MARK: - Usage / Error

    static func printUsage() {
        print(
            """
            IdeaLightRun CLI — 读取 IDEA Run Configuration 并启动 Java 项目

            USAGE: idealightrun <command> [options] <project-path>

            COMMANDS:
              scan <path>                扫描项目并输出所有 Run Configuration（list 为别名）
              run <path> <config-name>   编译并启动指定配置（Ctrl-C 停止）
              build <path>               构建整个项目（IDEA 的 Build Project）
              clean <path>               清空项目产物（Maven clean / Gradle clean，不编译）

            OPTIONS:
              --json                     以 JSON 输出（scan）
              --show-secrets             显示环境变量明文（默认掩码）
              --rebuild                  先清空产物再全量编译（build，IDEA 的 Rebuild Project）

            HOT RELOAD（run，仅 Application / Spring Boot 配置会真正注入 Agent）:
              --hot-reload               为本次启动启用热更新
              --hot-reload-provider       automatic（默认）/ standard / devtools / hotswap-agent / jrebel
              --hot-reload-no-auto-compile      保存源码后不自动编译，仅响应外部构建输出
              --hot-reload-no-watch-outputs     不监听编译输出目录
              --hot-reload-no-watch-resources   不监听资源目录
              --hot-reload-restart        notify / ask（默认）/ automatic
              --hot-reload-debounce       <毫秒，200–10000，默认 800>
              --hot-reload-ignore         <路径前缀，可重复>
              --hot-reload-agent-path     <外部 Agent jar / 安装目录>
              --hot-reload-agent-args     <追加参数原文，按空白分词，不经过 shell>

              -h, --help                 显示帮助
            """
        )
    }

    static func printError(_ error: Error) {
        if let lightRunError = error as? IdeaLightRunError {
            FileHandle.standardError.write(
                "\(lightRunError.title)：\(lightRunError.reason)\n建议：\(lightRunError.suggestion)\n".data(using: .utf8)!
            )
        } else {
            FileHandle.standardError.write("错误：\(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }
}
