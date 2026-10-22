import Foundation

/// §4.1: 准备阶段与执行阶段的边界。`prepare` 只产出计划，不启动进程；
/// GUI / CLI 不再自己拼装 Java、Maven、Gradle 命令行，也不认识具体配置类型。
public indirect enum PreparedExecution: Sendable {
    case process(ExecutableLaunchPlan)
    case compound(CompoundExecutionPlan)
    /// 测试执行：底层仍是一个进程，但终态还要解释测试结果并输出汇总。
    case test(TestExecutionPlan)

    /// 单个进程执行计划。Compound 由组合执行器展开，调用方不应把它硬转成单进程。
    public var processPlan: ExecutableLaunchPlan? {
        switch self {
        case .process(let plan):
            return plan
        case .test(let plan):
            return plan.process
        case .compound:
            return nil
        }
    }
}

/// JUnit 测试执行计划。命令由构建系统适配器生成，
/// `filters` 是已按构建系统语法转换的精确筛选（空表示模块内全部测试）。
public struct TestExecutionPlan: Sendable {
    public var process: ExecutableLaunchPlan
    public var buildSystem: BuildSystemKind
    public var moduleName: String
    /// 界面与汇总用的目标描述（类名 / 方法 / 包 / 目录 / 整个模块）。
    public var targetDescription: String
    public var filters: [String]

    public init(
        process: ExecutableLaunchPlan,
        buildSystem: BuildSystemKind,
        moduleName: String,
        targetDescription: String,
        filters: [String]
    ) {
        self.process = process
        self.buildSystem = buildSystem
        self.moduleName = moduleName
        self.targetDescription = targetDescription
        self.filters = filters
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
