# IdeaLightRun 项目规则

## 发布偏好

- 每次改动完成并验证通过后：提交并推送 GitHub、创建新的 patch 版本 tag、创建 GitHub Release，回复 commit 与 Release 链接。
- 使用新版本号，绝不移动或覆盖已推送的 tag；仅在 `swift test` 与构建验证通过后发布。
- 打 tag 前必须先等 `Compile check` 工作流在 main 上绿灯，再打 tag 发布：CI runner 是
  macos-14 / Swift 5.10（旧 SDK 上 `Commands.body` 不是 `@MainActor`，本机 Xcode 26 能过
  的写法在 CI 上是编译错误），而 `swift test` 不构建 App target，只有 `swift build`
  全量编译才覆盖到 GUI 代码。tag 一旦推上去就作废不了，失败的 tag 只能留着。
- 签名、公证或 Actions 任一环失败时，必须报告失败环节和证据，不得把未验证的包当正式 Release。

## 在线更新通道

- 更新通道靠字面量对齐：产物名 `IdeaLightRun-<ver>-universal.zip`、bundle id、Team ID、
  更新助手落点 `Contents/MacOS/IdeaLightRunUpdater` 同时存在于
  `IdeaLightRunUpdate/UpdateIdentity.swift`、`scripts/build-app.sh`、`scripts/distribute-app.sh`
  与 `.github/workflows/release.yml`。改任何一处都要同步其余三处——不同步的后果是老用户
  永远「无可用更新」或永远校验失败，而且本地看不出来。
  `UpdateIdentityTests` 直接读脚本与 workflow 原文钉住这条线。
- 正式包必须内置更新助手：`distribute-app.sh` 会拒绝缺少 `IdeaLightRunUpdater` 的包。
- 只有 `Developer ID Application` + Team `U8U443D7ZL` 签出的产物才会被接受；换证书或换签名
  方式（ad-hoc / Apple Development）等于断开更新链，老用户会收到身份校验失败。
- 联网只在用户主动点「检查更新…」时发生（§64）。不要加启动自查、后台定时器或遥测。

## 签名与公证

- 禁止生成或交付 ad-hoc、临时签名包。`scripts/build-app.sh` 默认用
  `Developer ID Application: Guofeng Liu (U8U443D7ZL)` 加 hardened runtime + 安全时间戳，
  并校验 `Authority=Developer ID Application` 与 `TeamIdentifier`。
- 正式包只能走 `./scripts/distribute-app.sh`：通用二进制 → 签名 → 公证 → staple → 复打包
  （stapled 后的包才离线可验）→ `codesign --verify --deep --strict` + `spctl --assess` + 双架构校验。
- 公证凭据两条路径：本机用 notarytool 凭据档 `idealightrun-notary`
  （`IDEALIGHTRUN_NOTARY_PROFILE` 可覆盖）；CI 用 App Store Connect API Key 三元组
  `APPLE_API_KEY` / `APPLE_API_KEY_ID` / `APPLE_API_ISSUER`，因此不需要 Apple App 专用密码。
- 其余 CI secrets：`APPLE_CERTIFICATE_P12`、`APPLE_CERTIFICATE_PASSWORD`、
  `APPLE_DEVELOPER_ID`、`APPLE_TEAM_ID`。凭据值只存在本机钥匙串和 GitHub Secrets 里，
  不写入仓库、日志或聊天。

## 推送与测试注意

- 改动 `.github/workflows/` 下任何文件后必须走 SSH 推送：
  `git push git@github.com:misswell/IdeaLightRun.git main`。
  `gh` 的 token 没有 `workflow` scope，HTTPS 推送这类提交会被 GitHub 拒绝。
- `MavenClasspathIntegrationTests` 会真实下载依赖，只在本地跑；CI 用
  `swift test --skip MavenClasspathIntegrationTests` 排除，不要在 CI 里放开。
