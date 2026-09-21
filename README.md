# IdeaLightRun

独立 macOS Java 项目启动器：读取 IntelliJ IDEA 的 Run Configuration，不打开 IDEA 就能编译并启动 Java / Spring Boot 项目。

- **下载**：[Releases](https://github.com/misswell/IdeaLightRun/releases/latest) 里的 `IdeaLightRun-<ver>-universal.zip`。Developer ID 签名 + Apple 公证、票据已 staple，解压拖进「应用程序」后直接双击就能打开，不需要右键放行
- **环境**：macOS 13 及以上（Apple Silicon / Intel 通用二进制）；本机 JDK；Maven 或项目内的 `mvnw`
- **隐私**：除用户主动点「检查更新…」外，全程 100% 本地——不联网、无后台常驻、不上传任何项目或本机信息（§64）

> 原暂定名 LightRun，已正式更名为 IdeaLightRun。文中 § 编号均指向项目需求文档。

## 快速上手

1. 左侧栏「添加项目」（或把项目文件夹直接拖进来），选包含 `.idea` 或 `pom.xml` 的目录
2. 项目下自动列出 IDEA 里已有的 Run Configuration；标 `UNSUPPORTED` 的是暂不接管的类型（§78）
3. 选中一条 → **运行 ▶**；**停止 ■** 发 SIGTERM，停止过程中按钮变成 **Force Kill**（SIGKILL）；**重启 ↻** 停掉旧进程后重新编译启动
4. 项目级动作在详情栏：**构建**（增量，⌘F9）/ **重新构建**（clean compile，⇧⌘F9）/ **清理**（`mvn clean`），输出走独立的「构建」页
5. 升级：菜单 **IdeaLightRun ▸ 检查更新…**

## 当前进度

已完成：

- **Milestone 1（Core）** — 扫描 / 解析 / 宏 / Tokenizer / Module & JDK Resolver / 单测
- **Milestone 2 核心（Maven）** — MavenBuildService（mvnw 优先、`-pl -am` 增量编译不 clean）、`dependency:build-classpath` classpath 解析、reactor 依赖转 `target/classes`（§92/§93）、ClasspathCache + fingerprint 失效（§19/§57）、同项目构建串行（§42）
- **Milestone 3 核心（启动）** — JavaLaunchPlan（§26）、数组传参启动（§27）、env 合并（§28）、profiles 去重注入（§29）、ProcessSession（SIGTERM→Force Kill，§32/§33）、LogRingBuffer（20000 行 / 10MB 上限，§37）+ 100ms 批量（§103）
- **Build / Rebuild / Clean（对齐 IDEA）** — 整 reactor 的 `mvn compile` / `mvn clean compile` / `mvn clean`、独立构建控制台、可停止（SIGTERM→SIGKILL）、CLI `build` / `clean`
- **GUI** — 三栏界面 + 运行 ▶ / 停止 ■ / 重启 ↻ / Force Kill + NSTextView 控制台 + 退出时停服（§66）
- **在线更新** — 「检查更新…」→ GitHub Releases → 镜像链下载 + SHA-256 校验 + 签名与身份校验 → 进程外原子替换并重启，失败自动回滚

待做：

- **Milestone 4** — Gradle（当前 Gradle 项目仅支持浏览，启动会提示）
- **Milestone 5** — GUI 完整版（Compound 启动、Restart to Apply 提示、端口检测等 P1）

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
IdeaLightRunUpdate/  在线更新内核（版本比较、发布解析、镜像下载、产物与签名校验、助手参数契约）
IdeaLightRunUpdater/ 进程外安装助手（主 app 退出后替换 bundle 并重启，失败回滚）
IdeaLightRunCLI/     开发期验证工具（scan / run / build / clean）
IdeaLightRunApp/     SwiftUI GUI
Tests/               单元 + Maven 多模块真实集成测试（共 138 用例）+ Fixtures
```

## CLI 用法

CLI 是开发期验证工具，与 GUI 共用 `IdeaLightRunCore` 那一条流水线（同一套解析、构建与启动逻辑）。

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

## 在线更新

### 用户视角

入口只有一个：菜单 **IdeaLightRun ▸ 检查更新…**（§64 不做启动自查，也没有后台定时器）。面板会说明走到哪一步、为什么失败、下一步做什么；日志落在 `~/Library/Logs/IdeaLightRun/update.log`。

前提与限制：

- 必须装在可写目录（`/Applications` 或 `~/Applications`）；DMG、只读位置、App Translocation 一律拒绝
- 更新会退出应用，正在运行的 Java 服务随之停止——面板在安装前会说明当前有几个在跑
- 不做权限提升：不用 Authorization Services，也不弹管理员密码；装不进可写位置就是不可自更新
- **从 v0.1.6 起才内置更新助手**：更早的版本点更新会提示「缺少更新助手」，需要手动装一次 0.1.6，之后的更新才都能在应用内完成

### 实现要点

安装要替换的正是自己，所以分两段：主进程只做「取到并验干净的新 app」，落盘与重启交给进程外助手。

- **取版本**：`api.github.com/repos/misswell/IdeaLightRun/releases/latest` 给出 `tag_name` 与附件的 `digest`（SHA-256）；被匿名限流（403）时退回公开的 `releases/expanded_assets/<tag>` 页面解析同一份摘要。只接受 `IdeaLightRun-<ver>-universal.zip`，且必须带可解析的 sha256——**没有摘要就不下载**
- **镜像链**：`xget.xi-xu.me → ghfast.top → gh-proxy.org → github.com`。第三方源只当传输通道，不当信任来源：每个源落地后都要过 SHA-256，不过就删掉换下一个源。最近一次成功的镜像会记住并提到队首，直连成功则清掉该偏好（避免网络变好后仍绕远路）
- **主进程内校验（`UpdatePackageValidator`）**：SHA-256 → `ditto` 解包（不是 `unzip`，只有它保留权限与元数据）→ 结构自检（bundle id、可执行文件、版本号、**更新助手在位**）→ `codesign --verify --deep --strict` → TeamIdentifier → 按**语义**比对新旧 app 的 designated requirement（比文本会把合法更新判成身份变更，而这条 requirement 决定系统授权能否延续）→ `spctl --assess` → 递归清除隔离属性（漏掉它，重启后会被 App Translocation 搬到随机只读路径，每项系统授权都要重新点）
- **进程外安装（`IdeaLightRunUpdater`）**：先把助手拷出 bundle 再执行（它所在的 bundle 即将被换掉）→ 等主进程退出 → 同卷原子替换并留备份 → 直接 exec `Contents/MacOS/IdeaLightRun` 重启（不走 `open`：LaunchServices 对刚替换路径的旧记录会「返回成功却不起进程」）→ 任一步失败则回滚旧版本，并且仍然把可用的 app 拉起来

## 打包与发布

```bash
./scripts/build-app.sh release      # 本机包：Developer ID 签名 + hardened runtime，产物 build/IdeaLightRun.app
./scripts/distribute-app.sh         # 正式包：通用二进制 + 签名 + 公证 + staple + 校验，产物 dist/
```

正式发布走 GitHub Actions：推 `v*` tag 即自动 `swift test` → Developer ID 签名 → Apple 公证 → staple → 创建 Release（附件 `IdeaLightRun-<ver>-universal.zip` 与 `SHA256SUMS.txt`）。

**打 tag 前必须先等 `Compile check`（push 到 main 自动跑）绿灯**：它用发布同款工具链 `swift build` 全量编译，覆盖 `swift test` 不构建的 GUI target——CI runner 是旧的 Xcode 15 / Swift 5.10，本机 Xcode 26 能过的写法在它上面是编译错误，而 tag 推上去就作废不了。

```bash
git tag -a v<下一个版本号> -m "v<下一个版本号>" && git push git@github.com:misswell/IdeaLightRun.git v<下一个版本号>
```

## 测试

```bash
swift test                                        # 本地全量：138 用例
swift test --skip MavenClasspathIntegrationTests  # CI 集合：135 用例（跳过那 3 个要真实下载依赖的）
```

覆盖范围：

- **解析层** — RunConfigurationParser（alias / rawOptions / Before Launch）、WorkspaceParser（流式、只取 RunManager、跳过模板）、ProjectScanner（§7 来源优先级去重、§6 深度上限 4、忽略目录）、MacroResolver（§11 全部宏与 IDEA 上下文变量）、ModuleResolver（§13 五种方式）、JDKResolver（§23–25 优先级与 major version 模糊匹配）
- **构建与启动** — LaunchPlanBuilder（§26–§29）、CommandLineTokenizer（§72 参数集）、ClasspathCache + reactor 归一化（§18/§19/§57）、MavenLocator（Dock 启动无 PATH 时的绝对路径枚举）、项目级 Build/Rebuild/Clean 参数与取消语义、Maven 多模块真实集成（§92/§93）
- **进程与日志** — ProcessSession（启动/停止/日志捕获、退出以进程自身为准）、LogRingBuffer（§37 上限）
- **在线更新** — 版本比较与 fail-closed、发布元数据解析（JSON 与 expanded_assets 两条路径）、镜像链顺序与回退/取消/坏文件删除、更新助手参数契约与重启路径、designated requirement 解析与语义判定，以及把产物名 / bundle id / Team / 助手落点钉到 `scripts/` 与 `release.yml` **原文**的防漂移断言

## 关键设计约束（当前已落实）

- 不修改用户项目任何文件；自有数据写入 `~/Library/Caches/IdeaLightRun` 与 `~/Library/Application Support/IdeaLightRun`
- 不依赖 IDEA 安装目录，只读项目内配置（§113）
- XML 宽松解析：未知字段进 `rawOptions`，未知类型标记 `unknown` 并显示为 Unsupported（§78）
- `$Prompt$` 等 IDEA 上下文宏不伪造，产生 warning（§11）
- Java 启动使用 Process.arguments 数组传参，绝不走 `/bin/sh -c`（§27）
- Maven 默认加 `-nsu`：跳过 SNAPSHOT 远程更新检查，优先用 `~/.m2` 已有依赖（与 IDEA 点 Run 的行为一致）；本地缺失的依赖仍会正常首次下载，需要强制拉最新快照时在 IDEA/Maven 里更新一次即可
- reactor 依赖解析为 `target/classes` 而非 SNAPSHOT jar，重启即用最新代码（§92/§93）
- Maven 定位不依赖 PATH：GUI 从 Dock/Finder 启动时环境里没有 Homebrew 或用户自装的 Maven，故按绝对路径枚举候选（含 IDEA 自带 Maven），逐个 `--version` 探活后取第一个可用的
- Build / Rebuild / Clean 与 IDEA 一一对应：Build = 整 reactor `compile`，Rebuild = `clean compile`，Clean = `clean`（只清空产物、不编译，因此不带 `-DskipTests`）。三者都不带 `-pl`、不跑测试，也不清 classpath 缓存——`clean` 只删 `target/`，依赖坐标未变则缓存仍有效，缓存另有 fingerprint 守护。Clean 之后 Run 仍正常：Run 的 compile 步骤带 `-pl -am`，会连带重新产出依赖模块的 `target/classes`。Run 与三者共用同一条工具链解析管线（`ProjectToolchain`）
- 除「检查更新…」外 100% 本地（§64）：联网只在用户主动点菜单时发生，没有启动自查、没有定时器、不上传任何项目或本机信息
