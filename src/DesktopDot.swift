import Cocoa
import WebKit

// 收起态的小圆点、闹钟气泡、窗口基类：纯视图，不认识待办数据

// MARK: - Window

final class FloatWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 收起后的桌面小圆点（可拖动、可换色）

final class DotView: NSView {
    var onClick: (() -> Void)?
    var onDragEnd: ((NSPoint) -> Void)?
    var onRightClick: ((NSPoint) -> Void)?

    var tint: NSColor = NSColor(srgbRed: 0.04, green: 0.49, blue: 1.0, alpha: 1.0) {
        didSet { needsDisplay = true }
    }

    /// 闹钟在响：圆点外面套一圈呼吸的红环，右上角挂个感叹号
    var alerting = false {
        didSet {
            needsDisplay = true
            alphaValue = (alerting || hovering) ? 1.0 : 0.62
            if alerting { startPulse() } else { stopPulse() }
        }
    }

    var hovering = false
    var tracking: NSTrackingArea?
    var dragStartMouse = NSPoint.zero
    var dragStartOrigin = NSPoint.zero
    var dragging = false
    var pulseTimer: Timer?
    var pulseOn = false

    func startPulse() {
        stopPulse()
        pulseOn = true
        let t = Timer(timeInterval: 0.62, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pulseOn.toggle()
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        pulseTimer = t
    }

    func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseOn = false
        needsDisplay = true
    }

    deinit { pulseTimer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        // 报警时窗口会变大一点，给红环留出空间；平时贴边
        let pad: CGFloat = alerting ? 9 : 4
        let r = bounds.insetBy(dx: pad, dy: pad)

        // 拖动时给一点柔光，提示"可以摆到任何地方"
        if dragging {
            let halo = NSBezierPath(ovalIn: r.insetBy(dx: -2.5, dy: -2.5))
            tint.withAlphaComponent(0.28).setFill()
            halo.fill()
        }
        if alerting {
            // 呼吸的红环 + 一圈淡淡的光晕，余光就能看见
            let halo = NSBezierPath(ovalIn: r.insetBy(dx: -6, dy: -6))
            NSColor.systemRed.withAlphaComponent(pulseOn ? 0.26 : 0.10).setFill()
            halo.fill()

            let ring = NSBezierPath(ovalIn: r.insetBy(dx: -3.5, dy: -3.5))
            NSColor.systemRed.withAlphaComponent(pulseOn ? 1.0 : 0.45).setStroke()
            ring.lineWidth = 2.4
            ring.stroke()
        }

        let ring = NSBezierPath(ovalIn: r)
        tint.withAlphaComponent(hovering || dragging || alerting ? 1.0 : 0.86).setFill()
        ring.fill()

        let inner = NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.33, dy: r.height * 0.33))
        NSColor.white.withAlphaComponent(0.95).setFill()
        inner.fill()

        if alerting {
            // 右上角小徽标
            let bs: CGFloat = 13
            let br = NSRect(x: bounds.maxX - bs - 1.5, y: bounds.maxY - bs - 1.5, width: bs, height: bs)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: br).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .heavy),
                .foregroundColor: NSColor.white
            ]
            let s = NSAttributedString(string: "!", attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: br.midX - sz.width / 2, y: br.midY - sz.height / 2))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        alphaValue = 1.0
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        // 报警时别淡下去：红圈要在余光里也看得见
        alphaValue = alerting ? 1.0 : 0.62
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
        dragging = false
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragStartMouse.x
        let dy = now.y - dragStartMouse.y
        if !dragging && (abs(dx) > 2 || abs(dy) > 2) {
            dragging = true
            needsDisplay = true
        }
        if dragging {
            w.setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.openHand.set()
        if dragging {
            dragging = false
            needsDisplay = true
            if let origin = window?.frame.origin { onDragEnd?(origin) }
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(NSEvent.mouseLocation)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - 圆点旁边的闹钟气泡（点一下就能展开）

final class AlertBubble: NSWindow {
    var onOpen: (() -> Void)?

    let titleLabel = NSTextField(labelWithString: "")
    let hintLabel = NSTextField(labelWithString: "点击查看这条待办")
    var dismissWork: DispatchWorkItem?

    init() {
        let size = NSSize(width: 238, height: 62)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        animationBehavior = .utilityWindow

        let box = ClickBox(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.cornerRadius = 14
        box.layer?.cornerCurve = .continuous
        box.layer?.masksToBounds = true
        box.layer?.borderWidth = 0.5
        box.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        box.onClick = { [weak self] in
            self?.dismiss()
            self?.onOpen?()
        }

        let ve = NSVisualEffectView(frame: box.bounds)
        ve.material = .popover
        ve.blendingMode = .behindWindow
        ve.state = .active
        ve.autoresizingMask = [.width, .height]
        box.addSubview(ve)

        // 底色压一层，浮在乱七八糟的窗口上也看得清
        let tint = NSView(frame: box.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55).cgColor
        tint.autoresizingMask = [.width, .height]
        box.addSubview(tint)

        let bell = NSTextField(labelWithString: "⏰")
        bell.font = NSFont.systemFont(ofSize: 16)
        bell.alignment = .center
        bell.frame = NSRect(x: 8, y: 21, width: 30, height: 20)
        box.addSubview(bell)

        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: 42, y: 32, width: size.width - 54, height: 17)
        box.addSubview(titleLabel)

        hintLabel.font = NSFont.systemFont(ofSize: 10.5)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.frame = NSRect(x: 42, y: 14, width: size.width - 54, height: 14)
        box.addSubview(hintLabel)

        contentView = box
    }

    func show(text: String, near dotFrame: NSRect) {
        titleLabel.stringValue = text.isEmpty ? "该做这件事了" : text
        let size = frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(dotFrame) }
            ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // 优先放在圆点左边，放不下就右边
        var x = dotFrame.minX - size.width - 10
        if x < vf.minX + 6 { x = dotFrame.maxX + 10 }
        x = min(max(x, vf.minX + 6), vf.maxX - size.width - 6)
        var y = dotFrame.midY - size.height / 2
        y = min(max(y, vf.minY + 6), vf.maxY - size.height - 6)
        setFrameOrigin(NSPoint(x: x, y: y))

        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            animator().alphaValue = 1
        }

        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 14, execute: work)
    }

    func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.orderOut(nil) })
    }

    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        orderOut(nil)
    }
}

/// 整块气泡都能点
final class ClickBox: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
