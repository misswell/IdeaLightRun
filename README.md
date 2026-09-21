# IdeaLightRun

独立 macOS Java 项目启动器：读取 IntelliJ IDEA 的 Run Configuration，不打开 IDEA 就能编译并启动 Java / Spring Boot 项目。

- **环境**：macOS 13 及以上（Apple Silicon / Intel 通用二进制）；本机 JDK；项目是 Maven（有 `pom.xml` 或 `mvnw`）
- **隐私**：除用户主动点「检查更新…」外，全程 100% 本地——不联网、无后台常驻、不上传任何项目或本机信息（§64）

> 原暂定名 LightRun，已正式更名为 IdeaLightRun。文中 § 编号均指向项目需求文档。

## 安装

1. 到 [Releases](https://github.com/misswell/IdeaLightRun/releases/latest) 下载 `IdeaLightRun-<ver>-universal.zip`
2. 解压，把 **IdeaLightRun.app 拖进「应用程序」**——位置决定了以后能不能在应用内更新（见「检查更新」）
3. 双击打开即可。产物是 Developer ID 签名 + Apple 公证 + 票据已 staple，不需要右键放行，离线也能通过 Gatekeeper

项目放在「桌面 / 文稿 / 下载」里时，macOS 会照例弹一次文件夹读取授权。

## 快速上手

1. 左侧栏 **添加项目**（或把项目文件夹直接拖进侧栏）。目录需包含 `.idea`、`pom.xml` 或 `build.gradle(.kts)` 之一，否则弹窗拒绝
2. 项目下自动列出 IDEA 里已有的 Run Configuration，无需再配一遍：Main Class、Module、JDK、VM Options、Program Arguments、Spring Profiles、环境变量、Working Directory 都从 IDEA 配置读，可在「信息」页签核对
3. 选中一条 → **Run**（⌘R），界面自动切到「控制台」。它会先编译再启动，状态依次显示「解析依赖中 → 编译中 → 启动中 → 运行中」
4. **Stop**（⌘.）发 SIGTERM；进入「停止中」后出现 **Force Kill**（SIGKILL）。**Restart**（⇧⌘R）= 停掉旧进程后重新编译启动
5. 退出应用时正在跑的服务一并停掉：先 SIGTERM，最多等 2 秒再强杀（§66）

## 界面

| 区域 | 内容 |
| --- | --- |
| 左栏「项目」 | 项目列表（`扫描中…` / `N 个配置` / `扫描失败` / `待扫描`）、底部 **添加项目**；右键菜单可构建 / 重新构建 / 清理 / 重新扫描 / 移除 |
| 中栏 | 配置列表，顶栏为重新扫描 / 在 Finder 中显示 / 移除；上方摘要条显示构建系统、JDK、模块数与三个构建动作 |
| 右栏 | **信息 / 控制台 / 构建** 三个页签，顶部为 `Run` `Stop` `Force Kill` `Restart` |

配置行右侧的标记：`READY` 可启动、`WARNING` 可启动但有警告、`PLANNED` 已识别但本版本不接管、`UNSUPPORTED` 不接管（§78）。运行状态依次为：准备中 / 解析依赖中 / 编译中 / 启动中 / 运行中 / 停止中 / 已退出 (N) / 已停止 / 失败。

快捷键：**Run ⌘R**、**Stop ⌘.**、**Restart ⇧⌘R**、**构建项目 ⌘F9**、**重新构建项目 ⇧⌘F9**。「清理项目 / 停止构建 / 强制结束构建」在顶部 **构建** 菜单里，没有快捷键。顶部 **构建** 菜单的项一律不置灰：非 Maven 项目点了会弹窗说明原因，构建进行中再点则被忽略（同项目串行，§42）；摘要条和项目右键菜单里的构建三项会直接置灰，悬停提示写明「仅支持 Maven 项目；Gradle 支持在 Milestone 4 提供」。

## 什么配置能直接启动

只有 **Maven 项目**里的 **Application** 与 **Spring Boot** 两类配置。其余按情况标记：

| 标记 | 覆盖范围 |
| --- | --- |
| `PLANNED` | Compound、JAR、Maven、Gradle 类型——认得出来，本版不接管启动 |
| `UNSUPPORTED` | JUnit 与未知类型（未知字段保留在 `rawOptions` 里，不丢信息） |

两点容易踩：

- Maven 只看项目根有没有 `pom.xml`。根目录只有 `.idea`、或所有 pom 都在子目录的项目，会被判成非 Maven 项目而拒绝启动
- Gradle 项目目前只能浏览配置（Milestone 4 才支持启动）

## 构建 / 重新构建 / 清理

与 IDEA 一一对应，入口在摘要条按钮或 **构建** 菜单，输出走独立的「构建」页：

| 动作 | 实际执行 | 用途 |
| --- | --- | --- |
| 构建（⌘F9） | `mvn -B -nsu -DskipTests compile`，整个 reactor | 增量编译 |
| 重新构建（⇧⌘F9） | `mvn -B -nsu -DskipTests clean compile` | 清空产物后全量 |
| 清理 | `mvn -B clean` | 只删各模块 `target/`，不编译 |

用项目自己的 `mvnw` 时不加 `-B`（wrapper 自带进度输出）。

- 三者都不跑测试、都不带 `-pl`，构建期可 **停止构建**（SIGTERM）或 **强制结束构建**（SIGKILL）
- 清理之后 Run 仍正常：Run 的编译步骤带 `-pl -am`，会连带重新产出依赖模块的 `target/classes`（§92/§93）

## 日志与环境变量

- 控制台与构建页：等宽字体，每行前缀短时间（`时:分`，随系统区域设置），stdout 常态、stderr 红、系统消息灰，新输出始终滚到最新一行；「清空日志」只清显示，不影响进程
- 长跑服务不会吃满内存：日志在内存中保留最近 20000 行 / 10MB，超出丢弃最旧行（§37）。需要完整历史请用项目自己的日志文件
- 环境变量默认掩码 `••••••••`，勾选「显示明文」才展示取值（§28）；切换配置时自动回到掩码。CLI 对应 `--show-secrets`

## 遇到问题

**找不到 Maven。** 从 Dock/Finder 启动的 GUI 拿到的 PATH 不含 Homebrew 或用户自装的 Maven，所以不依赖 PATH，而按绝对路径枚举候选，取第一个真实可执行的文件：项目 `mvnw` → `MAVEN_HOME` / `M2_HOME` → PATH 各目录 → IDEA 自带 Maven（`/Applications`、`~/Applications` 与 Toolbox 安装位置）→ `/opt/homebrew`、`/usr/local`、`/opt/local`、`~/.sdkman` → `~/.m2/wrapper/dists`。选中了哪个会写在日志开头（Run 的控制台、构建页都是同一条解析），形如 `[IdeaLightRun] Maven: /opt/homebrew/bin/mvn（常见安装位置）`；全都不可用时，报错里按来源列出试过的全部位置，并提示给项目加 Maven Wrapper。

**无法匹配 JDK。** 解析优先级：Run Configuration 指定的 JDK → IDEA 项目 SDK → `JAVA_HOME` → 系统里已安装的最高版本（§23–25）。错误标题是「无法匹配 JDK」，正文会点出哪一级要求了什么版本，例如`运行配置要求 JDK “17”，但系统中未找到 major version 匹配的安装。`——装上对应 JDK，或回 IDEA 改配置。

**启动后立刻退出（状态 `已退出 (N)`）。** 看控制台第一条 stderr 输出，通常是 Main Class、Working Directory 或端口冲突。本应用不猜失败原因，也绝不伪造退出码。

**SNAPSHOT 依赖不是最新的。** Maven 固定带 `-nsu`：跳过逐仓库的 SNAPSHOT metadata 检查，优先用 `~/.m2` 已有依赖（与 IDEA 点 Run 的行为一致）。想强制拉最新快照，在 IDEA 或命令行执行一次 `mvn -U` 即可，应用本身不提供刷新开关。本地缺失的依赖仍会正常首次下载。

**classpath 看着不对。** 解析结果有缓存，按 fingerprint（pom / `.mvn` / wrapper / `settings.xml` / JDK）自动失效（§19/§57）。界面没有「清除缓存」按钮，需要时手工删除 `~/Library/Caches/IdeaLightRun/projects/<项目hash>/maven/<模块hash>/` 下的 `classpath.json` 与 `classpath-maven-<scope>.txt`，下次启动重新解析。

**「检查更新…」没有入口。** 只有 v0.1.6 及以后的版本带这个菜单，更早的版本请先手动装一次新版，之后的更新才都能在应用内完成。

**更新失败。** 面板每一步都说明走到哪、为什么失败、下一步做什么（标题 / 原因 / 建议三段），日志落在 `~/Library/Logs/IdeaLightRun/update.log`。最常见的是安装位置：必须装在可写目录（`/Applications` 或 `~/Applications`），从 DMG、只读位置或 App Translocation 的随机路径运行一律拒绝——把 app 拖进「应用程序」再试。安装会退出应用，正在运行的服务随之停止，面板在安装前会说明当前有几个在跑。不做权限提升，也不弹管理员密码；更新过程任一步失败都会回滚旧版本并把它重新拉起。

## 数据放在哪

- `~/Library/Application Support/IdeaLightRun/projects.json` — 添加过的项目路径
- `~/Library/Caches/IdeaLightRun/` — Maven classpath 缓存
- `~/Library/Logs/IdeaLightRun/update.log` — 更新日志
- **不写用户项目的任何文件**；`target/` 里的构建产物由 Maven 自己生成

## 命令行

CLI 与 GUI 共用 `IdeaLightRunCore` 的同一条解析、构建、启动流水线，主要用于开发期验证：

```bash
swift run IdeaLightRunCLI scan /path/to/project          # 列出所有 Run Configuration（list 为别名）
swift run IdeaLightRunCLI run /path/to/project UserApp   # 编译并启动，Ctrl-C 发 SIGTERM
swift run IdeaLightRunCLI build /path/to/project          # IDEA 的 Build Project
swift run IdeaLightRunCLI build /path/to/project --rebuild # Rebuild Project（clean compile）
swift run IdeaLightRunCLI clean /path/to/project          # Maven clean（只删 target/，不编译）
swift run IdeaLightRunCLI scan /path/to/project --json     # JSON 输出
swift run IdeaLightRunCLI scan /path/to/project --show-secrets  # 环境变量明文（默认掩码）
```

退出码：`0` 成功、`1` 解析/运行失败或 Java 进程非 0 退出、`2` 参数或命令有误、`130` 构建被 Ctrl-C 取消。

---

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

## 当前进度

已完成：Core 解析与宏、Maven 编译与 classpath、启动流水线、进程与日志、GUI 三栏、Build/Rebuild/Clean、在线更新。

待做：

- **Milestone 4** — Gradle 构建与启动
- **Milestone 5** — GUI 完整版（Compound 启动、Restart to Apply 提示、端口检测等 P1）

## 在线更新实现要点

安装要替换的正是自己，所以分两段：主进程只负责「取到并验干净的新 app」，落盘与重启交给进程外助手。

- **取版本**：`api.github.com/repos/misswell/IdeaLightRun/releases/latest` 给出 `tag_name` 与附件的 `digest`（SHA-256）；被匿名限流（403）时退回公开的 `releases/expanded_assets/<tag>` 页面解析同一份摘要。只接受 `IdeaLightRun-<ver>-universal.zip`，且必须带可解析的 sha256——**没有摘要就不下载**
- **镜像链**：`xget.xi-xu.me → ghfast.top → gh-proxy.org → github.com`。第三方源只当传输通道，不当信任来源：每个源落地后都要过 SHA-256，不过就删掉换下一个源。最近一次成功的镜像会记住并提到队首，直连成功则清掉该偏好（避免网络变好后仍绕远路）
- **主进程内校验（`UpdatePackageValidator`）**：SHA-256 → `ditto` 解包（不是 `unzip`，只有它保留权限与元数据）→ 结构自检（bundle id、可执行文件、版本号、**更新助手在位**）→ `codesign --verify --deep --strict` → TeamIdentifier → 按**语义**比对新旧 app 的 designated requirement（比文本会把合法更新判成身份变更，而这条 requirement 决定系统授权能否延续）→ `spctl --assess` → 递归清除隔离属性（漏掉它，重启后会被 App Translocation 搬到随机只读路径，每项系统授权都要重新点）
- **进程外安装（`IdeaLightRunUpdater`）**：先把助手拷出 bundle 再执行（它所在的 bundle 即将被换掉）→ 等主进程退出 → 同卷原子替换并留备份 → 直接 exec `Contents/MacOS/IdeaLightRun` 重启（不走 `open`：LaunchServices 对刚替换路径的旧记录会「返回成功却不起进程」）→ 任一步失败则回滚旧版本，并且仍然把可用的 app 拉起来

## 关键设计约束

- 不依赖 IDEA 安装目录，只读项目内配置（§113）；Maven 定位也不依赖 PATH，见「遇到问题」
- XML 宽松解析：未知字段进 `rawOptions`，未知类型标记 `unknown` 并显示为 `UNSUPPORTED`（§78）
- `$Prompt$` 等 IDEA 上下文宏不伪造，只产生 warning（§11）
- Java 启动使用 Process.arguments 数组传参，绝不走 `/bin/sh -c`（§27）
- reactor 依赖解析为 `target/classes` 而非 SNAPSHOT jar，重启即用最新代码（§92/§93）
- 同一条流水线服务 Run 与 Build/Rebuild/Clean（`ProjectToolchain`），不出现两套工具链判定
- 除「检查更新…」外 100% 本地（§64）：联网只在用户主动点菜单时发生，没有启动自查、没有定时器

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
