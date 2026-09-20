# IdeaLightRun 项目规则

## 发布偏好

- 每次改动完成并验证通过后：提交并推送 GitHub、创建新的 patch 版本 tag、创建 GitHub Release，回复 commit 与 Release 链接。
- 使用新版本号，绝不移动或覆盖已推送的 tag；仅在 `swift test` 与构建验证通过后发布。
- 签名、公证或 Actions 任一环失败时，必须报告失败环节和证据，不得把未验证的包当正式 Release。

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
