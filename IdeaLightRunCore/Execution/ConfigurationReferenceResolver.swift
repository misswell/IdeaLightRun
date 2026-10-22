import Foundation

/// 运行配置引用（Compound 成员、Before Launch 的 Run Another Configuration）
/// 共用的解析规则：名字必须存在；引用带 type 时类型也必须一致。
/// 两边各写一份是之前同名类型引用被静默换成另一套语义的来源。
public enum ConfigurationReferenceResolver {
    public enum Resolution: Equatable, Sendable {
        case found(RunConfiguration)
        case notFound
        case typeMismatch
    }

    /// - Parameter allowNameFallback: IDEA 的 Compound 实际按名字找成员，type 只用于同名消歧。
    ///   配置类型改过之后旧 `toRun` 里的 type 会过期，此时唯一的同名配置仍是用户当初选的那一个。
    ///   Before Launch 的引用保持严格匹配：构建任务不能被静默换成另一套语义。
    public static func resolve(
        name: String,
        type: String?,
        in configurations: [RunConfiguration],
        allowNameFallback: Bool = false
    ) -> Resolution {
        let sameName = configurations.filter { $0.name == name }
        guard !sameName.isEmpty else { return .notFound }
        if let type, !type.isEmpty {
            if let matchesType = sameName.first(where: { $0.type.ideaTypeRaw == type }) {
                return .found(matchesType)
            }
            if allowNameFallback, sameName.count == 1 {
                return .found(sameName[0])
            }
            return .typeMismatch
        }
        return .found(sameName[0])
    }
}
