# IdeaLightRun

独立 macOS Java 项目启动器：读取 IntelliJ IDEA Run Configuration，在不启动 IDEA 的前提下编译并启动 Java / Spring Boot 项目。

> 原暂定名 LightRun，已正式更名为 IdeaLightRun。§ 编号均指向项目需求文档。

## 当前进度

- [x] **Milestone 1（Core）** — 扫描 / 解析 / 宏 / Tokenizer / Module & JDK Resolver / 单测
- [x] **Milestone 2 核心（Maven）** — MavenBuildService（mvnw 优先、`-pl -am` 增量编译不 clean）、`dependency:build-classpath` classpath 解析、reactor 依赖转 `target/classes`（§92/§93 验收机制）、ClasspathCache + fingerprint 失效（§19/§57）、同项目构建串行（§42）
- [x] **Milestone 3 核心（启动）** — JavaLaunchPlan（§26）、数组传参启动（§27）、env 合并（§28）、profiles 去重注入（§29）、ProcessSession（SIGTERM→Force Kill，§32/§33）、LogRingBuffer（20000 行/10MB 上限，§37）+ 100ms 批量（§103）
- [x] **Build / Rebuild / Clean（对齐 IDEA）** — 项目级 `mvn compile` / `mvn clean compile` / `mvn clean`（整 reactor，不带 `-pl`）、独立构建控制台、可停止（SIGTERM→SIGKILL）、⌘F9 / ⇧⌘F9、CLI `build` / `clean`
- [x] **GUI** — 三栏界面 + ▶ Run / ■ Stop / ↻ Restart / Force Kill + NSTextView 控制台 + 退出时停服（§66）
- [ ] Milestone 4 — Gradle（当前 Gradle 项目仅支持浏览，启动会提示）
- [ ] Milestone 5 — GUI 完整版（Compound 启动、Restart to Apply 提示、端口检测等 P1）

## 工程结构

```text
IdeaLightRunCore/    核心库（GUI 与 CLI 共用，禁止另起一套启动逻辑）
  Domain/            RunConfiguration / JavaLaunchPlan / ProcessState / 统一错误模型
  IntelliJ/          ProjectScanner、RunConfiguration 解析（宽松 + alias）、MacroResolver、ModuleResolver
  BuildSystem/       Maven 检测/编译/classpath 解析/缓存；ProjectToolchain + ProjectBuilder（启动与构建共用一条管线）；Gradle 检测（M4 实现）
  Java/              JDKResolver、LaunchPlanBuilder、JavaLauncher 流水线
  Process/           ProcessSession（进程生命周期 + 日志捕获）
  Logging/           LogRingBuffer（环形日志缓冲）
  Utilities/         CommandLineTokenizer（禁用 /bin/sh -c）、XML 子树捕获
IdeaLightRunCLI/     开发期验证工具（scan / run / build）
IdeaLightRunApp/     SwiftUI GUI
Tests/               单元 + Maven 多模块真实集成测试（共 100 用例）+ Fixtures
```

## CLI 用法

```bash
# 扫描项目并输出所有 Run Configuration（list 为别名）
swift run IdeaLightRunCLI scan /path/to/project

# 编译并启动指定配置（前台运行，Ctrl-C 发送 SIGTERM 停止）
swift run IdeaLightRunCLI run /path/to/project UserApplication

# 项目级构建：IDEA 的 Build Project（增量）/ Rebuild Project（clean compile 全量）
swift run IdeaLightRunCLI build /path/to/project
swift run IdeaLightRunCLI build /path/to/project --rebuild

# 项目级清理：Maven clean（只删各模块 target/，不编译）
swift run IdeaLightRunCLI clean /path/to/project

# JSON 输出 / 显示环境变量明文（默认掩码 ******）
swift run IdeaLightRunCLI scan /path/to/project --json
```

GUI 侧对应「构建」菜单：构建项目 ⌘F9、重新构建项目 ⇧⌘F9、清理项目、停止构建；构建输出在详情栏的「构建」页，
与 IDEA 一样是项目级动作（作用于整个 reactor），不针对单个 Run Configuration。

## GUI 打包与发布

