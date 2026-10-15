import Foundation

/// 运行中进程的本机监听端口探测：只读本机 lsof，不涉网（§64 不受影响）。
/// 用于界面展示「启动了哪些端口」。解析与执行分开，解析可单测。
public enum ListeningPortScanner {
    /// 解析 `lsof -F n` 输出中的地址行（`n*:8080`、`n127.0.0.1:9000`、`n[::]:9229`），
    /// 去重并按端口号升序。非地址行（`p<pid>` 等）与无法解析的行直接忽略。
    public static func parse(_ output: String) -> [Int] {
        var ports = Set<Int>()
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("n"), let colon = line.lastIndex(of: ":") else { continue }
            // 端口一定在最后一个冒号之后；IPv6 链路本地地址的 scope（%en0）在冒号之前
            guard let port = Int(line[line.index(after: colon)...]) else { continue }
            ports.insert(port)
        }
        return ports.sorted()
    }

    /// 查询某个 PID 正在 LISTEN 的 TCP 端口；lsof 不可用或进程已退出时返回空。
    public static func listeningPorts(pid: Int32, lsofPath: String = "/usr/sbin/lsof") -> [Int] {
        guard FileManager.default.isExecutableFile(atPath: lsofPath) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsofPath)
        process.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-F", "n"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 无监听端口时 lsof 以非 0 退出且输出为空，同样按「没有端口」处理
        return parse(String(data: data, encoding: .utf8) ?? "")
    }
}
