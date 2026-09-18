import Foundation

/// Fixtures 以源码文件形式存放（含 .idea/.run 等点目录），
/// 通过 #filePath 定位，避免资源打包对点目录的处理差异。
enum Fixtures {
    static var root: URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile.deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    }

    static func url(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }
}
