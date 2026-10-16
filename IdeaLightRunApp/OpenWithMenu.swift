import AppKit
import SwiftUI

/// 「打开」菜单的一项：把项目目录交给外部应用（编辑器 / 终端 / 默认应用）。
/// 探测顺序：bundle id（LaunchServices）→ 常见安装路径；都找不到则菜单项置灰。
struct OpenTarget: Identifiable {
    let name: String
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
    static let catalog: [OpenTarget] = [
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
}

/// 中栏顶栏的「打开」菜单：用外部应用打开当前项目（对齐 Codex 的打开方式）。
struct OpenWithMenu: View {
    let projectURL: URL

    var body: some View {
        Menu {
            ForEach(OpenTarget.catalog) { target in
                let appURL = target.applicationURL
                Button {
                    target.open(projectURL)
                } label: {
                    Label {
                        Text(target.name)
                    } icon: {
                        Image(nsImage: target.icon(for: projectURL, applicationURL: appURL))
                    }
                }
                .disabled(target.requiresApp && appURL == nil)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text("打开")
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
        }
        .help("用外部应用打开项目")
    }
}
