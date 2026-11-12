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

#if DEBUG
    // 导出样例：把 exportPayload 写到指定路径，供外部解析验证（仅 DEBUG）
    if let i = CommandLine.arguments.firstIndex(of: "--export"),
       i + 1 < CommandLine.arguments.count {
        let probe = AppDelegate()
        if let data = probe.exportPayload() {
            try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }
        exit(1)
    }

    // 备份审阅样例（仅 DEBUG）
    if CommandLine.arguments.contains("--review") {
        let probe = AppDelegate()
        print(probe.backupReviewText())
        exit(0)
    }

    // 诊断自证：把诊断文本打到 stdout，供 shell grep（仅 DEBUG）
    if CommandLine.arguments.contains("--diag") {
        let probe = AppDelegate()
        print(probe.diagnosticText())
        exit(0)
    }

    // 夹具：重构前后各编一次，用同一份代码跑同一组场景，输出规范化 JSON 做字节比对。
    if let i = CommandLine.arguments.firstIndex(of: "--fixture"),
       i + 1 < CommandLine.arguments.count {
        let probe = AppDelegate()
        print(probe.runFixture(CommandLine.arguments[i + 1]))
        exit(0)
    }
#endif

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
