import Darwin
import Foundation
import IdeaLightRunUpdate

/// 进程外安装助手。替换的是父 app 自己的 bundle，而 Mach-O 正在被执行、
/// 主进程一死就没人负责重启，所以这一步必须在主进程退出后由另一个进程完成。
/// 主进程把本可执行文件拷出 bundle 后再拉起它（见 SoftwareUpdater.launchInstaller）。

private enum UpdaterError: Error {
    case invalidArguments
    case parentDidNotExit
    case executableMissing(URL)
    case launchFailed(String)

    var message: String {
        switch self {
        case .invalidArguments: "更新助手收到的参数不完整。"
        case .parentDidNotExit: "等待 IdeaLightRun 退出超时，已放弃替换。"
        case .executableMissing(let url): "新版本缺少可执行文件 \(url.path)。"
        case .launchFailed(let detail): "重启新版本失败：\(detail)"
        }
    }
}

private func waitForParent(_ pid: pid_t) throws {
    // 主进程退出前动它的 bundle 没有意义；100ms 轮询，最多 60s。
    for _ in 0..<600 {
        if kill(pid, 0) != 0 { return }
        usleep(100_000)
    }
    throw UpdaterError.parentDidNotExit
}

private func launch(_ application: URL, logURL: URL) throws {
    let executableURL = UpdaterRequest.directExecutableURL(for: application)
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
        throw UpdaterError.executableMissing(executableURL)
    }
    let process = Process()
    process.executableURL = executableURL
    process.currentDirectoryURL = application.deletingLastPathComponent()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        throw UpdaterError.launchFailed(error.localizedDescription)
    }
    UpdateLog.append("已请求重启 \(executableURL.path)", to: logURL)
}

/// 返回值表示「新版本是否已经就位」——失败时永远不许留下一个都不剩的空位置。
private func install(_ request: UpdaterRequest) throws {
    let fileManager = FileManager.default
    try waitForParent(request.parentPID)

    // 暂存副本先落到目标所在目录（同一卷），replaceItemAt 才是 rename 级的原子替换；
    // 跨卷会退化成逐字节拷贝，中途失败就是半个 app。
    let parent = request.destinationApplication.deletingLastPathComponent()
    let token = UUID().uuidString
    let incoming = parent.appendingPathComponent(".\(UpdateIdentity.applicationName)-update-\(token).app")
    let backupName = ".\(UpdateIdentity.applicationName)-backup-\(token).app"
    let backup = parent.appendingPathComponent(backupName)

    do {
        try fileManager.copyItem(at: request.sourceApplication, to: incoming)
        _ = try fileManager.replaceItemAt(
            request.destinationApplication,
            withItemAt: incoming,
            backupItemName: backupName,
            options: .withoutDeletingBackupItem
        )
        do {
            try launch(request.destinationApplication, logURL: request.logURL)
        } catch {
            // 新版本装上了但起不来：先换回备份。重启交给外层统一处理，
            // 否则这里起一次、外面再起一次，会同时跑着两份同一个 app。
            if fileManager.fileExists(atPath: backup.path) {
                _ = try? fileManager.replaceItemAt(request.destinationApplication, withItemAt: backup)
                UpdateLog.append("新版本启动失败，已回滚到更新前的版本", to: request.logURL)
            }
            throw error
        }
        try? fileManager.removeItem(at: backup)
        UpdateLog.append("更新完成：\(request.destinationApplication.path)", to: request.logURL)
    } catch {
        try? fileManager.removeItem(at: incoming)
        if !fileManager.fileExists(atPath: request.destinationApplication.path),
           fileManager.fileExists(atPath: backup.path) {
            try? fileManager.moveItem(at: backup, to: request.destinationApplication)
            UpdateLog.append("已回滚到更新前的版本", to: request.logURL)
        }
        UpdateLog.append("更新失败：\(error)", to: request.logURL)
        if fileManager.fileExists(atPath: request.destinationApplication.path) {
            // 无论替换走到哪一步，用户至少要有原来那个能打开的 app。
            try? launch(request.destinationApplication, logURL: request.logURL)
        }
        throw error
    }
}

do {
    guard let request = UpdaterRequest(commandLineArguments: CommandLine.arguments) else {
        throw UpdaterError.invalidArguments
    }
    // 助手把暂存目录和自己所在的临时目录一起带走，磁盘上不留残渣。
    defer {
        try? FileManager.default.removeItem(at: request.stagingDirectory)
        try? FileManager.default.removeItem(at: request.helperDirectory)
    }
    try install(request)
} catch {
    let message = (error as? UpdaterError)?.message ?? error.localizedDescription
    UpdateLog.append("更新助手退出：\(message)", to: UpdateIdentity.logURL)
    exit(1)
}