```bash
./scripts/build-app.sh release      # 本机包：Developer ID 签名 + hardened runtime，产物 build/IdeaLightRun.app
./scripts/distribute-app.sh         # 正式包：通用二进制 + 签名 + 公证 + staple + 校验，产物 dist/
```

正式发布走 GitHub Actions：推 `v*` tag 即自动 `swift test` → Developer ID 签名 → Apple 公证
→ staple → 创建 Release（附件 `IdeaLightRun-<ver>-universal.zip` 与 `SHA256SUMS.txt`）。
tag 之前先等 `Compile check`（push 到 main 自动跑）绿灯：它用发布同款工具链
`swift build` 全量编译，覆盖 `swift test` 不构建的 GUI target。

```bash
git tag -a v0.1.2 -m "v0.1.2" && git push origin v0.1.2
```

产物已 Developer ID 签名并公证（票据已 staple），解压双击即可打开，无需右键放行；
通用二进制（Apple Silicon + Intel），要求 macOS 13 及以上。
Maven 集成测试需要真实下载依赖，只在本地跑，CI 用 `--skip` 跳过。

## 测试

```bash
swift test    # 含真实 Maven 多模块 classpath 集成测试（无 mvn 自动跳过）
```

覆盖：RunConfigurationParser（alias / rawOptions / Before Launch）、WorkspaceParser（流式、只取 RunManager、跳过模板）、ProjectScanner（§7 来源优先级去重、§6 深度上限 4、忽略目录）、MacroResolver（§11 全部宏与 IDEA 上下文变量）、CommandLineTokenizer（§72 参数集）、ModuleResolver（§13 五种方式）、JDKResolver（§23–25 优先级与 major version 模糊匹配）、LaunchPlanBuilder（§26–§29）、LogRingBuffer（§37 上限）、ProcessSession（启动/停止/日志捕获、退出以进程自身为准）、MavenLocator（Dock 启动无 PATH 时的绝对路径枚举）、项目级 Build/Rebuild/Clean 参数与取消语义、ClasspathCache + reactor 归一化（§18/§19/§57）、Maven 多模块真实集成（§92/§93）。

## 关键设计约束（当前已落实）

- 不修改用户项目任何文件；自有数据写入 `~/Library/Caches/IdeaLightRun` 与 `~/Library/Application Support/IdeaLightRun`。
- XML 宽松解析：未知字段进 `rawOptions`，未知类型标记 `unknown` 并显示为 Unsupported（§78）。
- `$Prompt$` 等 IDEA 上下文宏不伪造，产生 warning（§11）。
- Java 启动使用 Process.arguments 数组传参，绝不走 `/bin/sh -c`（§27）。
- Maven 默认加 `-nsu`：跳过 SNAPSHOT 远程更新检查，优先使用 `~/.m2` 已有依赖（与 IDEA 点 Run 的行为一致）；本地缺失的依赖仍会正常首次下载。需要强制拉取最新快照时，在 IDEA/Maven 里更新一次即可。
- reactor 依赖解析为 `target/classes` 而非 SNAPSHOT jar，重启即用最新代码（§92/§93）。
- Build / Rebuild / Clean 与 IDEA 一一对应：Build = 整 reactor `compile`（增量），Rebuild = `clean compile`（全量），Clean = `clean`（只清空产物、不编译，因此不带 `-DskipTests`）；都不带 `-pl`、不跑测试，且不清 classpath 缓存（`clean` 只删 `target/`，依赖坐标未变则缓存仍有效，缓存另有 fingerprint 守护）。Clean 之后 Run 仍正常：Run 的 compile 步骤带 `-pl -am`，会连带重新产出依赖模块的 `target/classes`。Run 与三者共用同一条工具链解析管线（`ProjectToolchain`）。
- Maven 定位不依赖 PATH：GUI 从 Dock/Finder 启动时环境变量里没有 Homebrew 或用户自装的 Maven，故按绝对路径枚举候选（含 IDEA 自带 Maven），逐个 `--version` 探活后取第一个可用的。
- 不依赖 IDEA 安装目录，只读项目内配置（§113）。
- 100% 本地，无网络，无后台常驻（§64）。
