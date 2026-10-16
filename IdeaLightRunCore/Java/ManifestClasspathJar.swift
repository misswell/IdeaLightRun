import Foundation

/// §P0-10: SHORTEN_COMMAND_LINE=JAR_MANIFEST 的临时 manifest jar。
///
/// 纯 Swift 写一个 stored（不压缩）zip，只含 `META-INF/MANIFEST.MF` 一个条目，
/// `Class-Path` 逐条列出 classpath（`file:` URL、72 字节行折叠）。JDK 的
/// URLClassLoader 会把 manifest Class-Path 并进实际 classpath——这是 JDK 8
/// 唯一可用的缩短手段（@argfile 要 JDK 9+）。产物只有几百字节，压缩没有意义；
/// 不引第三方 zip 库，CRC32 自己算。
public enum ManifestClasspathJar {
    /// 生成 MANIFEST.MF 内容。条目做 URL 百分号编码（空格、非 ASCII），
    /// 行长按 JAR 规范折到 72 字节以内。
    static func manifestContent(classpath: [String]) -> Data {
        let entries = classpath.map { "file:" + percentEncodePath($0) }
        let value = "Class-Path: " + entries.joined(separator: " ")
        return Data(("Manifest-Version: 1.0\r\nCreated-By: IdeaLightRun\r\n" + fold(value) + "\r\n").utf8)
    }

    /// 写出 zip 文件（local header + central directory + EOCD，单条目）。
    public static func write(classpath: [String], to url: URL) throws {
        let manifest = manifestContent(classpath: classpath)
        let name = Array("META-INF/MANIFEST.MF".utf8)
        let crc = crc32(manifest)
        // 固定时间戳即可：产物只服务一次启动，时间没有语义。
        let dosTime = UInt16(0)          // 00:00:00
        let dosDate = UInt16(0x5821)     // 2024-01-01

        var local = Data()
        local += u32(0x04034b50)                     // local file header signature
        local += u16(20) + u16(0) + u16(0)           // version needed, flags, method=stored
        local += u16(dosTime) + u16(dosDate)
        local += u32(crc)
        local += u32(UInt32(manifest.count)) + u32(UInt32(manifest.count))
        local += u16(UInt16(name.count)) + u16(0)    // name length, extra length
        local += Data(name) + manifest

        var central = Data()
        central += u32(0x02014b50)                   // central directory signature
        central += u16(20) + u16(20) + u16(0) + u16(0)
        central += u16(dosTime) + u16(dosDate)
        central += u32(crc)
        central += u32(UInt32(manifest.count)) + u32(UInt32(manifest.count))
        central += u16(UInt16(name.count)) + u16(0) + u16(0) + u16(0) + u16(0)
        central += u32(0)                            // external attributes
        central += u32(0)                            // local header offset
        central += Data(name)

        var eocd = Data()
        eocd += u32(0x06054b50)                      // end of central directory
        eocd += u16(0) + u16(0) + u16(1) + u16(1)
        eocd += u32(UInt32(central.count)) + u32(0) + u16(0)

        try (local + central + eocd).write(to: url, options: .atomic)
    }

    // MARK: - 内部

    /// JAR 规范：任何行（含续行）最长 72 字节，续行以单个空格开头。
    /// Class-Path 值经百分号编码后是纯 ASCII，按字节切分安全。
    static func fold(_ value: String) -> String {
        let bytes = Array(value.utf8)
        guard bytes.count > 72 else { return value }
        var lines: [String] = []
        var index = 0
        while index < bytes.count {
            let limit = index == 0 ? 72 : 71
            let end = min(index + limit, bytes.count)
            lines.append(String(decoding: bytes[index..<end], as: UTF8.self))
            index = end
        }
        return lines.joined(separator: "\r\n ")
    }

    /// Class-Path 条目是 URL：只保留 URL 里绝对安全的字符，其余全部百分号编码
    /// （包括空格、`#`、`?`、非 ASCII——按 UTF-8 编码）。
    static func percentEncodePath(_ path: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-~")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    static func u16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    static func u32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// 标准 CRC-32（IEEE 802.3，zip 使用的多项式）。纯 Swift 实现，
    /// 产物大小只有几百字节，不需要为它引 zlib。
    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var value = UInt32(i)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            table[i] = value
        }
        return table
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32(0xFFFFFFFF)
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
