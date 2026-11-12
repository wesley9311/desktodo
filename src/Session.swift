import Cocoa
import CoreGraphics

// MARK: - 人到底在不在
//
// 只回答三个问题：有没有输入、屏幕锁没锁、机器睡没睡。
// 不记录按了什么键、点了哪里、窗口里是什么内容——系统只给时长和布尔值，我们只要这个。
// 用途只有一个：别把「锁屏 2 小时」算成「你在用 Arc 2 小时」。

enum SessionState {

    /// 距最后一次键鼠输入过了多少秒（全局合并状态，不含任何内容）
    static var idleSeconds: Int {
        // ~0 就是 kCGAnyInputEventType（任意输入事件），这不是魔法数，
        // 是 CoreGraphics 自己定义的"所有输入"哨兵值。
        let any = CGEventType(rawValue: ~0) ?? .null
        let s = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
        // 超过一周的返回值当异常（休眠唤醒后偶发巨大数），不往界面上送
        guard s.isFinite, s >= 0, s < 86400 * 7 else { return 0 }
        return Int(s)
    }

    /// 屏幕是否锁着（锁屏界面 / 登录窗口）
    static var isLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let b = d["CGSSessionScreenIsLocked"] as? Bool { return b }
        if let n = d["CGSSessionScreenIsLocked"] as? Int { return n != 0 }
        return false
    }

    /// 显示器是否已睡眠（熄屏/合盖，但主机还醒着）
    static var displayAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    /// 系统是否正在睡眠。靠通知维护，不轮询。
    private(set) static var systemAsleep = false

    /// 屏保是否在跑（屏保不一定锁屏，但人已经走了）
    private(set) static var screensaver = false

    /// 当前会话是否在"前台"（快速用户切换后，原用户仍在跑但看不见屏幕）
    static var onConsole: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        if let b = d["CGSSessionOnConsoleKey"] as? Bool { return b }
        if let n = d["CGSSessionOnConsoleKey"] as? Int { return n != 0 }
        return true
    }

    private static var watching = false
    private static var awaySince: Date?

    static func watchSleep() {
        guard !watching else { return }
        watching = true

        let c = NSWorkspace.shared.notificationCenter
        c.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            markAway()
        }
        c.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            // 唤醒后系统可能还在锁屏，不要立刻清空 away，
            // 下一拍 refresh() 会按真实状态决定。
            systemAsleep = false
            refresh()
        }

        // 屏保走的是分布式通知中心，不是 workspace 的
        let d = DistributedNotificationCenter.default()
        d.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstart"),
                      object: nil, queue: .main) { _ in
            screensaver = true
            markAway()
        }
        d.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstop"),
                      object: nil, queue: .main) { _ in
            screensaver = false
            refresh()
        }
    }

    private static func markAway() {
        if awaySince == nil { awaySince = Date() }
    }

    /// 现在这一刻算不算"人不在"。
    /// 只用确定的信号：锁屏、熄屏、系统睡眠、屏保、不在前台会话。
    /// **不用空闲时长**——看视频、读长文档时键鼠也是静止的，按空闲剔除会把真实使用抹掉。
    static var isAway: Bool { isLocked || displayAsleep || systemAsleep || screensaver || !onConsole }

    /// 每隔几秒调一次，维护"从什么时候开始不在"。
    /// 这个时间点是前台计时器唯一能用的截断依据：人在 10:00 锁屏，
    /// 12:00 回来计时器才发现，那 10:00–12:00 这段必须整段作废，
    /// 而不是靠"间隔太长"去猜。
    @discardableResult
    static func refresh() -> Bool {
        if isAway {
            if awaySince == nil { awaySince = Date() }
        } else {
            awaySince = nil
        }
        return isAway
    }

    /// 本次离开是从哪一刻开始的（没离开就是 nil）
    static var awayStartedAt: Date? { awaySince }

    /// 已经离开多少秒（没离开是 0）。只用于文案，不作为权限或统计依据。
    static var awaySeconds: Int {
        guard let s = awaySince else { return 0 }
        return max(0, Int(Date().timeIntervalSince(s)))
    }

    /// 给页面看的一行状态，字段少但有定义，别处不许再自己算。
    static func snapshot() -> [String: Any] {
        refresh()
        return [
            "idle": idleSeconds,
            "locked": isLocked,
            "screenoff": displayAsleep,
            "asleep": systemAsleep,
            "screensaver": screensaver,
            "console": onConsole,
            "away": isAway,
            "awaySec": awaySeconds
        ]
    }
}
