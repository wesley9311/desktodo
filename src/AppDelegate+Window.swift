import Cocoa
import WebKit

// 建窗、摆位、四边缩放、拖动边缘、闹钟弹窗
extension AppDelegate {

    // MARK: Window build

    func buildWindow() {
        // 没拉过尺寸时，默认宽度跟着视图缩放走：字大了，一行还是装得下那么多字
        let startW = manualSize ? manualW : (W * uiZoom)
        let startH = manualSize ? manualH : normalHeight
        let rect = NSRect(x: 0, y: 0, width: startW, height: startH)
        let w = FloatWindow(contentRect: rect,
                            styleMask: [.borderless, .fullSizeContentView],
                            backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isMovableByWindowBackground = false
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.animationBehavior = .utilityWindow
        w.delegate = self

        let container = NSView(frame: rect)
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        w.contentView = container

        let ve = NSVisualEffectView(frame: rect)
        ve.material = .popover
        ve.blendingMode = .behindWindow
        ve.state = .active
        ve.autoresizingMask = [.width, .height]
        container.addSubview(ve)

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "bridge")
        cfg.mediaTypesRequiringUserActionForPlayback = []

        let wv = WKWebView(frame: rect, configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = self
        wv.allowsMagnification = false
        container.addSubview(wv)

        self.webView = wv
        self.window = w

        loadHTML()
        placeInitial()
        w.orderFrontRegardless()
    }

    func loadHTML() {
        var url: URL?
        // 调试入口：任何本地 HTML 都能拿到 bridge 权限，所以必须显式 --dev 才认
        if devMode, let env = ProcessInfo.processInfo.environment["DESKTODO_HTML"],
           FileManager.default.fileExists(atPath: env) {
            url = URL(fileURLWithPath: env)
        } else {
            url = Bundle.main.url(forResource: "index", withExtension: "html")
        }
        guard let u = url else {
            NSLog("DeskTodo: index.html not found")
            return
        }
        // 缩放要在加载前定好，免得先渲染一帧小的再跳大
        if let wv = webView { wv.pageZoom = uiZoom }
        webView.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent())
    }

    func placeTopRight() {
        guard let w = window else { return }
        let screen = w.screen ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let s = w.frame.size
        w.setFrameOrigin(NSPoint(x: vf.maxX - s.width - 18, y: vf.maxY - s.height - 18))
    }

    // MARK: 窗口自由摆位 + 记忆

    /// 记"右上角"这个锚点：高度变化时我们本来就锚着顶边，
    /// 所以窗口变高变矮都不会让它自己往下漂
    func saveWindowAnchor() {
        guard let f = window?.frame else { return }
        let d = UserDefaults.standard
        d.set(Double(f.maxX), forKey: "winRight")
        d.set(Double(f.maxY), forKey: "winTop")
    }

    func savedWindowTopRight() -> NSPoint? {
        let d = UserDefaults.standard
        guard d.object(forKey: "winRight") != nil, d.object(forKey: "winTop") != nil else { return nil }
        let p = NSPoint(x: d.double(forKey: "winRight"), y: d.double(forKey: "winTop"))
        guard p.x.isFinite, p.y.isFinite else { return nil }
        // 允许贴边、跨屏、甚至一部分挂在屏幕外；彻底飘没了才当没记过
        for s in NSScreen.screens where s.frame.insetBy(dx: -240, dy: -240).contains(p) {
            return p
        }
        return nil
    }

    /// 启动时：记过位置就回原位，没记过才贴右上角
    func placeInitial() {
        guard let w = window else { return }
        if let p = savedWindowTopRight() {
            w.setFrame(NSRect(x: p.x - w.frame.width, y: p.y - w.frame.height,
                              width: w.frame.width, height: w.frame.height),
                       display: false)
        } else {
            placeTopRight()
        }
        posReady = true
        saveWindowAnchor()
    }

