import Cocoa
import WebKit

// 收起成圆点 / 从圆点唤回 / 圆点尺寸与颜色
extension AppDelegate {

    // MARK: 收起 / 唤回

    var dotTintIndex: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "dotTint")
            return (v >= 0 && v < dotPalette.count) ? v : 0
        }
        set { UserDefaults.standard.set(newValue, forKey: "dotTint") }
    }

    func showDot() {
        let size = dotSize
        if dotWindow == nil {
            let dw = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            dw.isOpaque = false
            dw.backgroundColor = .clear
            dw.hasShadow = false
            dw.level = .floating
            dw.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            dw.isReleasedWhenClosed = false
            let v = DotView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            v.onClick = { [weak self] in self?.showMain() }
            v.onDragEnd = { [weak self] origin in
                guard let self = self else { return }
                // 报警时窗口大一圈，存位置要折算回小圆点的坐标，换尺寸时才不会飘
                let grow = (self.dotSize - self.dotBaseSize) / 2
                self.saveDotOrigin(NSPoint(x: origin.x + grow, y: origin.y + grow))
            }
            v.onRightClick = { [weak self] p in self?.showDotMenu(at: p) }
            v.alphaValue = 0.62
            v.toolTip = "点击展开「浮窗待办」· 按住拖到任意位置 · 右键更多"
            dw.contentView = v
            dotWindow = dw
        }
        if let v = dotWindow?.contentView as? DotView {
            v.tint = dotPalette[dotTintIndex].1
            v.alerting = dotAlerting
        }
        guard let dw = dotWindow else { return }
        // 记住你摆的位置（可以跨屏、可以贴边甚至半挂在屏幕外）；没摆过才贴右上角
        let base = savedDotOrigin() ?? defaultDotBase()
        dw.setFrame(NSRect(origin: windowOrigin(forBase: base),
                           size: NSSize(width: size, height: size)), display: true)
        dw.orderFrontRegardless()
    }

    var dotSize: CGFloat { dotAlerting ? dotAlertSize : dotBaseSize }

    func defaultDotBase() -> NSPoint {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vf.maxX - dotBaseSize - 12, y: vf.maxY - dotBaseSize - 12)
    }

    /// 存的是"30×30 小圆点"的左下角，窗口变大时按中心对齐换算
    func windowOrigin(forBase base: NSPoint) -> NSPoint {
        let grow = (dotSize - dotBaseSize) / 2
        return NSPoint(x: base.x - grow, y: base.y - grow)
    }

    /// 闹钟在响：圆点变大一点、套红圈 + 感叹号
    func setDotAlerting(_ on: Bool) {
        guard on != dotAlerting else { return }
        guard let dw = dotWindow else {
            dotAlerting = on
            return
        }
        let base = NSPoint(x: dw.frame.origin.x + (dw.frame.width - dotBaseSize) / 2,
                           y: dw.frame.origin.y + (dw.frame.height - dotBaseSize) / 2)
        dotAlerting = on
        let s = dotSize
        dw.setFrame(NSRect(origin: windowOrigin(forBase: base), size: NSSize(width: s, height: s)),
                    display: true)
        (dw.contentView as? DotView)?.alerting = on
    }

    func showAlertBubble(_ text: String) {
        if alertBubble == nil {
            let b = AlertBubble()
            b.onOpen = { [weak self] in
                guard let self = self else { return }
                self.clearDotAlert()
                self.showMain()
            }
            alertBubble = b
        }
        guard let dw = dotWindow else { return }
        alertBubble?.show(text: text, near: dw.frame)
    }

    func clearDotAlert() {
        alertStopWork?.cancel()
        alertStopWork = nil
        setDotAlerting(false)
        alertBubble?.dismiss()
    }

    func savedDotOrigin() -> NSPoint? {
        let d = UserDefaults.standard
        guard d.object(forKey: "dotX") != nil else { return nil }
        let p = NSPoint(x: d.double(forKey: "dotX"), y: d.double(forKey: "dotY"))
        guard p.x.isFinite, p.y.isFinite else { return nil }
        // 允许贴着屏幕边、甚至一半挂在屏幕外（跨屏也自由）；
        // 只有整个圆点飘到所有屏幕之外太多时，才拉回最近的屏幕，免得找不回来
        let screens = NSScreen.screens
        for s in screens where s.frame.insetBy(dx: -60, dy: -60).contains(p) {
            return p
        }
        var best: NSPoint?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for s in screens {
            let f = s.frame
            let q = NSPoint(x: min(max(p.x, f.minX), f.maxX - 16),
                            y: min(max(p.y, f.minY), f.maxY - 16))
            let dist = hypot(q.x - p.x, q.y - p.y)
            if dist < bestDist { bestDist = dist; best = q }
        }
        return best
    }

    func saveDotOrigin(_ p: NSPoint) {
        let d = UserDefaults.standard
        d.set(Double(p.x), forKey: "dotX")
        d.set(Double(p.y), forKey: "dotY")
    }

    /// 圆点右键：就算摆到奇怪的位置，也能从菜单里找回来
    func showDotMenu(at screenPoint: NSPoint) {
        let menu = NSMenu()
        let open = NSMenuItem(title: "展开悬浮窗", action: #selector(expandFromDot), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let tint = NSMenuItem(title: "小圆点颜色", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, entry) in dotPalette.enumerated() {
            let mi = NSMenuItem(title: entry.0, action: #selector(setDotColor(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.image = dotSwatch(entry.1)
            mi.state = (i == dotTintIndex) ? .on : .off
            sub.addItem(mi)
        }
        tint.submenu = sub
        menu.addItem(tint)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出浮窗待办", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil, at: screenPoint, in: nil)
    }

    @objc func expandFromDot() { showMain() }

    @objc func setDotColor(_ sender: NSMenuItem) {
        dotTintIndex = sender.tag
        if let v = dotWindow?.contentView as? DotView {
            v.tint = dotPalette[sender.tag].1
        }
    }

    func dotSwatch(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 13, height: 13))
        img.lockFocus()
        let r = NSRect(x: 2, y: 2, width: 9, height: 9)
        color.setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 3, dy: 3)).fill()
        img.unlockFocus()
        return img
    }

    func hideToDot() {
        cancelPendingAutoHide()
        engagedAt = nil
        // 离开时把"正在写入"这个目标一并取消，免得下次回来还挂在某个项目上
        webView?.evaluateJavaScript("window.__onBlur && window.__onBlur();", completionHandler: nil)
        // 注意：不清 manualSize。收起态本来就按内容算高度（见 applyHeight），
        // 展开时再按你亲手拉过的尺寸复原。
        window.orderOut(nil)
        showDot()
    }

    func showMain() {
        debugLog("showMain engaged=\(engagedAt != nil)")
        let fromDot = (dotWindow?.isVisible ?? false)
        // 没自己摆过窗口的话，就贴着你放圆点的那块地方展开
        if fromDot && !winUserPos { placeNearDot() }
        // 亲手拉过尺寸：按你的尺寸展开，而不是从 44 高的紧凑条慢慢长出来
        if manualSize {
            setFrameKeepingTopRight(NSSize(width: min(max(manualW, minW), maxW),
                                           height: min(max(manualH, minH), maxHeight)),
                                    animate: false)
        }
        clearDotAlert()
        dotWindow?.orderOut(nil)
        // 摆过的位置不回退：只有彻底跑到屏幕外才拉回来
        rescueIfLost()
        // 是用户主动展开的：从这一刻起算"在用"，之后切走就收起
        engagedAt = Date()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView?.evaluateJavaScript("window.__onShow && window.__onShow();", completionHandler: nil)
        // 展开时顺手对一遍：日历/提醒事项刚改过也能立刻看到（90 秒内不重复读）
        if Date().timeIntervalSince(sourcesAt) > 90 { refreshSources() }
    }

    /// 贴着圆点展开：优先放左边，放不下放右边；上下都钳在屏幕里
    func placeNearDot() {
        guard let dw = dotWindow, let w = window else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(dw.frame) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let dot = dw.frame
        let size = w.frame.size
        let gap: CGFloat = 10
        var x = dot.minX - size.width - gap
        if x < vf.minX { x = dot.maxX + gap }
        x = clamp(x, low: vf.minX + 6, high: vf.maxX - size.width - 6)
        var y = dot.maxY - size.height
        y = clamp(y, low: vf.minY + 6, high: vf.maxY - size.height - 6)
        w.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
    }
}
