import Foundation
@testable import IdeaLightRunCore

/// 用假 `mvnw` 顶替真实 Maven：只做两件事——
/// ① 把每次调用的完整参数记进 `mvnw.log`；② 按 `-DincludeScope` 把预置文本写进 `-Dmdep.outputFile`。
///
/// "compile 调用了几次、有没有和依赖解析合并、provided 有没有多跑一段" 这类断言
/// 因此不需要真的解析依赖，CI 上也能稳定跑；真实 Maven 的行为由
/// `MavenClasspathIntegrationTests`（本机）覆盖。
final class StubMavenProject {
    let root: URL
    private let fm = FileManager.default

    var logURL: URL { root.appendingPathComponent("mvnw.log") }
    private var invocationLines: [String] {
        (try? String(contentsOf: logURL, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).map(String.init) ?? []
    }
    /// 每次 Maven 调用的参数列表（按空格切分；测试用的路径与参数都不含空格）。
    var invocations: [[String]] { invocationLines.map { $0.split(separator: " ").map(String.init) } }

    /// 含某个 goal/参数片段的调用次数。
    func count(containing goal: String) -> Int {
        invocations.filter { $0.contains(goal) }.count
    }
    func count(containingAll goals: [String]) -> Int {
        invocations.filter { args in goals.allSatisfy { args.contains($0) } }.count
    }
    var logText: String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }

    init(fixture: String) throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("lr-stub-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.copyItem(at: Fixtures.url(fixture), to: root)
    }

    /// 生成 mvnw 桩；`runtime` / `compile` 是两种 scope 各自要写出的 classpath 条目。
    func installStub(runtime: [String], compile: [String]? = nil) throws {
        let stubDirectory = root.appendingPathComponent(".stub", isDirectory: true)
        try fm.createDirectory(at: stubDirectory, withIntermediateDirectories: true)
        try runtime.joined(separator: ":").write(
            to: stubDirectory.appendingPathComponent("runtime.txt"), atomically: true, encoding: .utf8
        )
        if let compile {
            try compile.joined(separator: ":").write(
                to: stubDirectory.appendingPathComponent("compile.txt"), atomically: true, encoding: .utf8
            )
        }

        let script = """
        #!/bin/sh
        DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        printf '%s\\n' "$*" >> "$DIR/mvnw.log"
        out=""
        scope=""
        for arg in "$@"; do
            case "$arg" in
                -Dmdep.outputFile=*) out="${arg#-Dmdep.outputFile=}" ;;
                -DincludeScope=*) scope="${arg#-DincludeScope=}" ;;
            esac
        done
        if [ -n "$out" ]; then
            mkdir -p "$(dirname "$out")"
            if [ -f "$DIR/.stub/$scope.txt" ]; then
                printf '%s' "$(cat "$DIR/.stub/$scope.txt")" > "$out"
            else
                : > "$out"
            fi
        fi
        exit 0
        """
        let url = root.appendingPathComponent("mvnw")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// 模拟"已经编译过"：dependency:build-classpath 会把兄弟模块解析到 target/classes，
    /// `MavenClasspathResolver.normalize` 也只在目录存在时才做 jar → classes 的替换。
    func markCompiled(_ modules: [String]) throws {
        for module in modules {
            try fm.createDirectory(
                at: root.appendingPathComponent("\(module)/target/classes", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    func configuration(named name: String) throws -> RunConfiguration {
        let result = try IntelliJProjectScanner().scan(projectRoot: root)
        guard let config = result.configurations.first(where: { $0.name == name }) else {
            throw IdeaLightRunError.invalidConfiguration(
                detail: "桩项目里没有配置 “\(name)”，扫到的是 \(result.configurations.map(\.name))"
            )
        }
        return config
    }

    /// 假 mvnw 不产生编译产物，但 classpath 缓存是真的落在 ~/Library/Caches 里，
    /// 用完必须按临时目录清掉，否则每次跑测试都在攒垃圾。
    func delete() {
        for module in ["app", "provided-lib"] {
            ClasspathCache.clear(projectRoot: root, moduleName: module)
        }
        try? fm.removeItem(at: root)
    }
}

/// 系统上没有可用 JDK 时跳过整组启动流水线测试：
/// `JavaLauncher` 必须解析出 JDK 才能产出 LaunchPlan，这与桩无关。
enum TestToolchain {
    static func availableJDK() -> JDKInstallation? {
        JDKResolver().resolve(configJDKName: nil, projectJDKName: nil).installation
    }
}
