import Foundation

/// 主进程 → 更新助手之间唯一的接口：一串命令行参数。
/// 定义在共享 target 里，是为了让「怎么调」和「怎么解」不可能各自漂移，
/// 也让这条契约能在不真的启动 app 的情况下被测试覆盖。
public struct UpdaterRequest: Equatable, Sendable {
    public let parentPID: Int32
    /// 校验通过的暂存新版本。
    public let sourceApplication: URL
    /// 正在运行的安装位置。
    public let destinationApplication: URL
    /// 替换完成后要清掉的暂存根目录。
    public let stagingDirectory: URL
    /// 助手自己被拷出去的临时目录——它要能删掉自己。
    public let helperDirectory: URL
    public let logURL: URL

    public init(
        parentPID: Int32,
        sourceApplication: URL,
        destinationApplication: URL,
        stagingDirectory: URL,
        helperDirectory: URL,
        logURL: URL
    ) {
        self.parentPID = parentPID
        self.sourceApplication = sourceApplication
        self.destinationApplication = destinationApplication
        self.stagingDirectory = stagingDirectory
        self.helperDirectory = helperDirectory
        self.logURL = logURL
    }

    /// 从 `CommandLine.arguments` 解析（首元素是程序自身路径，占位）。
    public init?(commandLineArguments: [String]) {
        let values = Array(commandLineArguments.dropFirst())
        guard values.count == 6, let parentPID = Int32(values[0]), parentPID > 0 else { return nil }
        self.parentPID = parentPID
        sourceApplication = URL(fileURLWithPath: values[1])
        destinationApplication = URL(fileURLWithPath: values[2])
        stagingDirectory = URL(fileURLWithPath: values[3])
        helperDirectory = URL(fileURLWithPath: values[4])
        logURL = URL(fileURLWithPath: values[5])
    }

    /// 交给 `Process.arguments` 的参数数组。
    public var processArguments: [String] {
        [
            String(parentPID),
            sourceApplication.path,
            destinationApplication.path,
            stagingDirectory.path,
            helperDirectory.path,
            logURL.path
        ]
    }

    /// 重启走直接 exec 而不是 `open`：`open` 可能命中 LaunchServices 对刚被
    /// 替换掉的路径留下的旧记录，返回成功却根本不产生进程。
    public static func directExecutableURL(for application: URL) -> URL {
        application
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(UpdateIdentity.executableName, isDirectory: false)
    }
}