    /// 万一窗口被拖到所有屏幕之外（换了显示器 / 拔了外接屏），
    /// 展开时拉回鼠标所在的那块屏幕，保证还能看见
    func rescueIfLost() {
        guard let w = window else { return }
        let f = w.frame
        let visible = NSScreen.screens.contains { s in
            let hit = s.visibleFrame.intersection(f)
            return hit.width >= 80 && hit.height >= 44
        }
        if visible { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        var nf = f
        nf.origin.x = clamp(f.minX, low: vf.minX + 8, high: vf.maxX - f.width - 8)
        nf.origin.y = clamp(f.minY, low: vf.minY + 8, high: vf.maxY - f.height - 8)
        w.setFrame(nf, display: true)
    }

    func clamp(_ v: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        if high <= low { return low }
        return min(max(v, low), high)
    }

    @objc func screenParamsChanged() {
        // 换屏幕只做兜底：位置照旧，除非它已经不在任何屏幕上
        rescueIfLost()
        // 换到更小的屏幕：高度别长出去
        guard let w = window else { return }
        if w.frame.height > maxHeight {
            manualH = maxHeight
            setFrameKeepingTopRight(NSSize(width: w.frame.width, height: maxHeight), animate: false)
        }
    }

    // MARK: Resize / collapse

    // 高度上限跟着"当前这块屏"走，多显示器时不会拿主屏的高度去卡别的屏
    var maxHeight: CGFloat { ((window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 32 }

    func applyHeight(_ h: CGFloat, animate: Bool) {
        guard let w = window else { return }
        contentHeight = max(44, h)
        // 默认高度跟着内容走；你拉过高度就听你的，
        // 但内容比窗口更高时继续跟着长，免得内容被切掉（自适应又不留白）
        var target = min(max(h, 44), maxHeight)
        // 窗口不可见（收成小圆点）时只按内容算高度，免得把 44 的紧凑高度
        // 当成用户尺寸存下来；下次展开会自动回到你亲手拉的那个高度
        if manualSize && !isCollapsed && w.isVisible {
            target = max(min(max(manualH, minH), maxHeight), target)
        }
        setFrameKeepingTopRight(NSSize(width: w.frame.width, height: target), animate: animate)
    }

    /// 锚点是你摆的那个"右上角"：改尺寸时顶边和右边不动，往上/往左长
    func setFrameKeepingTopRight(_ size: NSSize, animate: Bool) {
        guard let w = window else { return }
        var size = size
        // 摆得比较靠下时，别让内容一路长到屏幕外面去（长了就滚动）
        if let vf = (w.screen ?? NSScreen.main)?.visibleFrame {
            let room = w.frame.maxY - vf.minY
            if room > 0 { size.height = min(size.height, max(120, room)) }
        }
        if abs(w.frame.width - size.width) < 1 && abs(w.frame.height - size.height) < 1 { return }
        var f = w.frame
        let top = f.maxY, right = f.maxX
        f.size = size
        f.origin = NSPoint(x: right - size.width, y: top - size.height)
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                w.animator().setFrame(f, display: true)
            }
        } else {
            w.setFrame(f, display: true)
        }
        if posReady { saveWindowAnchor() }
    }

    /// 把整个窗口拉回当前屏幕内（只挪位置，不改尺寸）
    func clampIntoScreen() {
        guard let w = window, let vf = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = w.frame
        if f.width > vf.width - 8 { f.size.width = vf.width - 8 }
        if f.height > vf.height - 8 { f.size.height = vf.height - 8 }
        if f.minX < vf.minX { f.origin.x = vf.minX + 4 }
        if f.maxX > vf.maxX { f.origin.x = vf.maxX - f.width - 4 }
        if f.minY < vf.minY { f.origin.y = vf.minY + 4 }
        if f.maxY > vf.maxY { f.origin.y = vf.maxY - f.height - 4 }
        if f != w.frame {
            w.setFrame(f, display: true)
            if posReady { saveWindowAnchor() }
        }
    }

    func applyManualFrame() {
        guard manualSize, window != nil else { return }
        setFrameKeepingTopRight(NSSize(width: min(max(manualW, minW), maxW),
                                       height: min(max(manualH, minH), maxHeight)),
                                animate: true)
    }

    // MARK: 拖动边缘调尺寸

    func beginResizeDrag() {
        resizeBase = window?.frame
        cancelPendingAutoHide()
    }

    func resizeDrag(edge: String, dw: CGFloat, dh: CGFloat) {
        guard let w = window, let base = resizeBase else { return }
        let vf = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var f = base
        if edge.contains("r") {
            var nw = min(max(base.width + dw, minW), maxW)
            var nx = base.minX
            // 已经贴着屏幕右边：让窗口整体往左让一下，右边始终跟着鼠标
            if nx + nw > vf.maxX { nx = vf.maxX - nw }
            if nx < vf.minX { nx = vf.minX; nw = min(nw, vf.maxX - nx) }
            f.origin.x = nx
            f.size.width = nw
        }
        if edge.contains("l") {
            let nw = min(max(base.width - dw, minW), maxW)
            let nx = max(vf.minX, base.maxX - nw)
            f.origin.x = nx
            f.size.width = base.maxX - nx
        }
        if edge.contains("t") {
            // 顶边跟着鼠标走，底边不动；被屏幕顶/最小高度夹住时顶边回退
            let top = min(base.maxY - dh, vf.maxY)
            var nh = min(max(top - base.minY, minH), maxHeight)
            nh = min(nh, vf.maxY - base.minY)
            f.origin.y = base.minY
            f.size.height = nh
        }
        if edge.contains("b") {
            var nh = min(max(base.height + dh, minH), maxHeight)
            nh = min(nh, max(minH, base.maxY - vf.minY))
            f.origin.y = base.maxY - nh
            f.size.height = nh
        }
        w.setFrame(f, display: true)
    }

    func endResizeDrag() {
        guard let w = window else { return }
        resizeBase = nil
        manualW = min(max(w.frame.width, minW), maxW)
        if !isCollapsed {
            manualSize = true
            manualH = min(max(w.frame.height, minH), maxHeight)
        } else {
            // 收起态只允许拉宽：别把紧凑日程的矮高度记成"你定过的展开高度"
            if manualH < 220 { manualH = max(normalHeight, 460) }
        }
        saveWindowSize()
        saveWindowAnchor()
        // 亲手调过尺寸/位置，就把窗口固定在自己摆的地方
        winUserPos = true
        webView?.evaluateJavaScript("window.__setManual && window.__setManual(true);", completionHandler: nil)
    }

    func setCollapsed(_ value: Bool) {
        guard value != isCollapsed else { return }
        isCollapsed = value
        // 展开时若用户自己调过尺寸，回到他设定的高度（收起态则跟着内容收）
        if !value && manualSize { applyManualFrame() }
    }

    // MARK: Alerts

    func playSound() {
        if soundPlayer == nil {
            let path = "/System/Library/Sounds/Glass.aiff"
            soundPlayer = NSSound(contentsOfFile: path, byReference: true)
        }
        if let s = soundPlayer, s.play() == false {
            NSSound.beep()
        }
    }

    func shakeWindow() {
        guard let w = window else { return }
        let base = w.frame.origin
        let offsets: [CGFloat] = [10, -9, 7, -6, 4, -3, 0]
        for (i, dx) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.055) { [weak self] in
                guard let self = self, let w = self.window else { return }
                w.setFrameOrigin(NSPoint(x: base.x + dx, y: base.y))
            }
        }
    }

    func fireAlert(_ title: String) {
        alertUntil = Date().addingTimeInterval(12)   // 响铃期间别自动收起
        cancelPendingAutoHide()
        playSound()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.playSound() }
        statusItem.button?.contentTintColor = .systemOrange

        // 已经收成小圆点：不抢你的焦点，让圆点报警 + 冒个气泡
        let hidden = !(window?.isVisible ?? false)
        if hidden {
            if dotWindow == nil || dotWindow?.isVisible != true { showDot() }
            setDotAlerting(true)
            showAlertBubble(title)
            // 五分钟没人理就安静下来，提示已经给够了
            alertStopWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.clearDotAlert() }
            alertStopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
            return
        }

        if isCollapsed { isCollapsed = false }
        // 闹钟响时把界面同步展开，否则窗口拉高了页面还停在收起态
        webView.evaluateJavaScript("window.__setCollapsed && window.__setCollapsed(false);", completionHandler: nil)
        dotWindow?.orderOut(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        shakeWindow()
    }
}
