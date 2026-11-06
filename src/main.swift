import Cocoa
import WebKit

// 入口：没有 Dock 图标的常驻浮窗

autoreleasepool {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
