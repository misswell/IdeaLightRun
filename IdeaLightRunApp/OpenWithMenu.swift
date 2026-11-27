import AppKit
import SwiftUI

/// 「打开」菜单的一项：把项目目录交给外部应用（编辑器 / 终端 / 默认应用）。
/// 探测顺序：bundle id（LaunchServices）→ 常见安装路径；都找不到则菜单项置灰。
struct OpenTarget: Identifiable {
    let name: String
    /// 菜单里真正的显示名（带图标的那个）。`nil` 时直接用 bundle id 探测结果。
    var bundleIDs: [String] = []
    var fallbackPaths: [String] = []

    var id: String { name }

    /// Default app（bundleIDs 与 fallbackPaths 都为空）永远可用，走系统默认处理者。
    var requiresApp: Bool { !bundleIDs.isEmpty || !fallbackPaths.isEmpty }

    var applicationURL: URL? {
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        for rawPath in fallbackPaths {
            let path = (rawPath as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }

    /// 兜底用的路径：没装对应应用时，图标要落到项目目录本身（否则菜单项没法显示图标）。
    func icon(for projectURL: URL, applicationURL: URL?) -> NSImage {
        let path = applicationURL?.path ?? projectURL.path
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    func open(_ projectURL: URL) {
        guard let appURL = applicationURL else {
            NSWorkspace.shared.open(projectURL)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([projectURL], withApplicationAt: appURL, configuration: configuration)
    }

    /// 菜单顺序对齐参考实现；bundle id 探测不到时按常见路径兜底。
    /// 第 0 项必须是「访达」：它是默认动作，用户说它始终显示在列表里。
    static let catalog: [OpenTarget] = [
        OpenTarget(name: "访达", bundleIDs: ["com.apple.finder"], fallbackPaths: ["/System/Library/CoreServices/Finder.app"]),
        OpenTarget(name: "VS Code", bundleIDs: ["com.microsoft.VSCode"], fallbackPaths: ["/Applications/Visual Studio Code.app", "~/Applications/Visual Studio Code.app"]),
        OpenTarget(name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"], fallbackPaths: ["/Applications/Cursor.app", "~/Applications/Cursor.app"]),
        OpenTarget(name: "Zed", bundleIDs: ["dev.zed.Zed"], fallbackPaths: ["/Applications/Zed.app", "~/Applications/Zed.app"]),
        OpenTarget(name: "Default app"),
        OpenTarget(name: "Terminal", bundleIDs: ["com.apple.Terminal"], fallbackPaths: ["/System/Applications/Utilities/Terminal.app", "/Applications/Utilities/Terminal.app"]),
        OpenTarget(name: "iTerm2", bundleIDs: ["com.googlecode.iterm2"], fallbackPaths: ["/Applications/iTerm.app", "~/Applications/iTerm.app"]),
        OpenTarget(name: "Ghostty", bundleIDs: ["com.mitchellh.ghostty"], fallbackPaths: ["/Applications/Ghostty.app", "~/Applications/Ghostty.app"]),
        OpenTarget(name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"], fallbackPaths: ["/Applications/Xcode.app"]),
        OpenTarget(
            name: "IntelliJ IDEA",
            bundleIDs: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"],
            fallbackPaths: ["/Applications/IntelliJ IDEA Ultimate.app", "/Applications/IntelliJ IDEA CE.app", "/Applications/IntelliJ IDEA.app"]
        ),
    ]

    /// 访达：默认动作，始终可用（系统自带）。
    static var finder: OpenTarget { catalog[0] }

    /// 默认选中的项是访达；存过的偏好优先。
    static func preferredTarget(storedName: String?) -> OpenTarget {
        if let storedName, let stored = catalog.first(where: { $0.name == storedName }) {
            return stored
        }
        return finder
    }
}

/// 中栏顶栏的「打开」菜单：主区域直接用当前应用打开，右侧箭头切换应用。
/// 图标与文字放在同一个 Menu 里，避免工具栏把「图标按钮 + 菜单」合并成
/// 双层胶囊，也避免系统箭头和手写箭头同时出现。
struct OpenWithMenu: View {
    let projectURL: URL

    @AppStorage("openWithApp") private var preferredName = ""

    private var target: OpenTarget {
        OpenTarget.preferredTarget(storedName: preferredName.isEmpty ? nil : preferredName)
    }

    private var resolvedURL: URL? { target.applicationURL }

    var body: some View {
        Menu {
            ForEach(OpenTarget.catalog) { candidate in
                let appURL = candidate.applicationURL
                Button {
                    preferredName = candidate.name
                    candidate.open(projectURL)
                } label: {
                    Label {
                        Text(candidate.name)
                    } icon: {
                        Image(nsImage: candidate.icon(for: projectURL, applicationURL: appURL))
                    }
                }
                .disabled(candidate.requiresApp && appURL == nil)
            }
        } label: {
            HStack(spacing: 6) {
                Image(nsImage: target.icon(for: projectURL, applicationURL: resolvedURL))
                    .frame(width: 16, height: 16)
                Text("打开")
            }
        } primaryAction: {
            target.open(projectURL)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("用\(target.name)打开项目；点箭头切换应用")
    }
}
