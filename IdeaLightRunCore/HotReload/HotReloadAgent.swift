import Darwin
import Foundation

/// 内置 Java Agent 的启动配置。
///
/// 控制通道只绑定 127.0.0.1 的随机端口；token 通过 0600 文件传给 Agent，
/// 不出现在进程参数 / 日志里。整个控制目录在进程终态时删除。
public struct HotReloadAgentLaunch: Sendable {
    public var jarURL: URL
    public var controlDirectory: URL
    public var tokenFileURL: URL
    public var portFileURL: URL
    public var token: String
    public var jvmArguments: [String]

    public static func prepare(jarURL: URL) throws -> HotReloadAgentLaunch {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("IdeaLightRun-hotreload-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw IdeaLightRunError.hotReloadUnavailable(
                detail: "无法创建热更新控制目录：\(error.localizedDescription)"
            )
        }

        var generator = SystemRandomNumberGenerator()
        let tokenBytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let token = tokenBytes.map { String(format: "%02x", $0) }.joined()
        let tokenFile = directory.appendingPathComponent("token")
        let portFile = directory.appendingPathComponent("port")
        do {
            try Data(token.utf8).write(to: tokenFile, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        } catch {
            try? fm.removeItem(at: directory)
            throw IdeaLightRunError.hotReloadUnavailable(
                detail: "无法写入热更新控制凭据：\(error.localizedDescription)"
            )
        }

        let argument = "-javaagent:\(jarURL.path)=portFile=\(portFile.path),tokenFile=\(tokenFile.path)"
        return HotReloadAgentLaunch(
            jarURL: jarURL,
            controlDirectory: directory,
            tokenFileURL: tokenFile,
            portFileURL: portFile,
            token: token,
            jvmArguments: [argument]
        )
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: controlDirectory)
    }
}

public enum HotReloadAgentLocator {
    public static let environmentKey = "IDEALIGHTRUN_HOT_RELOAD_AGENT"

    /// 查找随应用打包的 Agent；开发期允许用环境变量指向本地构建产物。
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = Bundle.main.executableURL,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) -> URL? {
        var candidates: [URL] = []
        if let configured = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: (configured as NSString).expandingTildeInPath))
        }
        if let bundleResourceURL {
            candidates.append(bundleResourceURL.appendingPathComponent("HotReloadAgent.jar"))
        }
        if let executableURL {
            let directory = executableURL.deletingLastPathComponent()
            candidates.append(directory.appendingPathComponent("HotReloadAgent.jar"))
            candidates.append(
                directory.deletingLastPathComponent()
                    .appendingPathComponent("Resources/HotReloadAgent.jar")
            )
        }
        candidates.append(currentDirectory.appendingPathComponent("build/HotReloadAgent.jar"))
        candidates.append(currentDirectory.appendingPathComponent("Resources/HotReloadAgent.jar"))

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 0 {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }
}

// MARK: - 控制协议

public enum HotReloadAgentStatus: UInt8, Sendable {
    case ok = 0
    case partial = 1
    case error = 2
    case unauthorized = 3
}

public struct HotReloadAgentClassResult: Equatable, Sendable {
    public enum Code: UInt8, Sendable {
        case applied = 0
        case failed = 1
        case skipped = 2
    }

    public var className: String
    public var code: Code
    public var message: String

    public init(className: String, code: Code, message: String) {
        self.className = className
        self.code = code
        self.message = message
    }
}

public struct HotReloadAgentResponse: Equatable, Sendable {
    public var status: HotReloadAgentStatus
    public var message: String
    public var classes: [HotReloadAgentClassResult]

    public init(status: HotReloadAgentStatus, message: String, classes: [HotReloadAgentClassResult]) {
        self.status = status
        self.message = message
        self.classes = classes
    }
}

public enum HotReloadAgentProtocol {
    public static let magic: UInt32 = 0x494C_5231  // "ILR1"
    public static let maxFrameSize = 64 * 1024 * 1024
    public static let maxStringBytes = 8 * 1024
    public static let maxTokenBytes = 256

    enum Opcode: UInt8 {
        case status = 1
        case reload = 2
        case shutdown = 3
    }
}

/// 同步的 loopback 客户端。会话在一次热更新周期内串行调用，
/// 锁只是防止 Stop 与手动触发同时落到同一个 socket。
public final class HotReloadAgentClient: @unchecked Sendable {
    /// 请求串行化与 socket 关闭分开加锁：Stop 不能被 20s 的读写超时拖住。
    private let requestLock = NSLock()
    private let fdLock = NSLock()
    private var socketFD: Int32
    private let token: String

