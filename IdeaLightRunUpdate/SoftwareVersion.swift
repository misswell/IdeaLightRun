import Foundation

/// 点分十进制版本号。不用 semver 是因为发布通道只有 `vX.Y.Z` tag，
/// 带后缀的预发布号在这里应被判为「不可比较」而不是「更大」。
public struct SoftwareVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    private let components: [Int]

    public init?(_ value: String) {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let pieces = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty,
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              pieces.compactMap({ Int($0) }).count == pieces.count else { return nil }
        components = pieces.compactMap { Int($0) }
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func == (lhs: SoftwareVersion, rhs: SoftwareVersion) -> Bool {
        normalized(lhs.components) == normalized(rhs.components)
    }

    /// 逐段比较并补零，保证 `1.9.9 < 1.10.0`（字典序会把它判成更小）。
    public static func < (lhs: SoftwareVersion, rhs: SoftwareVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Self.normalized(components))
    }

    private static func normalized(_ components: [Int]) -> [Int] {
        var result = components
        while result.count > 1 && result.last == 0 { result.removeLast() }
        return result
    }
}
