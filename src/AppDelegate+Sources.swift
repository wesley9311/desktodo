import Cocoa
import WebKit

// 外部数据来源接线：日历 / 提醒事项 / 屏幕时间 / 年度公告
extension AppDelegate {

    // MARK: 数据来源：日历 / 提醒事项 / 屏幕使用时间

    /// 状态 → 人话
    func statusText(_ s: String) -> String {
        switch s {
        case "ok": return "已连接"
        case "writeonly": return "只写权限（读不到）"
        case "ask": return "还没授权"
        case "denied": return "已被拒绝"
        case "restricted": return "被系统限制"
        case "nofda": return "需要「完全磁盘访问」"
        case "nofile": return "系统里没有这份记录"
        case "empty": return "今天还没有记录"
        case "noschema": return "记录格式对不上"
        default: return "未知"
        }
    }

    func sourceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "数据来源", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        func statusLine(_ name: String, _ st: String) -> NSMenuItem {
            let mi = NSMenuItem(title: "\(name)：\(statusText(st))", action: nil, keyEquivalent: "")
            mi.isEnabled = false
            return mi
        }

        sub.addItem(statusLine("日历", ExtSources.shared.calStatus()))
        let rc = NSMenuItem(title: "请求日历授权…", action: #selector(askCalendarAccess), keyEquivalent: "")
        rc.target = self
        sub.addItem(rc)
        if ExtSources.shared.calStatus() == "denied" {
            let go = NSMenuItem(title: "打开「日历」隐私设置…", action: #selector(openCalPrivacy), keyEquivalent: "")
            go.target = self
            sub.addItem(go)
        }

        sub.addItem(.separator())

        sub.addItem(statusLine("提醒事项", ExtSources.shared.remStatus()))
        let rr = NSMenuItem(title: "请求提醒事项授权…", action: #selector(askReminderAccess), keyEquivalent: "")
        rr.target = self
        sub.addItem(rr)
        if ExtSources.shared.remStatus() == "denied" {
            let go = NSMenuItem(title: "打开「提醒事项」隐私设置…", action: #selector(openRemPrivacy), keyEquivalent: "")
            go.target = self
            sub.addItem(go)
        }

        sub.addItem(.separator())

        let sc = ExtSources.shared.screenSnapshot()
        sub.addItem(statusLine("屏幕使用时间", (sc["st"] as? String) ?? "unknown"))
        let fda = NSMenuItem(title: "打开「完全磁盘访问」设置…", action: #selector(openFDA), keyEquivalent: "")
        fda.target = self
        sub.addItem(fda)

        sub.addItem(.separator())

        let now = NSMenuItem(title: "前台 App 计时：运行中（不需要授权）", action: nil, keyEquivalent: "")
        now.isEnabled = false
        sub.addItem(now)

        let rf = NSMenuItem(title: "立即刷新数据", action: #selector(refreshSourcesNow), keyEquivalent: "")
        rf.target = self
        sub.addItem(rf)

        item.submenu = sub
        return item
    }

    @objc func askCalendarAccess() { requestSource("cal") }
    @objc func askReminderAccess() { requestSource("rem") }

    /// 一次把两个都问了：系统会连着弹两个框，用户点两下就齐了。
    /// 已经被处理过的（同意或拒绝）不再问，系统也不会再弹。
    func requestBoth() {
        alertUntil = Date().addingTimeInterval(25)
        let needCal = (ExtSources.shared.calStatus() == "ask")
        let needRem = (ExtSources.shared.remStatus() == "ask")
        debugLog("requestBoth needCal=\(needCal) needRem=\(needRem) raw=[\(ExtSources.shared.rawStatus())]")

        guard needCal || needRem else {
            refreshSources()
            nativeToast("日历与提醒事项都已处理过 · 菜单「数据来源」里能看状态")
            return
        }

        let step2: () -> Void = { [weak self] in
            guard let self = self else { return }
            if needRem {
                ExtSources.shared.requestAccess("rem") { [weak self] ok, err in
                    guard let self = self else { return }
                    if let err = err { self.debugLog("requestAccess(rem) error: \(err)") }
                    self.debugLog("requestAccess(rem) ok=\(ok) status=\(ExtSources.shared.remStatus())")
                    self.refreshSources()
                    self.nativeToast(ok ? (needCal ? "日历与提醒事项已连接" : "提醒事项已连接") : "提醒事项没拿到授权")
                }
            } else {
                self.refreshSources()
                self.nativeToast("日历已连接")
            }
        }

        if needCal {
            ExtSources.shared.requestAccess("cal") { [weak self] ok, err in
                guard let self = self else { return }
                if let err = err { self.debugLog("requestAccess(cal) error: \(err)") }
                self.debugLog("requestAccess(cal) ok=\(ok) status=\(ExtSources.shared.calStatus())")
                self.refreshSources()
                step2()
            }
        } else {
            step2()
        }
    }

    func requestSource(_ kind: String) {
        ExtSources.shared.requestAccess(kind) { [weak self] ok, err in
            guard let self = self else { return }
            if let err = err { self.debugLog("requestAccess(\(kind)) error: \(err)") }
            if ok {
                self.nativeToast(kind == "cal" ? "日历已连接" : "提醒事项已连接")
            } else {
                self.nativeToast("没拿到授权 · 菜单「数据来源」里有系统设置入口")
            }
            self.refreshSources()
        }
    }

    @objc func openCalPrivacy() { openPrivacyPane("Privacy_Calendars") }
    @objc func openRemPrivacy() { openPrivacyPane("Privacy_Reminders") }
    @objc func openFDA() { openPrivacyPane("Privacy_AllFiles") }

    func openPrivacyPane(_ pane: String) {
        /* 顺序有讲究：macOS 27 上新的 PrivacySecurity.extension scheme 会被"接受"
           （open 返回 true）但实际落在「连接」页，等于点了没反应。
           旧的 preference.security 才真的能定位到具体那一页，所以旧的先试。
           两个都返回 true 也没关系——真开错了用户看得见，别静默失败。 */
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?\(pane)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)"
        ]
        for s in urls {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
        nativeToast("请手动打开：系统设置 › 隐私与安全性")
    }

    @objc func refreshSourcesNow() {
        refreshSources(announce: true)
    }

    func startSources() {
        // 睡眠/唤醒要提前挂钩，否则第一次醒来之前不知道机器睡过
        SessionState.watchSleep()
        // 前台计时器不在这里启动：由 snapshot() 判断系统屏幕时间读不到时才开
        refreshSources()
        guard sourcesTimer == nil else { return }
        // 5 分钟一轮：日历/提醒事项改了就跟着变，屏幕时间也不会太旧
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshSources()
        }
        RunLoop.main.add(t, forMode: .common)
        sourcesTimer = t
    }

    func refreshSources(announce: Bool = false) {
        if sourcesBusy { return }
        sourcesBusy = true
        sourcesAt = Date()
        ExtSources.shared.snapshot(focusAllowed: !focusDisabledUntilRestart) { [weak self] dict in
            guard let self = self else { return }
            self.sourcesBusy = false
            // 升级换了签名 → 系统把已授权的项退回"未决定"。这里检测并主动重问一次。
            self.detectAuthResetIfNeeded(dict)
            if let d = try? JSONSerialization.data(withJSONObject: dict),
               let s = String(data: d, encoding: .utf8) {
                self.webView?.evaluateJavaScript("window.__ext && window.__ext(\(s));", completionHandler: nil)
            }
            let c = dict["cal"] as? [String: Any] ?? [:]
            let r = dict["rem"] as? [String: Any] ?? [:]
            let sc = dict["screen"] as? [String: Any] ?? [:]
            let fg = dict["focus"] as? [String: Any] ?? [:]
            let se = dict["session"] as? [String: Any] ?? [:]
            // 节日来自哪本日历、自己的计时器开没开、人此刻在不在：一行看全，免得以后又靠猜
            let hc = (c["hcal"] as? [String]) ?? []
            let hn = (c["holi"] as? [String: Any])?.count ?? 0
            // 44 里有一半是节气：分开数，才知道"放假"到底几天
            let offs = (c["hoff"] as? [String: Any])?.values.compactMap { $0 as? Int } ?? []
            let offN = offs.filter { $0 == 1 }.count
            let workN = offs.filter { $0 == 0 }.count
            self.debugLog("ext cal=\(c["st"] ?? "-")/\(c["n"] ?? 0)/\(c["days"] ?? 0)d"
                + " rem=\(r["st"] ?? "-")/\(r["open"] ?? 0)open/\(r["overdue"] ?? 0)late"
                + " screen=\(sc["st"] ?? "-")/\(sc["sec"] ?? 0)s"
                + (sc["why"] != nil ? "(\(sc["why"]!))" : "")
                + " focus=\(fg["sec"] ?? 0)s\(FocusTracker.shared.isRunning ? "+" : "-")"
                + " holi=\(hn)\(hc.isEmpty ? "" : "[\(hc.joined(separator: ","))]")"
                + " off=休\(offN)/班\(workN)"
                + " sess=\(self.awayText(se))/idle\(se["idle"] ?? 0)s")
            // 排查"节日 N 天"到底是什么：`defaults write local.desktodo.app dbgHoli -bool true`
            if UserDefaults.standard.bool(forKey: "dbgHoli") {
                let map = (c["holi"] as? [String: String]) ?? [:]
                let sample = map.keys.sorted().prefix(14)
                    .map { "\($0)=\(map[$0] ?? "")" }
                self.debugLog("holi样本 " + sample.joined(separator: " "))
            }
            if announce {
                let c = dict["cal"] as? [String: Any] ?? [:]
                let r = dict["rem"] as? [String: Any] ?? [:]
                var bits: [String] = []
                if (c["st"] as? String) == "ok" { bits.append("日历 \(c["n"] as? Int ?? 0) 项") }
                if (r["st"] as? String) == "ok" { bits.append("待办 \(r["open"] as? Int ?? 0) 件") }
                self.nativeToast(bits.isEmpty ? "已刷新 · 还没有可读的数据" : "已刷新 · " + bits.joined(separator: " · "))
            }
        }
    }

    /* 升级/换签名之后，TCC 会把"已授权"退回"未决定"：
       日历、提醒事项回到 ask，完全磁盘访问回到 nofda。
       系统不会主动再弹框（extAsked 早就写过），用户看到的就是"功能突然没了"。
       这里用"曾经 ok / 现在不是 ok"这个组合来识别重置，主动重问一次，
       并把"完全磁盘访问要手动重加"这句话说清楚。 */
    func detectAuthResetIfNeeded(_ dict: [String: Any]) {
        let d = UserDefaults.standard
        let cal = (dict["cal"] as? [String: Any])?["st"] as? String ?? "?"
        let rem = (dict["rem"] as? [String: Any])?["st"] as? String ?? "?"
        let scr = (dict["screen"] as? [String: Any])?["st"] as? String ?? "?"
        if cal == "ok" { d.set(true, forKey: "everCal") }
        if rem == "ok" { d.set(true, forKey: "everRem") }
        if scr == "ok" { d.set(true, forKey: "everScreen") }

        /* 两种"被重置"的样子：
           1. 曾经 ok、现在退回 ask —— 系统把旧授权收回去了（换签名最常见）；
           2. extAsked 已经写过（说明这个 app 以前问过），但现在还是 ask ——
              同上，只是没有历史记录可对照（本次升级前还没有 ever* 标记）。
           完全磁盘访问单独看：曾经 ok、现在 nofda。 */
        let askStuck = d.bool(forKey: "extAsked") && (cal == "ask" || rem == "ask")
        let reset = askStuck
            || (d.bool(forKey: "everCal") && cal == "ask")
            || (d.bool(forKey: "everRem") && rem == "ask")
            || (d.bool(forKey: "everScreen") && scr == "nofda")
        guard reset else {
            // 全部恢复之后再遇到下一次重置，还要能再提示
            if cal == "ok" && rem == "ok" && scr == "ok" {
                d.set(false, forKey: "authResetHandled")
            }
            return
        }
        guard !d.bool(forKey: "authResetHandled") else { return }
        d.set(true, forKey: "authResetHandled")
        debugLog("authReset: 授权被系统重置 cal=\(cal) rem=\(rem) screen=\(scr)")
        var msg = "权限被系统重置了（这次升级换了签名）"
        if scr == "nofda" { msg += " · 完全磁盘访问要手动去设置里删掉再加回" }
        nativeToast(msg + " · 正在重新请求日历/提醒")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.requestBoth()
        }
    }

    /// 人为什么"不在"：锁屏 / 熄屏 / 睡眠 / 屏保 / 不在前台会话。
    /// 五种原因分开报，出问题时不用再猜是权限还是状态。
    private func awayText(_ se: [String: Any]) -> String {
        if !(se["away"] as? Bool ?? false) { return "on" }
        var r: [String] = []
        if se["locked"] as? Bool ?? false { r.append("locked") }
        if se["screenoff"] as? Bool ?? false { r.append("display") }
        if se["asleep"] as? Bool ?? false { r.append("sleep") }
        if se["screensaver"] as? Bool ?? false { r.append("saver") }
        if !(se["console"] as? Bool ?? true) { r.append("offconsole") }
        let sec = se["awaySec"] as? Int ?? 0
        return (r.isEmpty ? "away" : r.joined(separator: "+")) + "(\(sec)s)"
    }

    // MARK: 年度公告（每年 12/20 - 次年 1/15 自动出现，这里可以提前看效果）

    @objc func previewAnniversary() {
        if window?.isVisible != true { showMain() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.webView.evaluateJavaScript("window.__annivPreview && window.__annivPreview();", completionHandler: nil)
            self?.nativeToast("这是预览 · 每年 12/20 到次年 1/15 会自动出现")
        }
    }
}
