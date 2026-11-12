import Cocoa
import WebKit

// AppDelegate：只有状态和生命周期，方法全在 AppDelegate+*.swift
final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {

    var window: FloatWindow!
    var webView: WKWebView!
    var statusItem: NSStatusItem!
    var soundPlayer: NSSound?
    var dotWindow: NSWindow?
    var dotAlerting = false
    var alertBubble: AlertBubble?
    var alertStopWork: DispatchWorkItem?
    var heartbeat: Timer?

    var isCollapsed = false
    var normalHeight: CGFloat = 460          // 页面报告的内容高度（自适应模式下用它）
    let W: CGFloat = 340

    /// 界面缩放：1.0 = 标准。放大的同时把窗口也等比放宽，
    /// 这样字变大但一行还是那么多内容，不用凑近看。1.0 / 1.15 / 1.3 / 1.5
    var uiZoom: CGFloat = 1.0

    // 手动尺寸：自己拉过宽高之后，展开态高度听你的；收起成小圆点后自动回到"跟着内容"
    var manualSize = false
    var manualW: CGFloat = 340
    var manualH: CGFloat = 520
    var contentHeight: CGFloat = 460
    var resizeBase: NSRect?                  // 开始拉尺寸那一刻的窗口 frame

    // 离开窗口自动收起（常开，不需要开关）
    var suppressCount = 0                    // 选文件面板 / 菜单 期间不收起
    var menuOpen = false
    var alertUntil = Date.distantPast        // 闹钟刚响的一小段不收起
    var autoHideWork: DispatchWorkItem?
    var globalMonitor: Any?
    var localMonitor: Any?

    let minW: CGFloat = 280
    let maxW: CGFloat = 920
    let minH: CGFloat = 110

    /// 启动摆位完成后才开始记录窗口位置，免得把默认位置写进偏好
    var posReady = false

    /// 用户自己拖过窗口 → 之后就固定在那个位置；
    /// 没拖过 → 从圆点展开时窗口跟着圆点走，而不是永远贴右上角
    var winUserPos: Bool {
        get { UserDefaults.standard.bool(forKey: "winUserPos") }
        set { UserDefaults.standard.set(newValue, forKey: "winUserPos") }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.removeObject(forKey: "autoHide")   // 旧开关不再需要
        loadSettings()
        buildStatusItem()
        buildWindow()
        installAutoHide()
        startHeartbeat()
        applyThemeAppearance()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParamsChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // 这一版开始接日历 / 提醒事项：第一次启动问一次，之后不再打扰。
        // 系统权限框要 app 在前台才稳，所以先把窗口唤起来再问。
        let forced = ProcessInfo.processInfo.environment["DESKTODO_AUTH"] == "1"
            || CommandLine.arguments.contains("--auth")
        if forced || !UserDefaults.standard.bool(forKey: "extAsked") {
            UserDefaults.standard.set(true, forKey: "extAsked")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self = self else { return }
                // 点系统权限框时，全局点击会被当成"点了外面"→ 窗口收成小圆点。
                // 授权这一小段先别收，问完再说。
                self.alertUntil = Date().addingTimeInterval(25)
                NSApp.activate(ignoringOtherApps: true)
                self.window?.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.requestBoth()
                }
            }
        }
    }

    // MARK: 设置读写

    func loadSettings() {
        let d = UserDefaults.standard
        if d.object(forKey: "winW") != nil {
            manualW = min(max(d.double(forKey: "winW"), Double(minW)), Double(maxW))
            // 太矮的旧记录直接忽略（之前允许拉到 110，展开后只剩一条缝）
            let h = d.double(forKey: "winH")
            manualH = min(max(h, 220), Double(maxHeight))
            manualSize = d.bool(forKey: "winManual") && h >= 220
        }
        themeMode = d.string(forKey: "themeMode") ?? "auto"
        // uiZoom 有可能被写成字符串（defaults 命令、旧版本），两种都要认，
        // 否则启动后字号会悄悄退回标准
        if let v = d.object(forKey: "uiZoom") as? NSNumber {
            uiZoom = CGFloat(v.doubleValue)
        } else if let s = d.string(forKey: "uiZoom"), let v = Double(s) {
            uiZoom = CGFloat(v)
        }
        if uiZoom < 0.9 { uiZoom = 1.0 }
        d.set(Double(uiZoom), forKey: "uiZoom")   // 顺手把类型修正成数字
        // 旧的"护眼提醒"设置不再使用（不出测距结论的东西都撤掉了）
        for k in ["eyeMin"] { d.removeObject(forKey: k) }
    }

    func saveWindowSize() {
        guard let f = window?.frame else { return }
        let d = UserDefaults.standard
        d.set(Double(f.width), forKey: "winW")
        d.set(Double(f.height), forKey: "winH")
        d.set(manualSize, forKey: "winManual")
    }

    var activeObserver: NSObjectProtocol?
    var becameObserver: NSObjectProtocol?
    var selfActive = false
    var activeSince = Date.distantPast
    var launchedAt = Date()
    var engagedAt: Date?          // 用户真的点过/展开过窗口，才算"在用"
    var weatherTimer: Timer?
    var weatherBusy = false
    var themeMode = "auto" {
        didSet {
            UserDefaults.standard.set(themeMode, forKey: "themeMode")
            applyThemeAppearance()
        }
    }
    /// 圆点皮肤：名称 + 颜色
    let dotPalette: [(String, NSColor)] = [
        ("蓝", NSColor(srgbRed: 0.04, green: 0.49, blue: 1.00, alpha: 1)),
        ("绿", NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)),
        ("橙", NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1)),
        ("粉", NSColor(srgbRed: 1.00, green: 0.35, blue: 0.52, alpha: 1)),
        ("紫", NSColor(srgbRed: 0.58, green: 0.40, blue: 0.95, alpha: 1)),
        ("青", NSColor(srgbRed: 0.00, green: 0.72, blue: 0.76, alpha: 1)),
        ("石墨", NSColor(srgbRed: 0.32, green: 0.34, blue: 0.38, alpha: 1))
    ]
    let dotBaseSize: CGFloat = 30
    let dotAlertSize: CGFloat = 44
    var sourcesBusy = false
    var sourcesTimer: Timer?
    var sourcesAt = Date.distantPast
    var dragMouseOrigin: NSPoint = .zero
    var dragWindowOrigin: NSPoint = .zero
    // MARK: Data

    /// 上一次读盘的结果（normal / recovered / corrupt / fresh）。
    /// 只有状态放这儿；读写、导出、清空的具体做法全在 Storage.swift。
    var storeStatus = StoreStatus()

    /// 存储层。路径、读写、备份、快照、冲突、清空都在它里面。
    let store = Store(dataDirectory: supportDir)

    /// 账本 schemaVersion 高于当前应用时，这里会带上可读原因；界面据此只读。
    var storeReadOnlyReason: String?

    /// 清空之后的一小段静默期：页面内存里还是旧账本，
    /// 任何一个 1 秒 tick 的写盘都会把刚删掉的文件写回来。这期间一律拒写。
    var suppressSavesUntil = Date.distantPast

    /// 清空时把前台计时也停掉，并且本次运行不再启动——
    /// 否则 focus.json 会在 20 秒后被定时器写回来（"删了就是没了"就假了）。
    var focusDisabledUntilRestart = false

    /// 调试入口的第二把钥匙：只有显式 `--dev` 启动时才认
    /// dbgExport / dbgReport / DESKTODO_HTML。光写一个 UserDefaults 不够。
    var devMode: Bool { CommandLine.arguments.contains("--dev") }
}
