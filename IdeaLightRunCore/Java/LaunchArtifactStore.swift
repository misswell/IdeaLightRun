import Foundation

/// §P0-10: 启动临时产物（@argfile / manifest jar）的落点与孤儿清理。
/// 会话正常结束会自己删产物（`ManagedProcessSession` 的 temporaryArtifacts）；
/// 这里兜底清理"计划构造了、进程没起来"的遗留文件，不让缓存目录无界增长。
public enum LaunchArtifactStore {
    public static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IdeaLightRun/launch-artifacts", isDirectory: true)
    }

    /// 为一次启动生成唯一的产物文件路径（目录惰性创建）。
    public static func makeArtifactURL(suffix: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString)\(suffix)")
    }

    /// 删除超过 `age` 的遗留产物。每次启动流水线开始时调用，量级是几个文件的目录扫描。
    public static func cleanupOrphans(olderThan age: TimeInterval = 6 * 3600, now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            guard now.timeIntervalSince(modified) >= age else { continue }
            try? fm.removeItem(at: file)
        }
    }
}
