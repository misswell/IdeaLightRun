import Foundation

/// §4.1: 准备阶段与执行阶段的边界。`prepare` 只产出计划，不启动进程；
/// GUI / CLI 不再自己拼装 Java、Maven、Gradle 命令行，也不认识具体配置类型。
public indirect enum PreparedExecution: Sendable {
    case process(ExecutableLaunchPlan)
    case compound(CompoundExecutionPlan)

    /// 单个进程执行计划。Compound 由组合执行器展开，调用方不应把它硬转成单进程。
    public var processPlan: ExecutableLaunchPlan? {
        if case .process(let plan) = self { return plan }
        return nil
    }
}

public struct CompoundExecutionPlan: Sendable {
    public var name: String
    public var members: [CompoundMemberPlan]

    public init(name: String, members: [CompoundMemberPlan]) {
        self.name = name
        self.members = members
    }
}

public struct CompoundMemberPlan: Sendable {
    public var name: String
    public var configurationKey: String
    public var execution: PreparedExecution

    public init(name: String, configurationKey: String, execution: PreparedExecution) {
        self.name = name
        self.configurationKey = configurationKey
        self.execution = execution
    }
}
