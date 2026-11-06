import Cocoa
import WebKit

// 选本地文件 / 文件夹（NSOpenPanel）
extension AppDelegate {

    // MARK: 选择本地文件 / 文件夹

    func jsString(_ s: String) -> String {
        if let d = try? JSONEncoder().encode(s), let str = String(data: d, encoding: .utf8) {
            return str
        }
        return "\"\""
    }

    func pickPath(mode: String, callbackId: String, startPath: String = "") {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        let anyMode = (mode == "any")
        panel.canChooseFiles = (mode == "file" || anyMode)
        panel.canChooseDirectories = (mode == "folder" || anyMode)
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = (mode == "folder" || anyMode)

        // 已经有绑定 → 打开面板时直接定位到它，方便换掉选错的那一个
        let changing = !startPath.isEmpty
        panel.prompt = changing ? "换这个" : "选择"
        if changing {
            let u = URL(fileURLWithPath: startPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: startPath, isDirectory: &isDir) {
                if isDir.boolValue {
                    panel.directoryURL = u
                } else {
                    panel.directoryURL = u.deletingLastPathComponent()
                    panel.nameFieldStringValue = u.lastPathComponent
                }
            }
            panel.message = "当前：\(startPath)\n选一个别的来替换"
        } else if anyMode {
            panel.message = "选文件夹 = 建项目，选文件 = 建节点（都能挂很多条任务）"
        } else if mode == "folder" {
            panel.message = "选一个文件夹，作为这个项目的落点"
        } else {
            panel.message = "选一个文件，挂到这条待办上"
        }

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard let self = self else { return }
            var path = ""
            var isDir = false
            if resp == .OK, let u = panel.url {
                path = u.path
                let vals = try? u.resourceValues(forKeys: [.isDirectoryKey])
                isDir = vals?.isDirectory ?? false
            }
            let js = "window.__onPick && window.__onPick(\(self.jsString(callbackId)), \(self.jsString(path)), \(isDir ? "true" : "false"));"
            self.webView.evaluateJavaScript(js, completionHandler: nil)
            self.window.orderFrontRegardless()
            // 面板关掉之后再恢复"点外面就收起"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.suppressCount = max(0, self.suppressCount - 1) }
        }

        suppressCount += 1
        cancelPendingAutoHide()
        panel.begin(completionHandler: handler)
    }
}
