# IdeaLightRun

独立 macOS Java 项目启动器：读取 IntelliJ IDEA 的 Run Configuration，不打开 IDEA 就能编译并启动 Java / Spring Boot 项目，直接运行 Maven 配置与 JUnit 测试，也能直接启动已构建的 JAR。

- **环境**：macOS 13 及以上（Apple Silicon / Intel 通用二进制）；本机 JDK；Application / Spring Boot / Maven / JUnit 配置需项目是 Maven（`pom.xml` / `mvnw`）或 Gradle（`settings.gradle(.kts)` / `build.gradle(.kts)` / `gradlew`），JAR Application 只要求 JAR 已构建
- **隐私**：除用户主动点「检查更新…」外，全程 100% 本地——不联网、无后台常驻、不上传任何项目或本机信息（§64）

> 原暂定名 LightRun，已正式更名为 IdeaLightRun。文中 § 编号均指向项目需求文档。

## 安装

1. 到 [Releases](https://github.com/misswell/IdeaLightRun/releases/latest) 下载 `IdeaLightRun-<ver>-universal.zip`
2. 解压，把 **IdeaLightRun.app 拖进「应用程序」**——位置决定了以后能不能在应用内更新（见「检查更新」）
3. 双击打开即可。产物是 Developer ID 签名 + Apple 公证 + 票据已 staple，不需要右键放行，离线也能通过 Gatekeeper

项目放在「桌面 / 文稿 / 下载」里时，macOS 会照例弹一次文件夹读取授权。

## 快速上手

1. 左侧栏 **添加项目**（或把项目文件夹直接拖进侧栏）。目录需包含 `.idea`、`pom.xml`、`settings.gradle(.kts)` 或 `build.gradle(.kts)` 之一，否则弹窗拒绝
2. 项目下自动列出 IDEA 里已有的 Run Configuration，无需再配一遍：Main Class 或 JAR Path、Module、JDK、VM Options、Program Arguments、Spring Profiles、环境变量、Working Directory 都从 IDEA 配置读，可在「信息」页签核对
3. 选中一条 → **Run**（⌘R），界面自动切到「控制台」。Run 按该配置的 Before Launch 执行构建：IDEA 里勾了 Make / Build Project 才会先编译，勾了 "Do not build before run" 则直接启动。Java / Spring Boot 的状态依次显示「解析依赖中 → 编译中（如有）→ 启动中 → 运行中」，JAR Application 直接进入「启动中」
4. **Stop**（⌘.）发 SIGTERM；进入「停止中」后出现 **Force Kill**（SIGKILL）。**Restart**（⇧⌘R）= 停掉旧进程后按同一配置重新准备并启动
5. 退出应用时若仍有任务在跑，会先弹窗确认：**停止并退出**（默认；先 SIGTERM，最多等 2 秒再强杀，§66）、**强制结束**（直接 SIGKILL）或**取消**留在应用。没有任务在跑时直接退出，不打扰；在线更新安装前的自动退出也不二次确认（更新面板里已说明会停掉服务）。

## 界面

| 区域 | 内容 |
| --- | --- |
| 左栏「项目」 | 项目列表（`扫描中…` / `N 个配置` / `扫描失败` / `待扫描`）、底部 **添加项目**；右键菜单可构建 / 重新构建 / 清理 / 重新扫描 / 移除。有活动时文件夹图标换成状态点：**绿**=有服务运行中、**黄**=正在编译或启动、**红**=最近一次运行失败（悬停看说明；无活动显示文件夹图标） |
| 中栏 | 配置列表，顶栏为重新扫描 / 打开（图标即动作：默认访达图标，点击直接用访达打开项目目录；从下拉换成其他应用后图标跟着换成该应用并记住，下次点击直接用它打开。下拉列表固定顺序：访达、VS Code、Cursor、Zed、Default app、Terminal、iTerm2、Ghostty、Xcode、IntelliJ IDEA——未安装的置灰，Default app 即用系统默认处理者，访达始终在列表首位）/ 移除；上方摘要条显示构建系统、JDK、模块数、当前 git 分支与三个构建动作。扫描中读不了的文件、损坏的 XML 会在列表上方显示诊断条（数量 + 严重程度，展开可查看文件路径并在访达中定位），不再静默丢配置 |

顶栏垃圾桶（以及侧栏右键菜单的「移除」）都会先弹二次确认，说明「只移除记录、不删磁盘文件」；该项目若有服务在跑，还会提示有几个会被一并停止。确认前不会动任何东西。
| 右栏 | **信息 / 控制台 / 构建** 三个页签；顶栏分两行——第一行是当前配置名与类型，第二行是 `Run` `Stop` `Force Kill` `Restart` 与页签切换 |

配置行右侧的标记：`READY` 可启动、`WARNING` 可启动但有警告、`PLANNED` 已识别但本版本不接管、`UNSUPPORTED` 不接管（§78）。标记由 Core 统一计算（类型、项目构建系统、缺失字段、Before Launch 任务都会影响结果），GUI 与 CLI 不各自判断。运行状态依次为：准备中 / 解析依赖中 / 编译中 / 启动中 / 运行中 / 停止中 / 已退出 (N) / 已停止 / 失败。运行中探测到监听端口时，状态文字左侧会显示 `:8080 :8081` 这样的端口列表（每 3 秒刷新，进程退出即清空），悬停看完整列表。

中栏被压窄时按优先级让位：状态文字与端口永远完整显示（与配置名同级，不参与压缩；端口最多占 140pt，超长部分省略号收尾），配置名其次保留，副标题最先被省略；三者都能悬停看全称。此前端口优先级排在副标题之后，Spring Boot 的全限定类名普遍超宽，端口每轮布局都被压成零宽——表现为「明明在运行却看不到端口」。

运行中的服务会自动探测本机监听端口：只读本机 `lsof`，每 3 秒一次，进程结束后即停（不涉网，§64 不受影响）。信息页运行横幅显示「端口 …」，首次探测到端口或端口集合变化时，控制台也会记录一条灰色系统消息；信息页同时列出可运行性问题与扫描诊断（数量、严重程度、文件、原因和建议处理方式）。

快捷键：**Run ⌘R**、**Stop ⌘.**、**Restart ⇧⌘R**、**构建项目 ⌘F9**、**重新构建项目 ⇧⌘F9**。「清理项目 / 停止构建 / 强制结束构建」在顶部 **构建** 菜单里，没有快捷键。顶部 **构建** 菜单的项一律不置灰：项目根既没有 Maven 也没有 Gradle 构建文件时点了会弹窗说明原因，构建进行中再点则被忽略（同项目串行，§42）；摘要条和项目右键菜单里的构建三项会直接置灰，悬停提示写明「项目根未找到 Maven 或 Gradle 构建文件」。

## 什么配置能直接启动

**Maven 或 Gradle 项目**里的 **Application**、**Spring Boot**、**Maven**、**JUnit**，**JAR Application**（不要求项目是 Maven / Gradle），以及引用这些配置的 **Compound**。

| 标记 | 覆盖范围 |
| --- | --- |
| `PLANNED` | Gradle 运行配置（类型为 Gradle、直接执行 task 的配置）——认得出来，本版不接管启动 |
| `UNSUPPORTED` | 未知类型（未知字段保留在 `rawOptions` 里，不丢信息）；JUnit 的标签 / Unique ID 目标；Compound 引用了缺失、类型不匹配或不支持启动的成员时也归到这里，信息页写明具体是哪个成员 |

`READY` / `WARNING` 由 Core 按项目实际情况计算：缺 Main Class / JAR Path / Maven goals、启用了暂不支持的字段（如 Maven 自定义 `mavenHome`、`userSettingsFile`、`multimoduleDir`，或 Maven 配置指定了 Project JDK / JAVA_HOME 之外的 JRE）、启用了暂不支持的 Before Launch 任务、引用了不存在的配置都会阻止启动；模块缺失、宏无法解析等只产生警告。项目同时存在 `pom.xml` 与 Gradle 构建文件时，先看配置所属模块目录里的构建脚本；仍无法判断时固定使用 Maven 并显示 `WARNING`，不依赖偶然的判断顺序。Before Launch 里的 Maven Goal 只能用于 Maven 项目、Gradle Task 只能用于 Gradle 项目，错配会阻止启动而不是静默改跑另一套命令。

JAR Application 按 IDEA 的语义启动：`java [VM Options] -jar <JAR Path> [Program Arguments]`。`JAR_PATH` 支持 `$PROJECT_DIR$` / `$MODULE_DIR$` 等宏，未填 Working Directory 时默认项目根；`ALTERNATIVE_JRE_PATH` 启用时优先使用该 JDK。JAR 尚不存在只显示 `WARNING`（Before Launch 可能生成它），真正启动前会再次校验，届时仍缺失则失败。Before Launch 里有 Build / Build Project / Maven goal / Gradle task 时，才要求可用的 Maven 或 Gradle 与 Module。

Compound 按 IDEA 的语义启动：成员按配置里保存的顺序逐个准备（每个成员执行自己的 Before Launch），全部成功后才一起启动；嵌套 Compound 展开成叶子配置，运行时只有真实进程。每个成员有独立的 PID、日志、端口与状态，控制台可在「全部 / 各成员」之间切换。Run 启动整组，Stop / Force Kill 停止整组；任一成员异常退出会停止其余成员，不会留下半组孤儿进程。Compound 自身的 Before Launch 任务、引用缺失或类型不匹配的成员、跨层重复引用同一配置都会阻止启动，不会静默跳过。

三点容易踩：

- Maven 只看项目根有没有 `pom.xml`。根目录只有 `.idea`、或所有 pom 都在子目录的项目，会被判成非 Maven 项目而拒绝启动。Gradle 项目根只要有 `settings.gradle(.kts)` 或 `build.gradle(.kts)` 即可；只有 `settings.gradle` 的聚合工程也能启动
- JAR Application 只有在 Before Launch 需要构建时才依赖 Maven / Gradle；单纯运行已有 JAR 不需要
- Gradle 运行配置（类型为 Gradle、在 IDEA 里直接执行 task 的配置）目前是 `PLANNED`；Application / Spring Boot / JAR / Maven / JUnit 配置在 Gradle 或 Maven 项目里已经可以直接 Run

## Maven 配置与 JUnit 测试

**Maven 配置**按 IDEA 保存的参数直接启动：goals、Command line、Profiles、Runner properties、`-pl` 工程列表，以及离线 / 更新快照 / 线程 / 输出级别等 General Settings 都会翻译成对应参数；VM Options 进 `MAVEN_OPTS`，环境变量与 Working Directory 沿用配置。使用项目 `mvnw` 时不加 `-B`；直接运行不追加 `-nsu`，保留与 IDEA 点 Run 相同的 SNAPSHOT 更新语义。Working Directory 默认项目根，`$PROJECT_DIR$` / `$MODULE_DIR$` 等宏按模块解析；`$Prompt$` 这类依赖 IDEA 上下文的宏会阻止启动，不会带着原文执行。自定义 `mavenHome`、`userSettingsFile`、`localRepository`、`multimoduleDir` 等无法等价映射的设置会被标记为不支持并阻止启动。

**JUnit 配置**交给项目自己的构建系统执行：Maven 项目走 Surefire（`mvn ... test -Dtest=...`），Gradle 项目走 `:module:test`（`--tests`）。支持整个模块、类、方法、包、测试目录与通配模式；包 / 目录 / 整模块会在运行前扫描 `src/test` 与 `src/testFixtures` 展开成具体类名，避免 Maven `-pl -am` 把上游模块的测试一起跑起来。测试 VM Options 在 Maven 侧通过 `argLine`、Gradle 侧通过 init script 的 `jvmArgs` 生效。

限制会明确拒绝而不是静默降级：

- JUnit 的标签（Tags）与 Unique ID 目标暂不支持
- JUnit 的 Program Arguments 在 Surefire / Gradle Test 中没有等价入口
- Maven JUnit 的 Working Directory 必须是模块目录（Surefire fork 无法从命令行可靠改写）；Gradle 不受此限，init script 会设置 `workingDir`

测试进程退出后按日志汇总判定结果：控制台照常显示构建与测试输出，末尾给出「测试完成 / 测试失败：共 N 个，失败 …」；测试失败但构建退出码为 0 也会判失败，一个测试都没跑或没有取得汇总同样判失败，用户手动停止则记为「已停止」，不会误报成测试失败。

## 构建 / 重新构建 / 清理

与 IDEA 一一对应，入口在摘要条按钮或 **构建** 菜单，输出走独立的「构建」页。构建系统按项目自动选择，Maven 与 Gradle 共用同一条工具链解析与串行构建管线：

| 动作 | Maven | Gradle | 用途 |
| --- | --- | --- | --- |
| 构建（⌘F9） | `mvn -B -nsu -DskipTests compile`，整个 reactor | `gradle --console=plain --no-daemon classes` | 增量编译 |
| 重新构建（⇧⌘F9） | `mvn -B -nsu -DskipTests clean compile` | `gradle --console=plain --no-daemon clean classes` | 清空产物后全量 |
| 清理 | `mvn -B clean` | `gradle --console=plain --no-daemon clean` | 只删产物，不编译 |

- 用项目自己的 `mvnw` 时不加 `-B`（wrapper 自带进度输出）；有 `gradlew` 时优先用它，否则依次找 `GRADLE_HOME`、`PATH`、Homebrew / MacPorts / SDKMAN 常见位置和 `~/.gradle/wrapper/dists` 里的发行版
- Gradle 固定 `--no-daemon`：Stop 终止的就是正在构建的进程，不会留下一个把构建跑完的后台 daemon；`--console=plain` 让日志可读、可按原文复现
- 三者都不跑测试、Maven 不带 `-pl`，构建期可 **停止构建**（SIGTERM）或 **强制结束构建**（SIGKILL）
- Gradle classpath 由临时 init script 读取 `sourceSets.main.runtimeClasspath`（勾选 Provided 时并入 `compileClasspath`），不重写项目依赖；缓存指纹覆盖 settings / 各项目构建脚本 / version catalog / wrapper / `GRADLE_USER_HOME` 全局配置 / JDK major

## Git 分支与拉取

摘要条上有当前分支（git 图标 + 分支名），点开可切换本地分支；旁边是拉取按钮。项目不是 git 仓库时该区块自动隐藏。

- **只列本地分支**（`git for-each-ref refs/heads`），不含远程分支；当前分支打勾置灰。点开弹层顶部有搜索框，按关键字过滤分支（忽略大小写）。
- **切换分支** = `git checkout <分支>`。工作区有未提交修改而 git 拒绝切换时，错误原文显示在摘要条上（悬停看全文），不会弹窗打断。
- **拉取** = `git pull --ff-only`，只接受快进：远端有新提交时更新，本地与远端分叉时直接报错，绝不自动生成 merge commit。需要当前分支有上游（首次推送过的分支都有）。
- git 走绝对路径枚举（`/usr/bin/git` 等），不依赖 GUI 的 PATH；凭据交给系统钥匙串 helper，GUI 内不弹终端提示（`GIT_TERMINAL_PROMPT=0`），进程卡住 120 秒兜底 SIGTERM。
- 网络只在用户点「拉取」（或切换分支触发 git 联网）时发生（§64 精神：无后台自查、无定时器）；平时只读本地 `.git`。子进程全部 `Process.arguments` 数组传参（§27）。
- 切换分支不停止运行中的服务——已在跑的 Java 进程仍用旧代码，需要重新 Run 才会用新分支的产物。
- 清理之后 Run 仍正常：若配置的 Before Launch 含 Make，Maven 的编译步骤带 `-pl -am`，会连带重新产出依赖模块的 `target/classes`（§92/§93）；Gradle 用 `:module:classes`，由 Gradle 按 task graph 先构建项目依赖。勾了 "Do not build before run" 的配置本来就不编译，清理后直接启动可能用到旧产物

## 日志与环境变量

- 控制台与构建页：等宽字体，每行前缀短时间（`时:分`，随系统区域设置），stdout 常态、stderr 红、系统消息灰；停在底部时新输出自动跟随到最新一行，向上回看历史时保持当前位置、不抢滚动，滚回底部后恢复跟随；「清空日志」只清显示，不影响进程
- Compound 运行中，控制台顶部提供「全部 / 各成员」切换：「全部」是带 `[成员名]` 前缀的合并日志，单个成员页只显示它自己的输出
- 控制台与构建页顶部的查找分两套语义：「搜索」只把匹配内容高亮（忽略大小写），▲▼ 在上一个/下一个匹配之间跳转并显示「当前/总数」，不改变显示的行；「筛选」（漏斗）按关键词把未匹配的行从显示中过滤掉，可与来源筛选（全部 / 输出 / 错误 / 系统）叠加，激活时显示「匹配行数 / 总行数」。两者都只影响显示，不影响日志保留上限（§37），页签切换后条件保持
- 「换行」勾选框控制长行显示：**默认不换行**，长行用横向滚动条查看（新日志跟到底时横向位置保持不动，不跳到最长行末尾）；勾选后自动折行。偏好全局生效并跨启动记忆
- 长跑服务不会吃满内存：日志在内存中保留最近 20000 行 / 10MB，超出丢弃最旧行（§37）。需要完整历史请用项目自己的日志文件
- 大流量日志按「批量 + 分块」设计，十万行级别不卡界面：读线程按当前到达字节流式读取并批量入环形缓冲；缓冲满后按批次一次性裁剪（不是逐行搬移）；文本视图开启懒排版（只排可见区域），字符数涨过 200 万后整块回收到 160 万，把重排代价按「每新增约 40 万字符一次」摊薄。控制台因此永远只渲染最近的内容，滚轮回看更早的历史会落在丢弃区之外
- 环境变量默认掩码 `••••••••`，勾选「显示明文」才展示取值（§28）；切换配置时自动回到掩码。CLI 对应 `--show-secrets`

## 遇到问题

**找不到 Maven。** 从 Dock/Finder 启动的 GUI 拿到的 PATH 不含 Homebrew 或用户自装的 Maven，所以不依赖 PATH，而按绝对路径枚举候选，取第一个真实可执行的文件：项目 `mvnw` → `MAVEN_HOME` / `M2_HOME` → PATH 各目录 → IDEA 自带 Maven（`/Applications`、`~/Applications` 与 Toolbox 安装位置）→ `/opt/homebrew`、`/usr/local`、`/opt/local`、`~/.sdkman` → `~/.m2/wrapper/dists`。选中了哪个会写在日志开头（Run 的控制台、构建页都是同一条解析），形如 `[IdeaLightRun] Maven: /opt/homebrew/bin/mvn（常见安装位置）`；全都不可用时，报错里按来源列出试过的全部位置，并提示给项目加 Maven Wrapper。

**无法匹配 JDK。** 解析优先级：Run Configuration 指定的 JDK → IDEA 项目 SDK → `JAVA_HOME` → 系统里已安装的最高版本（§23–25）。错误标题是「无法匹配 JDK」，正文会点出哪一级要求了什么版本，例如`运行配置要求 JDK “17”，但系统中未找到 major version 匹配的安装。`——装上对应 JDK，或回 IDEA 改配置。

**启动后立刻退出（状态 `已退出 (N)`）。** 看控制台第一条 stderr 输出，通常是 Main Class、Working Directory 或端口冲突。本应用不猜失败原因，也绝不伪造退出码。

**SNAPSHOT 依赖不是最新的。** 启动 Application / Spring Boot 前解析 classpath 时，Maven 固定带 `-nsu`：跳过逐仓库的 SNAPSHOT metadata 检查，优先用 `~/.m2` 已有依赖（与 IDEA 点 Run 的行为一致）。直接 Run Maven 配置时按配置自身参数执行，不额外追加 `-nsu`。想强制拉最新快照，在 IDEA 或命令行执行一次 `mvn -U` 即可，应用本身不提供刷新开关。本地缺失的依赖仍会正常首次下载。

**classpath 看着不对。** 解析结果有缓存，按 fingerprint（pom / `.mvn` / wrapper / `settings.xml` / JDK）自动失效（§19/§57）。界面没有「清除缓存」按钮，需要时手工删除 `~/Library/Caches/IdeaLightRun/projects/<项目hash>/maven/<模块hash>/` 下的 `classpath.json` 与 `classpath-maven-<scope>.txt`，下次启动重新解析。

**「检查更新…」没有入口。** 只有 v0.1.6 及以后的版本带这个菜单，更早的版本请先手动装一次新版，之后的更新才都能在应用内完成。

**v0.1.6–v0.1.9 点「下载并安装」会永远停在「正在安装」。** 那几版移交后没能真的退出应用（原因见「在线更新实现要点」的「主进程怎么退」），更新助手等满 60s 就放弃替换。此时更新已经中止，而且这个面板会连 ⌘Q 一起挡掉——用「强制退出」（`⌥⌘Esc`）结束应用，再手动装 v0.1.10 或更新的版本，之后的更新就都能在应用内走完。

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
swift run IdeaLightRunCLI clean /path/to/project          # Maven clean / Gradle clean（只删产物，不编译）
swift run IdeaLightRunCLI scan /path/to/project --json     # JSON 输出
swift run IdeaLightRunCLI scan /path/to/project --show-secrets  # 环境变量明文（默认掩码）
```

退出码：`0` 成功、`1` 解析/运行失败或 Java 进程非 0 退出、`2` 参数或命令有误、`130` 构建被 Ctrl-C 取消。

---

## 工程结构

```text
IdeaLightRunCore/    核心库（GUI 与 CLI 共用，禁止另起一套启动逻辑）
  Domain/            RunConfiguration / ExecutableLaunchPlan / PreparedExecution / ProcessState / 统一错误模型
  IntelliJ/          ProjectScanner、RunConfiguration 解析（宽松 + alias）、MacroResolver、ModuleResolver
  BuildSystem/       Maven 与 Gradle 的定位/编译/classpath 解析/缓存；ProjectToolchain + ProjectBuilder（启动与构建共用一条管线）；BuildSystemSelector（Maven/Gradle 共存时确定性选择）
  Execution/         ExecutionCoordinator、BeforeLaunchExecutor、ExecutionRuntime（GUI/CLI 统一执行器）、ConfigurationCapabilityResolver
  Java/              JDKResolver、JavaRunPlanner、JarRunPlanner
  Process/           ProcessSession（进程生命周期 + 日志捕获）
  Logging/           LogRingBuffer（环形日志缓冲）
  Utilities/         CommandLineTokenizer（禁用 /bin/sh -c）、XML 子树捕获
IdeaLightRunUpdate/  在线更新内核（版本比较、发布解析、镜像下载、产物与签名校验、助手参数契约）
IdeaLightRunUpdater/ 进程外安装助手（主 app 退出后替换 bundle 并重启，失败回滚）
IdeaLightRunCLI/     开发期验证工具（scan / run / build / clean）
IdeaLightRunApp/     SwiftUI GUI
Tests/               单元 + Maven 多模块真实集成测试（数量见文末「测试」）+ Fixtures
```

## 当前进度

已完成：Core 解析与宏、Maven / Gradle 编译与 classpath、启动流水线、统一 `PreparedExecution` / `ExecutionRuntime` 执行器、JAR Application 启动、Compound 多配置编排（独立进程 / 日志 / 端口、分组控制、嵌套展开与部分失败清理）、Maven 配置直接运行、JUnit 测试运行（Maven Surefire / Gradle Test、目标展开、测试结果判定与日志展示）、进程与日志、GUI 三栏、Build/Rebuild/Clean（Maven 与 Gradle）、运行端口检测、扫描诊断与统一配置能力计算、在线更新。

待做：

- Gradle 运行配置（直接执行 task）
- Before Launch 扩展（Build, no error check / Build Artifacts / Run External Tool / Launch Web Browser）与 Restart to Apply 提示

## 在线更新实现要点

安装要替换的正是自己，所以分两段：主进程只负责「取到并验干净的新 app」，落盘与重启交给进程外助手。

- **取版本**：`api.github.com/repos/misswell/IdeaLightRun/releases/latest` 给出 `tag_name` 与附件的 `digest`（SHA-256）；被匿名限流（403）时退回公开的 `releases/expanded_assets/<tag>` 页面解析同一份摘要。只接受 `IdeaLightRun-<ver>-universal.zip`，且必须带可解析的 sha256——**没有摘要就不下载**
- **镜像链**：`xget.xi-xu.me → ghfast.top → gh-proxy.org → github.com`。第三方源只当传输通道，不当信任来源：每个源落地后都要过 SHA-256，不过就删掉换下一个源。最近一次成功的镜像会记住并提到队首，直连成功则清掉该偏好（避免网络变好后仍绕远路）
- **主进程内校验（`UpdatePackageValidator`）**：SHA-256 → `ditto` 解包（不是 `unzip`，只有它保留权限与元数据）→ 结构自检（bundle id、可执行文件、版本号、**更新助手在位**）→ `codesign --verify --deep --strict` → TeamIdentifier → 按**语义**比对新旧 app 的 designated requirement（比文本会把合法更新判成身份变更，而这条 requirement 决定系统授权能否延续）→ `spctl --assess` → 递归清除隔离属性（漏掉它，重启后会被 App Translocation 搬到随机只读路径，每项系统授权都要重新点）
- **进程外安装（`IdeaLightRunUpdater`）**：先把助手拷出 bundle 再执行（它所在的 bundle 即将被换掉）→ 等主进程退出 → 同卷原子替换并留备份 → 直接 exec `Contents/MacOS/IdeaLightRun` 重启（不走 `open`：LaunchServices 对刚替换路径的旧记录会「返回成功却不起进程」）→ 任一步失败则回滚旧版本，并且仍然把可用的 app 拉起来
- **主进程怎么退**：移交后先收起更新面板，等面板真的没了再 `NSApp.terminate`。AppKit 在应用还挂着 sheet/alert 时会**静默**吞掉 terminate——连 `applicationShouldTerminate` 都不问，而 §66 停子进程的收尾就在那个回调里；助手只等主进程 60s，超时就不替换了。所以退出挂在面板的 `onDismiss` 上，并配 3s 兜底：`terminate` 一旦返回就自己收尾后强退，绝不允许停在「正在安装」的假象里

## 关键设计约束

- 不依赖 IDEA 安装目录，只读项目内配置（§113）；Maven 定位也不依赖 PATH，见「遇到问题」
- XML 宽松解析：未知字段进 `rawOptions`，未知类型标记 `unknown` 并显示为 `UNSUPPORTED`（§78）
- `$Prompt$` 等 IDEA 上下文宏不伪造，只产生 warning（§11）
- Java 启动使用 Process.arguments 数组传参，绝不走 `/bin/sh -c`（§27）
- 读子进程输出一律用 `FileHandle.availableData`，不用 `readData(ofLength:)`：后者要凑满
  请求长度或读到 EOF 才返回，会让日志成段攒住——表现就是「启动日志卡在某一处，
  点了 Stop/关闭才一次性刷出来」（§36/§103 的流式前提）
- 日志大流量路径禁止逐行搬移：`LogRingBuffer` 满后按批次一次 `removeFirst(k)`；
  NSTextStorage 涨过 200 万字符后一次回收到 160 万（水位式分块回收），并有
  吞吐回归测试钉住（`testHighVolumeAppendThroughput`，十万行写入限时 2s）
- reactor 依赖解析为 `target/classes` 而非 SNAPSHOT jar，重启即用最新代码（§92/§93）
- 同一条流水线服务 Run 与 Build/Rebuild/Clean（`ProjectToolchain`），不出现两套工具链判定
- 除「检查更新…」外 100% 本地（§64）：联网只在用户主动点菜单时发生，没有启动自查、没有定时器

## 测试

```bash
swift test                                        # 本地全量：455 用例
swift test --skip MavenClasspathIntegrationTests  # CI 集合：452 用例（跳过那 3 个要真实下载依赖的）
```

覆盖范围：

- **解析层** — RunConfigurationParser（alias / rawOptions / Before Launch / JAR 字段）、WorkspaceParser（流式、只取 RunManager、跳过模板）、ProjectScanner（§7 来源优先级去重、§6 深度上限 4、忽略目录）、MacroResolver（§11 全部宏与 IDEA 上下文变量，运行配置与 IML 路径共用）、ModuleResolver（§13 五种方式）、JDKResolver（§23–25 优先级与 major version 模糊匹配）
- **构建与启动** — JavaRunPlanner（§26–§29）、JarRunPlanner（`java -jar` 参数顺序、默认工作目录、缺失/不可读 JAR）、ExecutionRuntime（日志/PID/终态转发、Stop、Before Launch 同步执行与取消、测试终态：失败/无测试/无汇总/用户停止）、MavenRunExecution（直接运行参数顺序与 `-nsu` 缺失、Project JDK / `MAVEN_OPTS`、pom 与不支持选项的 fail-closed、宏与 `$Prompt$`、Surefire 模块范围/筛选/工作目录限制）、TestTargetResolver（类/方法/包/目录/模式展开与无匹配拒绝）、TestOutcomeMonitor（Surefire `Results:` 汇总与逐类行、旧版 `Results :`、Gradle SUMMARY、无测试检测）、Compound（成员按引用顺序准备、嵌套展开、缺失/类型不匹配/成环拦截、独立 PID 与日志、分组 Stop/Force Kill、部分失败清理）、CommandLineTokenizer（§72 参数集）、ClasspathCache + reactor 归一化（§18/§19/§57）、MavenLocator / GradleLocator（Dock 启动无 PATH 时的绝对路径枚举与 wrapper 发行版兜底）、GradleBuildService（project path 任务、合并编译与 classpath 解析、provided 变体、缓存失效、失败与取消、JUnit `:test` 与 `--tests`/init script）、项目级 Build/Rebuild/Clean 参数与取消语义、Maven 多模块真实集成（§92/§93）
- **诊断与能力** — ScanDiagnostic（读失败 / XML 损坏 / 配置目录不可读 / 重复配置 / 缺 Main Class / 不支持的 Before Launch 任务都带严重程度与建议，不静默丢配置）、ConfigurationCapabilityResolver（类型 + 构建系统 + 字段 + Module 解析 + Before Launch 统一裁决）、BuildSystemSelector（Maven/Gradle 共存时的确定性选择）、Gradle settings/projectDir 解析、Maven `$MODULE_DIR$` POM 路径、ProcessHandle 启动前取消与 SIGTERM→SIGKILL 升级
- **进程与日志** — ProcessSession（启动/停止/日志捕获、退出以进程自身为准）、LogRingBuffer（§37 上限）、LogScrollFollow（停在底部才跟随新日志，向上回看不抢滚动）
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
