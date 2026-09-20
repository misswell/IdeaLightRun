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
                try runBuild(arguments: Array(arguments.dropFirst()))
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
        print("")

        let jdkResolution = JDKResolver().resolve(
            configJDKName: nil,
            projectJDKName: result.projectJDKName
        )

        print("Run Configurations (\(result.configurations.count)):")
        print("")
        for config in result.configurations {
            print("  [\(statusLabel(for: config))] \(config.name) · \(config.type.displayName)")
            if let mainClass = config.mainClass {
                print("      Main:     \(mainClass)")
            }
            if let moduleName = config.moduleName {
                print("      Module:   \(moduleName)")
            }
            if config.type == .compound {
                print("      Members:  \(config.compoundMembers.map(\.name).joined(separator: ", "))")
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

    static func statusLabel(for config: RunConfiguration) -> String {
        switch config.readiness {
        case .ready: return "READY"
        case .warning: return "WARNING"
        case .planned: return "PLANNED"
        case .unsupported: return "UNSUPPORTED"
        }
    }

    static func resolvedModuleDirectory(for config: RunConfiguration, result: ScanResult) -> URL? {
        let resolution = ModuleResolver.resolveModule(
            named: config.moduleName,
            mainClass: config.mainClass,
            projectRoot: result.projectRoot,
            knownModules: result.modules
        )
        return resolution.module?.directory
    }

    // MARK: - run（Milestone 3）

    final class LaunchBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _session: ProcessSession?
        var session: ProcessSession? {
            get { lock.lock(); defer { lock.unlock() }; return _session }
            set { lock.lock(); _session = newValue; lock.unlock() }
        }
    }

    static func runLaunch(arguments: [String]) throws {
        var path: String?
        var name: String?
        for argument in arguments {
            if argument.hasPrefix("-") {
                FileHandle.standardError.write("未知选项：\(argument)\n".data(using: .utf8)!)
                printUsage()
                exit(2)
            }
            if path == nil { path = argument } else if name == nil { name = argument }
        }
        guard let path, let name else {
            FileHandle.standardError.write("用法：idealightrun run <project> <configuration-name>\n".data(using: .utf8)!)
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
        guard config.type == .application || config.type == .springBoot else {
            throw IdeaLightRunError.invalidConfiguration(detail: "“\(config.name)”（\(config.type.displayName)）当前不支持直接启动。")
        }

        let logLock = NSLock()
        let emit: (String) -> Void = { text in
            logLock.lock()
            print(text)
            logLock.unlock()
        }

        let launcher = JavaLauncher()
        let box = LaunchBox()
        let pipelineSemaphore = DispatchSemaphore(value: 0)

        Task.detached(priority: .userInitiated) {
            do {
                let plan = try await launcher.prepare(
                    config: config,
                    projectRoot: projectRoot,
                    log: { line in emit(line.text) },
                    progress: { state in emit("[IdeaLightRun] \(state.displayText)…") }
                )
                let session = try ProcessSession(configKey: config.uniqueKey, configName: config.name, plan: plan)
                session.onLogLines = { batch in
                    for line in batch { emit(line.text) }
                }
                session.onState = { state in
                    emit("[IdeaLightRun] \(state.displayText)")
                }
                box.session = session
                session.start()
            } catch {
                emit("[IdeaLightRun] 错误：\((error as? IdeaLightRunError)?.localizedDescription ?? error.localizedDescription)")
            }
            pipelineSemaphore.signal()
        }
        pipelineSemaphore.wait()

        guard let session = box.session else {
            exit(1)
        }

        // Ctrl-C → SIGTERM（§33）
        signal(SIGINT, SIG_IGN)
        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interruptSource.setEventHandler { session.stop() }
        interruptSource.resume()

        while session.isRunning {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if case .exited(let code) = session.state {
            exit(code == 0 ? 0 : 1)
        }
        exit(1)
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

    static func runBuild(arguments: [String]) throws {
        var rebuildRequested = false
        var path: String?
        for argument in arguments {
            switch argument {
            case "--rebuild":
                rebuildRequested = true
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
            FileHandle.standardError.write("用法：idealightrun build [--rebuild] <project>\n".data(using: .utf8)!)
            exit(2)
        }
        let rebuild = rebuildRequested


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
                    rebuild: rebuild,
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

        // Ctrl-C → 终止正在进行的 Maven 构建（对齐 IDEA 的 Stop Build）
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

            OPTIONS:
              --json                     以 JSON 输出（scan）
              --show-secrets             显示环境变量明文（默认掩码）
              --rebuild                  先清空产物再全量编译（build，IDEA 的 Rebuild Project）
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
