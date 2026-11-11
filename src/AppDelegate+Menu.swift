import Cocoa
import WebKit
import UniformTypeIdentifiers

// 状态栏菜单、视图大小、开机自启
extension AppDelegate {

    // MARK: Menu

    func showMenu() {
        guard let w = window else { return }
        let menu = NSMenu()

        let compact = NSMenuItem(title: isCollapsed ? "展开完整清单" : "收起为紧凑日程",
                                 action: #selector(toggleCompact), keyEquivalent: "")
        compact.target = self
        menu.addItem(compact)

        let collapse = NSMenuItem(title: "收起悬浮窗（留个桌面小圆点）", action: #selector(collapseToDot), keyEquivalent: "h")
        collapse.target = self
        menu.addItem(collapse)

        // 小圆点：换色（位置随你摆，不提供"回到右上角"，免得把位置重置掉）
        let dotItem = NSMenuItem(title: "收起后的小圆点", action: nil, keyEquivalent: "")
        let dotSub = NSMenu()
        for (i, entry) in dotPalette.enumerated() {
            let mi = NSMenuItem(title: entry.0, action: #selector(setDotColor(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.image = dotSwatch(entry.1)
            mi.state = (i == dotTintIndex) ? .on : .off
            dotSub.addItem(mi)
        }
        dotItem.submenu = dotSub
        menu.addItem(dotItem)

        menu.addItem(.separator())

        // 外观：跟随系统 / 浅色 / 深色
        let look = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        let lookSub = NSMenu()
        let modes: [(String, String, Selector)] = [
            ("跟随系统", "auto", #selector(setThemeAuto)),
            ("浅色", "light", #selector(setThemeLight)),
            ("深色", "dark", #selector(setThemeDark))
        ]
        for m in modes {
            let mi = NSMenuItem(title: m.0, action: m.2, keyEquivalent: "")
            mi.target = self
            mi.state = (themeMode == m.1) ? .on : .off
            lookSub.addItem(mi)
        }
        look.submenu = lookSub
        menu.addItem(look)

        // 天气城市：自动定位 / 手动填写，二选一，当前用哪个打勾
        let cityNow = UserDefaults.standard.string(forKey: "wxCity") ?? ""
        let cityItem = NSMenuItem(title: "天气城市", action: nil, keyEquivalent: "")
        let citySub = NSMenu()
        let autoItem = NSMenuItem(title: "自动定位（按 IP）", action: #selector(useAutoCity), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = weatherAuto ? .on : .off
        citySub.addItem(autoItem)
        let manualItem = NSMenuItem(
            title: "手动填写城市…" + (cityNow.isEmpty ? "" : "（现在：\(cityNow)）"),
            action: #selector(askWeatherCity), keyEquivalent: "")
        manualItem.target = self
        manualItem.state = weatherAuto ? .off : .on
        citySub.addItem(manualItem)
        cityItem.submenu = citySub
        menu.addItem(cityItem)

        // 全产品唯一的外部连接，给一个能当场关掉的闸门。
        // 放在"天气城市"下面，是因为它就是天气的一部分：不联网 = 不要天气。
        let offlineItem = NSMenuItem(title: "不联网（天气停更）", action: #selector(toggleOffline), keyEquivalent: "")
        offlineItem.target = self
        offlineItem.state = weatherOffline ? .on : .off
        offlineItem.toolTip = "打开后这个进程不再发起任何网络请求，可用 lsof 验证"
        menu.addItem(offlineItem)

        // 视图大小：字大一号，窗口跟着放一号（不是靠凑近屏幕解决）
        let zoomItem = NSMenuItem(title: "视图大小", action: nil, keyEquivalent: "")
        let zoomSub = NSMenu()
        let zoomSteps: [(String, Int)] = [("标准", 100), ("大", 115), ("更大", 130), ("最大", 150)]
        for (label, pct) in zoomSteps {
            let mi = NSMenuItem(title: label, action: #selector(setZoom(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = pct
            mi.state = (Int((uiZoom * 100).rounded()) == pct) ? .on : .off
            zoomSub.addItem(mi)
        }
        zoomItem.submenu = zoomSub
        menu.addItem(zoomItem)

        // 数据来源：日历 / 提醒事项 / 屏幕使用时间，各自带授权状态
        menu.addItem(sourceMenuItem())

        let top = NSMenuItem(title: "始终置顶", action: #selector(toggleAlwaysOnTop), keyEquivalent: "t")
        top.target = self
        top.state = window.level == .floating ? .on : .off
        menu.addItem(top)
        let fit = NSMenuItem(title: "高度贴合内容", action: #selector(fitHeightToContent), keyEquivalent: "")
        fit.target = self
        menu.addItem(fit)
        let pv = NSMenuItem(title: "预览年度公告…", action: #selector(previewAnniversary), keyEquivalent: "")
        pv.target = self
        menu.addItem(pv)
        let login = NSMenuItem(title: "开机自动显示", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = loginItemEnabled() ? .on : .off
        menu.addItem(login)

        // 数据三件事：带得走、看得见、删得掉。这三条做不到，就不能叫本地优先。
        menu.addItem(.separator())
        let exp = NSMenuItem(title: "导出账本…", action: #selector(doExport), keyEquivalent: "")
        exp.target = self
        menu.addItem(exp)
        let bak = NSMenuItem(title: "立即备份", action: #selector(doBackupNow), keyEquivalent: "")
        bak.target = self
        menu.addItem(bak)
        let chk = NSMenuItem(title: "备份自检…", action: #selector(doBackupCheck), keyEquivalent: "")
        chk.target = self
        menu.addItem(chk)
        let res = NSMenuItem(title: "恢复备份…", action: #selector(doRestore), keyEquivalent: "")
        res.target = self
        menu.addItem(res)
        let folder = NSMenuItem(title: "打开数据文件夹", action: #selector(openDataFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        let wipe = NSMenuItem(title: "清空全部数据…", action: #selector(doWipe), keyEquivalent: "")
        wipe.target = self
        menu.addItem(wipe)
        let diag = NSMenuItem(title: "复制诊断信息", action: #selector(copyDiag), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出浮窗待办", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        let pt = NSPoint(x: w.frame.width - 24, y: w.frame.height - 40)
        menuOpen = true
        cancelPendingAutoHide()
        menu.popUp(positioning: nil, at: pt, in: w.contentView)
        // popUp 是同步的，返回时菜单已关；留一点余量免得"关菜单"被当成点外部
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.menuOpen = false }
    }

    // MARK: 数据：导出 / 打开 / 清空

    @objc func doBackupNow() {
        store.backupNow("manual")
        nativeToast("已备份")
    }

    @objc func doBackupCheck() {
        let r = store.review()
        let a = NSAlert()
        a.messageText = r.passed ? "备份自检 7/7" : "备份自检有问题"
        a.informativeText = r.lines.joined(separator: "\n")
        a.addButton(withTitle: "好")
        a.runModal()
    }

    @objc func doRestore() {
        let backups = store.backupFileList()
        guard !backups.isEmpty else { nativeToast("还没有备份"); return }
        let a = NSAlert()
        a.messageText = "恢复备份？"
        a.informativeText = "会先把当前账本备份一次，再用选中的备份覆盖。"
        a.addButton(withTitle: "选择备份…")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSOpenPanel()
        panel.directoryURL = store.backupsURL
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选一份 backups/ 里的备份"
        panel.begin { [weak self] resp in
            guard let self = self, resp == .OK, let url = panel.url else { return }
            let r = self.store.restore(from: url)
            guard r.ok else { self.nativeToast("这份备份读不出来，没有恢复"); return }
            let json = self.readStore()
            self.webView?.evaluateJavaScript("window.__load && window.__load(\(json));", completionHandler: nil)
            self.pushStoreStatus()
            self.nativeToast("已恢复 · \(r.after) 件（恢复前 \(r.before) 件）")
        }
    }

    @objc func doExport() {
        exportViaPage { [weak self] ok in
            self?.nativeToast(ok ? "已导出：原始数据 + 一份说明" : "没有导出（已取消或写入失败）")
        }
    }

    @objc func openDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([storeURL])
    }

    @objc func copyDiag() { copyDiagToPasteboard() }

    /* 清空前把话说清楚：这一步不可撤销，而且不留副本。
       "先导出再清空"放在第一个按钮——不是因为更安全，是因为它才是大多数人真正想要的。 */
    @objc func doWipe() {
        NSApp.activate(ignoringOtherApps: true)
        suppressCount += 1
        let a = NSAlert()
        a.messageText = "清空全部数据？"
        a.informativeText = """
        清单、历史、年度统计会一起删除：主文件、上一版备份、读不出来时留下的坏文件，都不留。
        不进废纸篓，没法撤销。
        """
        a.alertStyle = .warning
        a.addButton(withTitle: "先导出，再清空")
        a.addButton(withTitle: "直接清空")
        a.addButton(withTitle: "取消")
        let r = a.runModal()

        if r == .alertThirdButtonReturn {
            suppressCount = max(0, suppressCount - 1)
            return
        }

        if r == .alertFirstButtonReturn {
            // 导出没成功就不清——否则"先导出"变成了"什么都没做就删了"
            exportViaPage { [weak self] ok in
                guard let self = self else { return }
                guard ok else {
                    self.suppressCount = max(0, self.suppressCount - 1)
                    self.nativeToast("导出没划掉，没有清空")
                    return
                }
                self.finishWipe()
            }
            return
        }

        finishWipe()
    }

    func finishWipe() {
        let failed = wipeAllData()
        /* 清空之后还有三件事必须做，少一件"删了就是没了"就是假话：
           1. 前台计时停了并清空内存——不然 20 秒后定时器会把 focus.json 写回来；
           2. 这一小段静默期拒写——页面内存里还是旧账本，1 秒 tick 会把它写回磁盘；
           3. 本次运行不再启动前台计时（下次启动才恢复）。 */
        FocusTracker.shared.stopAndClear()
        focusDisabledUntilRestart = true
        suppressSavesUntil = Date().addingTimeInterval(6)
        reloadEmptyStore()
        // 页面已重载成空，状态提示也没必要留着了
        storeStatus = StoreStatus(kind: .fresh, kept: [], at: Date())
        pushStoreStatus()
        suppressCount = max(0, suppressCount - 1)
        if failed.isEmpty {
            nativeToast("已清空：清单、历史、备份、快照、前台计时都没留")
        } else {
            nativeToast("有文件删不掉：\(failed.joined(separator: "、"))")
        }
    }

    @objc func toggleCompact() {
        webView.evaluateJavaScript("window.__toggleCollapse && window.__toggleCollapse();", completionHandler: nil)
    }

    // MARK: 视图大小（字大一号，窗口跟着宽一号）

    @objc func setZoom(_ mi: NSMenuItem) {
        changeZoom(to: CGFloat(mi.tag) / 100.0)
    }

    func changeZoom(to z: CGFloat) {
        let old = uiZoom
        uiZoom = max(0.9, min(1.6, z))
        UserDefaults.standard.set(Double(uiZoom), forKey: "uiZoom")
        webView?.pageZoom = uiZoom
        if abs(uiZoom - old) > 0.001, let w = window, w.isVisible {
            let ratio = uiZoom / old
            var nw = min(max(w.frame.width * ratio, minW), maxW)
            if let vf = (w.screen ?? NSScreen.main)?.visibleFrame { nw = min(nw, vf.width - 16) }
            let nh = min(w.frame.height * ratio, maxHeight)
            setFrameKeepingTopRight(NSSize(width: nw, height: nh), animate: false)
            // 靠屏幕左/下时，放大是往上左长，容易长到屏幕外——拉回来
            clampIntoScreen()
            if manualSize { manualW = nw; manualH = nh; saveWindowSize() }
        }
        // 页面按新的比例重算内容高度（它用 __setZoom 里的系数换算）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self else { return }
            self.webView?.evaluateJavaScript("window.__setZoom && window.__setZoom(\(self.uiZoom));", completionHandler: nil)
        }
    }

    /// 把窗口收紧到刚好包住内容（你拉高过之后想反悔，用这个）
    @objc func fitHeightToContent() {
        manualSize = false
        UserDefaults.standard.set(false, forKey: "winManual")
        // 让页面自己报高度：__setManual(false) 会去掉撑满视口的样式，
        // 内容一变矮它就会发新的 resize，窗口跟着收
        webView?.evaluateJavaScript("window.__setManual && window.__setManual(false);", completionHandler: nil)
        nativeToast("高度已贴合内容")
    }

    // MARK: 开机自启（LaunchAgent，免签名限制）

    func launchAgentPath() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("local.desktodo.plist")
    }

    func loginItemEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath().path)
    }

    @objc func toggleLoginItem() {
        let url = launchAgentPath()
        if loginItemEnabled() {
            try? FileManager.default.removeItem(at: url)
            shell("/bin/launchctl", ["bootout", "gui/\(getuid())", url.path])
        } else {
            let appPath = Bundle.main.bundlePath
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>local.desktodo</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/usr/bin/open</string>
                    <string>-a</string>
                    <string>\(appPath)</string>
                </array>
                <key>RunAtLoad</key><true/>
                <key>LimitLoadToSessionType</key><string>Aqua</string>
            </dict>
            </plist>
            """
            try? plist.write(to: url, atomically: true, encoding: .utf8)
            shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", url.path])
        }
    }

    func shell(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    @objc func toggleAlwaysOnTop() {
        window.level = window.level == .floating ? .normal : .floating
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.window.orderFrontRegardless() }
    }

    @objc func collapseToDot() { hideToDot() }

    @objc func hideWindow() { window.orderOut(nil) }
    @objc func quitApp() { NSApp.terminate(nil) }

    // 再次打开 App 时把窗口唤回
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMain() }
        return true
    }

    /// 退出前把最后一段前台时间落盘，不然每次退出都丢掉一截
    func applicationWillTerminate(_ notification: Notification) {
        FocusTracker.shared.flush()
    }

    // 手动拖动

    func beginDrag() {
        dragMouseOrigin = NSEvent.mouseLocation
        dragWindowOrigin = window.frame.origin
    }

    func updateDrag() {
        let cur = NSEvent.mouseLocation
        let dx = cur.x - dragMouseOrigin.x
        let dy = cur.y - dragMouseOrigin.y
        window.setFrameOrigin(NSPoint(x: dragWindowOrigin.x + dx, y: dragWindowOrigin.y + dy))
        // 你亲手摆过位置，以后就固定在这儿，不再跟着圆点跑
        if abs(dx) > 1 || abs(dy) > 1 {
            winUserPos = true
            saveWindowAnchor()
        }
    }
}
