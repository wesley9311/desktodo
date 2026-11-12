import Cocoa
import WebKit

// 浅色 / 深色 / 跟随系统
extension AppDelegate {

    func applyThemeAppearance() {
        switch themeMode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        window?.appearance = NSApp.appearance
        webView?.evaluateJavaScript("window.__setTheme && window.__setTheme('\(themeMode)');", completionHandler: nil)
    }

    @objc func setThemeAuto() { themeMode = "auto" }
    @objc func setThemeLight() { themeMode = "light" }
    @objc func setThemeDark() { themeMode = "dark" }
}
