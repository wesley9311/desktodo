import Cocoa
import WebKit

// 状态栏图标、点击外部自动收起、心跳
extension AppDelegate {

    // MARK: Status bar

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 26)
        guard let btn = statusItem.button else {
            debugLog("statusItem.button is nil")
            return
        }
        var img = NSImage(systemSymbolName: "alarm", accessibilityDescription: "浮窗待办")
        if img == nil { img = NSImage(systemSymbolName: "clock", accessibilityDescription: "浮窗待办") }
        if let i = img {
            i.isTemplate = true
            btn.image = i
            btn.imagePosition = .imageOnly
        } else {
            btn.title = "◔"
        }
        btn.toolTip = "浮窗待办 · 点击显示 / 隐藏"
        btn.target = self
        btn.action = #selector(toggleVisible)
        btn.sendAction(on: [.leftMouseUp])
        statusItem.isVisible = true
        debugLog("statusItem ok, img=\(img != nil), visible=\(statusItem.isVisible), buttonFrame=\(btn.frame)")
    }

    /* 诊断日志：数据目录 logs/ 下（600、512 KB 轮转）。
       早先写在 /tmp，那是 0644、全机可读，内容却包含
       使用时段、屏幕秒数、会议数、锁屏时长、前台计时秒数。
       现在放到自己的 Logs 目录、权限 600、超过 512 KB 轮转一份。 */
    func debugLog(_ s: String) {
        NSLog("DeskTodo: \(s)")
        guard let d = "\(Date()) \(s)\n".data(using: .utf8) else { return }
        let fm = FileManager.default
        let dir = store.logsURL
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = store.logURL
        if let a = try? fm.attributesOfItem(atPath: f.path),
           let sz = (a[.size] as? NSNumber)?.intValue, sz > 512 * 1024 {
            try? fm.removeItem(at: f.appendingPathExtension("old"))
            try? fm.moveItem(at: f, to: f.appendingPathExtension("old"))
        }
        if !fm.fileExists(atPath: f.path) {
            try? d.write(to: f)
        } else if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile(); h.write(d); try? h.close()
        }
        _ = chmod(f.path, 0o600)
    }

    @objc func toggleVisible() {
        guard let w = window else { return }
        if w.isVisible {
            hideToDot()
        } else {
            showMain()
        }
    }

    // MARK: 点击外部自动收起

    /// 窗口拿到键盘焦点 ≠ 用户在用它：开机、`open -a`、切换输入法都可能让窗口瞬时成为 key。
    /// 这里刻意什么都不做，只认两种"真的在用"：
    ///   1) 鼠标点在窗口里（下面的 localMonitor）
    ///   2) 用户主动展开（showMain）
    /// 否则启动时被系统激活一下，焦点一还给别人就把窗口收成小圆点了。
    func windowDidBecomeKey(_ notification: Notification) {}

    /// 窗口丢掉了键盘焦点：用户点了别处（别的 app、桌面、别的窗口）
    func windowDidResignKey(_ notification: Notification) {
        guard window?.isVisible == true, engagedAt != nil else { return }
        debugLog("resignKey -> scheduleAutoHide")
        scheduleAutoHide()
    }

    /// 摆到哪儿就记到哪儿（拖完、跨屏、拉过尺寸都算）
    func windowDidMove(_ notification: Notification) {
        guard posReady, window?.isVisible == true else { return }
        saveWindowAnchor()
    }

    func installAutoHide() {
        // 1) 点桌面上任何别的地方（包括别的 app 的窗口）
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.externalClick() }
        }
        // 2) 自己的窗口内点击：只用来"续命"，不算外部
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            self?.engagedAt = Date()
            self?.cancelPendingAutoHide()
            return e
        }
        // 3) 我们自己被抢了前台（点了浏览器 / 访达 / 桌面）—— 这才是真正的"离开"
        //    启动时我们本来就不是前台，所以不会一开机就把窗口收起来
        becameObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.selfActive = true
            self.activeSince = Date()
            // 注意：这里不算"用户在用"，只有真的点进窗口才算，
            // 否则开机/启动时被系统激活一下，切回别的 App 就把窗口收掉了
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let dwell = Date().timeIntervalSince(self.activeSince)
            self.selfActive = false
            // 只是"闪一下"（启动瞬间的激活抖动）不算用户离开；
            // 而且必须真的点过窗口，才认为"这窗口是在用的"
            guard dwell > 0.6, self.engagedAt != nil else { return }
            self.debugLog("resignActive dwell=\(Int(dwell*1000))ms -> scheduleAutoHide")
            self.cancelPendingAutoHide()
            self.scheduleAutoHide()
        }
    }

    func cancelPendingAutoHide() {
        autoHideWork?.cancel()
        autoHideWork = nil
    }

    func externalClick() {
        guard let w = window, w.isVisible else { return }
        let p = NSEvent.mouseLocation
        if w.frame.insetBy(dx: -1, dy: -1).contains(p) { return }
        if let d = dotWindow, d.isVisible, d.frame.insetBy(dx: -6, dy: -6).contains(p) { return }
        scheduleAutoHide()
    }

    /// 给用户留一点点时间：万一只是点到了输入法候选框，就别急着收
    func scheduleAutoHide() {
        cancelPendingAutoHide()
        let work = DispatchWorkItem { [weak self] in self?.maybeAutoHide() }
        autoHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    func maybeAutoHide() {
        guard let w = window, w.isVisible else { return }
        guard suppressCount == 0, !menuOpen else { return }
        guard Date() > alertUntil else { return }
        // 刚启动的头几秒不收拾，免得开应用的一瞬间就被收成小圆点
        guard Date().timeIntervalSince(launchedAt) > 3 else { return }
        // 问一下页面：是不是正在拼音选词 / 菜单开着 / 正在拉尺寸
        webView.evaluateJavaScript("window.__beforeBlur ? window.__beforeBlur() : false") { [weak self] result, _ in
            guard let self = self else { return }
            if let busy = result as? Bool, busy { return }
            self.debugLog("maybeAutoHide -> hideToDot")
            self.hideToDot()
        }
    }

    /// 每秒一拍：窗口收成小圆点时网页的定时器会被系统降频甚至停掉，
    /// 这里从原生侧叫醒页面，保证闹钟照常触发（不再"静默"）。
    func startHeartbeat() {
        heartbeat?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard !(self.window?.isVisible ?? false) else { return }
            self.webView?.evaluateJavaScript("window.__tick && window.__tick();", completionHandler: nil)
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
    }
}
