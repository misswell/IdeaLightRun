import Foundation

/// 控制台是否跟随新日志滚动：只有当前已经停在底部时才跟随，
/// 用户向上回看历史时保持当前位置。容器不足一屏时永远视为在底部。
public enum LogScrollFollow {
    public static let bottomTolerance: Double = 8

    public static func isAtBottom(
        originY: Double,
        visibleHeight: Double,
        documentHeight: Double,
        tolerance: Double = bottomTolerance
    ) -> Bool {
        let maxOrigin = documentHeight - visibleHeight
        guard maxOrigin > 0 else { return true }
        return maxOrigin - originY <= tolerance
    }
}
