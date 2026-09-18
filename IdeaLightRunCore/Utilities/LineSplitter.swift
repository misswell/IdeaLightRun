import Foundation

/// 流式按行切分：处理跨 chunk 的半行（含 UTF-8 多字节截断问题——只解析完整行）。
public struct LineSplitter {
    private var remainder: [UInt8] = []

    public init() {}

    public mutating func feed(_ data: Data) -> [String] {
        remainder.append(contentsOf: data)
        var lines: [String] = []
        var start = 0
        for index in remainder.indices where remainder[index] == 0x0A {
            var line = Array(remainder[start..<index])
            if line.last == 0x0D {
                line.removeLast()
            }
            lines.append(String(decoding: line, as: UTF8.self))
            start = index + 1
        }
        remainder = Array(remainder[start...])
        return lines
    }

    /// 进程结束时冲刷最后一段不带换行的内容。
    public mutating func finish() -> String? {
        guard !remainder.isEmpty else { return nil }
        var line = remainder
        if line.last == 0x0D {
            line.removeLast()
        }
        remainder = []
        return String(decoding: line, as: UTF8.self)
    }
}
