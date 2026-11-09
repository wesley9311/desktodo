import Cocoa
import WebKit

// 入口：没有 Dock 图标的常驻浮窗

autoreleasepool {
    // 数据层自检：只在 DESKTODO_TEST_HOME 指向的临时目录里跑，不碰真实数据。
    // build.sh 用它当构建闸门（坏数据能不能覆盖好数据、清空会不会有残留）。
    if CommandLine.arguments.contains("--selftest") {
        let probe = AppDelegate()
        exit(probe.runStorageSelfTest() ? 0 : 1)
    }

    // 单实例：同一个 app 只允许一份在跑。
    // 两份同时跑会各持一份内存账本，而保存是整份覆盖 —— 后写者会静默吃掉前写者的改动。
    // 所以第二个进程把已有那份叫到前台，自己立刻退出。
    let bid = Bundle.main.bundleIdentifier ?? "local.desktodo.app"
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if let other = others.first {
        NSLog("DeskTodo: 已有实例在跑（pid=\(other.processIdentifier)），本进程退出")
        other.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
