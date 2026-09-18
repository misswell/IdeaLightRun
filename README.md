# IdeaLightRun

独立 macOS Java 项目启动器：读取 IntelliJ IDEA Run Configuration，在不启动 IDEA 的前提下编译并启动 Java / Spring Boot 项目。

> IdeaLightRun 为暂定项目名。完整方案见项目需求文档（§ 编号均指向该文档）。

## 当前进度

- [x] **Milestone 1（Phase 1: Core）** — 扫描 / 解析 / 宏 / Tokenizer / Module & JDK Resolver / CLI / 单测
- [x] **GUI v0.1（提前交付浏览版）** — 三栏界面：项目侧栏（添加/拖入/持久化）→ 配置列表（状态徽标）→ 详情（JDK/宏解析、env 掩码、警告）。打包：`./scripts/build-app.sh` → `build/IdeaLightRun.app`
- [ ] Milestone 2 — MavenAdapter、MavenReactorGraph、MavenClasspathResolver、ClasspathCache
- [ ] Milestone 3 — JavaLaunchPlan、JavaLauncher、ProcessManager、LogEngine（`idealightrun run`，GUI 的 ▶/■ 依赖此项）
- [ ] Milestone 4 — Gradle
- [ ] Milestone 5 — SwiftUI GUI 完整版（Run/Stop/Restart、Compound、日志控制台）

## 工程结构

```text
IdeaLightRunCore/    核心库（GUI 与 CLI 共用，禁止 GUI 另起一套启动逻辑）
  Domain/        RunConfiguration / ProjectModule / JDK / IdeaLightRunError 统一模型
  IntelliJ/      ProjectScanner、RunConfiguration 解析（宽松 + alias）、MacroResolver、ModuleResolver
  BuildSystem/   Maven / Gradle 检测与轻量结构读取（reactor classpath 在 M2/M4 实现）
  Java/          JDKResolver（/usr/libexec/java_home + JAVA_HOME + major version 匹配）
  Utilities/     CommandLineTokenizer（禁用 /bin/sh -c）、XML 子树捕获
IdeaLightRunCLI/     开发期验证工具（不面向普通用户发布）
IdeaLightRunApp/     SwiftUI 占位（Phase 5 才做 UI）
Tests/           单元测试 + Fixtures（Maven 单/多模块、Gradle、深度边界）
```

## CLI 用法

```bash
# 扫描项目并输出所有 Run Configuration（list 为别名）
swift run IdeaLightRunCLI scan /path/to/project

# JSON 输出 / 显示环境变量明文（默认掩码 ******）
swift run IdeaLightRunCLI scan /path/to/project --json
swift run IdeaLightRunCLI scan /path/to/project --show-secrets
```

## 测试

```bash
swift test
```

覆盖：RunConfigurationParser（alias / rawOptions / Before Launch）、WorkspaceParser（流式、只取 RunManager、跳过模板）、ProjectScanner（§7 来源优先级去重、§6 深度上限 4、忽略目录）、MacroResolver（§11 全部宏与 IDEA 上下文变量）、CommandLineTokenizer（§72 参数集）、ModuleResolver（§13 四种方式 + mainClass fallback）、JDKResolver（§23–25 优先级与 major version 模糊匹配）。

## 关键设计约束（当前已落实）

- 不修改用户项目任何文件；自有数据一律不写入项目目录。
- XML 宽松解析：未知字段进 `rawOptions`，未知类型标记 `unknown` 并显示为 Unsupported（§78）。
- `$Prompt$` 等 IDEA 上下文宏不伪造，产生 warning（§11）。
- 不依赖 IDEA 安装目录，只读项目内配置（§113）。
- 100% 本地，无网络，无后台常驻（§64）。
