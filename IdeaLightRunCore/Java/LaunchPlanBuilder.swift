import Foundation

/// §26–§29: RunConfiguration + 解析结果 → JavaLaunchPlan。
public enum LaunchPlanBuilder {
    public static func build(
        config: RunConfiguration,
        projectRoot: URL,
        moduleDirectory: URL?,
        classpath: [String],
        jdk: JDKInstallation
    ) throws -> JavaLaunchPlan {
        guard let mainClass = config.mainClass, !mainClass.isEmpty else {
            throw IdeaLightRunError.mainClassNotFound(detail: "配置 “\(config.name)” 没有可用的 Main Class。")
        }

        let javaExecutable = jdk.javaExecutable
        guard FileManager.default.isExecutableFile(atPath: javaExecutable.path) else {
            throw IdeaLightRunError.jdkNotFound(detail: "Java 可执行文件不存在：\(javaExecutable.path)")
        }

        let resolver = MacroResolver(projectDir: projectRoot, moduleDir: moduleDirectory)

        // VM Options：分词 + 宏展开（§12/§11）
        var vmArguments: [String] = []
        if let vmOptions = config.vmOptions {
            vmArguments += CommandLineTokenizer.tokenize(vmOptions).map { resolver.resolve($0).value }
        }
        // §29: profiles 已显式存在时不重复注入
        if !config.springProfiles.isEmpty,
           !vmArguments.contains(where: { $0.hasPrefix("-Dspring.profiles.active") }) {
            vmArguments.append("-Dspring.profiles.active=" + config.springProfiles.joined(separator: ","))
        }

        let programArguments: [String]
        if let raw = config.programArguments {
            programArguments = CommandLineTokenizer.tokenize(raw).map { resolver.resolve($0).value }
        } else {
            programArguments = []
        }

        // §28: system < Run Configuration
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in config.environmentVariables {
            environment[key] = resolver.resolve(value).value
        }

        let workingDirectory: URL
        if let raw = config.workingDirectory {
            let resolved = resolver.resolve(raw).value
            workingDirectory = URL(fileURLWithPath: resolved, isDirectory: true)
        } else {
            workingDirectory = moduleDirectory ?? projectRoot
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw IdeaLightRunError.launchFailed(detail: "Working Directory 不存在：\(workingDirectory.path)（原始值：\(config.workingDirectory ?? "-")）")
        }

        guard !classpath.isEmpty else {
            throw IdeaLightRunError.classpathResolveFailed(detail: "runtime classpath 为空，无法启动。")
        }

        return JavaLaunchPlan(
            javaExecutable: javaExecutable,
            vmArguments: vmArguments,
            classpath: classpath,
            mainClass: mainClass,
            programArguments: programArguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
    }
}