    public init(port: UInt16, token: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IdeaLightRunError.hotReloadUnavailable(detail: "无法创建热更新控制通道。")
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw IdeaLightRunError.hotReloadUnavailable(
                detail: "无法连接热更新 Agent（127.0.0.1:\(port)）：\(String(cString: strerror(errno)))"
            )
        }
        self.socketFD = fd
        self.token = token
    }

    deinit {
        shutdown()
    }

    public func status() throws -> HotReloadAgentResponse {
        try request(opcode: .status, payload: Data())
    }

    public func reload(classes: [(name: String, path: String)]) throws -> HotReloadAgentResponse {
        var payload = Data()
        Self.appendUInt32(UInt32(classes.count), to: &payload)
        for entry in classes {
            try Self.appendString(entry.name, to: &payload)
            try Self.appendString(entry.path, to: &payload)
        }
        return try request(opcode: .reload, payload: payload)
    }

    public func shutdown() {
        fdLock.lock()
        let fd = socketFD
        socketFD = -1
        fdLock.unlock()
        guard fd >= 0 else { return }
        // 先 shutdown 再 close：正在阻塞读的请求会立即返回，不会等满 20s。
        Darwin.shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private func request(opcode: HotReloadAgentProtocol.Opcode, payload: Data) throws -> HotReloadAgentResponse {
        requestLock.lock()
        defer { requestLock.unlock() }
        fdLock.lock()
        let fd = socketFD
        fdLock.unlock()
        guard fd >= 0 else {
            throw IdeaLightRunError.hotReloadUnavailable(detail: "热更新控制通道已关闭。")
        }

        var frame = Data()
        Self.appendUInt32(HotReloadAgentProtocol.magic, to: &frame)
        try Self.appendString(token, to: &frame)
        frame.append(opcode.rawValue)
        frame.append(payload)
        do {
            try Self.writeAll(frame, to: fd)
            let magic = try Self.readUInt32(from: fd)
            guard magic == HotReloadAgentProtocol.magic else {
                throw IdeaLightRunError.hotReloadUnavailable(detail: "热更新 Agent 返回了无法识别的响应。")
            }
            guard let status = HotReloadAgentStatus(rawValue: try Self.readUInt8(from: fd)) else {
                throw IdeaLightRunError.hotReloadUnavailable(detail: "热更新 Agent 返回了未知状态。")
            }
            var message = try Self.readString(from: fd)
            let count = Int(try Self.readUInt32(from: fd))
            guard count >= 0, count <= 100_000 else {
                throw IdeaLightRunError.hotReloadUnavailable(detail: "热更新 Agent 返回的类数量异常。")
            }
            var classes: [HotReloadAgentClassResult] = []
            classes.reserveCapacity(count)
            for _ in 0..<count {
                let className = try Self.readString(from: fd)
                guard let code = HotReloadAgentClassResult.Code(rawValue: try Self.readUInt8(from: fd)) else {
                    throw IdeaLightRunError.hotReloadUnavailable(detail: "热更新 Agent 返回了未知的类状态。")
                }
                let detail = try Self.readString(from: fd)
                classes.append(HotReloadAgentClassResult(className: className, code: code, message: detail))
            }
            if status == .unauthorized {
                message = "热更新控制凭据被 Agent 拒绝。"
            }
            return HotReloadAgentResponse(status: status, message: message, classes: classes)
        } catch let error as IdeaLightRunError {
            shutdown()
            throw error
        } catch {
            shutdown()
            throw IdeaLightRunError.hotReloadUnavailable(
                detail: "热更新控制通道读写失败：\(error.localizedDescription)"
            )
        }
    }

    // MARK: - 帧读写

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendString(_ string: String, to data: inout Data) throws {
        let bytes = Data(string.utf8)
        guard bytes.count <= HotReloadAgentProtocol.maxStringBytes else {
            throw IdeaLightRunError.hotReloadUnavailable(detail: "热更新请求中的类名或路径过长。")
        }
        appendUInt32(UInt32(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if written == 0 {
                    throw POSIXError(.EPIPE)
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    private static func readExact(count: Int, from fd: Int32) throws -> Data {
        guard count >= 0, count <= HotReloadAgentProtocol.maxFrameSize else {
            throw POSIXError(.EMSGSIZE)
        }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = count
            while remaining > 0 {
                let readCount = Darwin.read(fd, pointer, remaining)
                if readCount < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if readCount == 0 {
                    throw POSIXError(.ECONNRESET)
                }
                remaining -= readCount
                pointer = pointer.advanced(by: readCount)
            }
        }
        return data
    }

    private static func readUInt8(from fd: Int32) throws -> UInt8 {
        try readExact(count: 1, from: fd)[0]
    }

    private static func readUInt32(from fd: Int32) throws -> UInt32 {
        let data = try readExact(count: 4, from: fd)
        return data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        }
    }

    private static func readString(from fd: Int32) throws -> String {
        let length = Int(try readUInt32(from: fd))
        guard length <= HotReloadAgentProtocol.maxStringBytes else {
            throw POSIXError(.EMSGSIZE)
        }
        let data = try readExact(count: length, from: fd)
        return String(decoding: data, as: UTF8.self)
    }
}

public enum HotReloadAgentEndpoint {
    /// Agent 在 premain 里监听 127.0.0.1:0 后把端口写进 0600 文件。
    /// 这里只轮询本地文件，不主动扫端口，避免误连到别的服务。
    public static func waitForPort(
        portFile: URL,
        timeout: TimeInterval,
        isCancelled: () -> Bool = { false }
    ) throws -> UInt16 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isCancelled() {
                throw IdeaLightRunError.launchCancelled(detail: "热更新启动已停止。")
            }
            if let text = try? String(contentsOf: portFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let port = UInt16(text), port > 0 {
                return port
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw IdeaLightRunError.hotReloadUnavailable(
            detail: "内置 HotReloadAgent 未在 \(Int(timeout)) 秒内就绪；请确认应用没有以禁用 Agent 的方式启动。"
        )
    }
}
