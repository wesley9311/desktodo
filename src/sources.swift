import Foundation
import Cocoa
import EventKit
import SQLite3

// MARK: - 外部真实数据源
//
// 这里只做三件事：把系统里已有的真实数据读出来、原样交给页面、读不到就如实说读不到。
// 没有任何补数、估算、按 due 猜测历史的行为。

final class ExtSources {

    static let shared = ExtSources()
    private let ek = EKEventStore()
    private var nameCache: [String: String] = [:]

    // MARK: 授权状态

    private func statusString(_ st: EKAuthorizationStatus) -> String {
        if #available(macOS 14.0, *) {
            switch st {
            case .fullAccess: return "ok"
            case .writeOnly: return "writeonly"
            case .denied, .restricted: return "denied"
            case .notDetermined: return "ask"
            default: return "unknown"
            }
        } else {
            switch st {
            case .authorized: return "ok"
            case .denied, .restricted: return "denied"
            case .notDetermined: return "ask"
            default: return "unknown"
            }
        }
    }

    func calStatus() -> String { statusString(EKEventStore.authorizationStatus(for: .event)) }
    func remStatus() -> String { statusString(EKEventStore.authorizationStatus(for: .reminder)) }

    /// 排查用：把原始枚举值也带出来，免得新版系统加了新状态被 default 吞掉
    func rawStatus() -> String {
        let c = EKEventStore.authorizationStatus(for: .event)
        let r = EKEventStore.authorizationStatus(for: .reminder)
        return "cal=\(c.rawValue) rem=\(r.rawValue)"
    }

    /// kind: "cal" / "rem"
    /// onError 回的是系统给的错误串：TCC 拒绝、签名不合格之类都会在这里露出来，
    /// 吞掉它就只能瞎猜"为什么没弹窗"。
    func requestAccess(_ kind: String, done: @escaping (Bool, String?) -> Void) {
        let isCal = (kind == "cal")
        if #available(macOS 14.0, *) {
            if isCal {
                ek.requestFullAccessToEvents { ok, err in
                    DispatchQueue.main.async { done(ok, err.map { "\($0)" }) }
                }
            } else {
                ek.requestFullAccessToReminders { ok, err in
                    DispatchQueue.main.async { done(ok, err.map { "\($0)" }) }
                }
            }
        } else {
            ek.requestAccess(to: isCal ? .event : .reminder) { ok, err in
                DispatchQueue.main.async { done(ok, err.map { "\($0)" }) }
            }
        }
    }

    // MARK: 汇总（页面一次拿全）

    func snapshot(_ done: @escaping ([String: Any]) -> Void) {
        let year = Calendar.current.component(.year, from: Date())
        var out: [String: Any] = [:]
        out["cal"] = calendarSnapshot(year: year)

        let sc = screenSnapshot()
        out["screen"] = sc
        /* 系统的屏幕使用时间能读 → 不启动自己的前台计时器。
           两个都读会得到两个"今天用了多久"，页面只能二选一，
           那不如一开始就别采第二份。 */
        let screenOk = (sc["st"] as? String) == "ok"
        FocusTracker.shared.setNeeded(!screenOk)
        out["focus"] = FocusTracker.shared.snapshot()
        out["session"] = SessionState.snapshot()

        reminderSnapshot(year: year) { rem in
            out["rem"] = rem
            DispatchQueue.main.async { done(out) }
        }
    }

    // MARK: 日历（当年 1/1 → 现在）

    /// 节假日只认系统里真实订阅的那本日历，绝不内置节日表。
    /// 理由：放假与调休每年由国务院公布，写死在代码里第二年就是编的。
    /// 用户没订阅 → 这里返回空，页面就不显示节日，而不是拿一张假表兜底。
    func isHolidayCalendar(_ c: EKCalendar?) -> Bool {
        guard let c = c else { return false }
        let t = (c.title + " " + (c.source?.title ?? "")).lowercased()
        return t.contains("holiday") || t.contains("节假日") || t.contains("假日")
            || t.contains("節日") || t.contains("festival")
    }

    private lazy var dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private lazy var hmFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    func calendarSnapshot(year: Int) -> [String: Any] {
        let st = calStatus()
        guard st == "ok" else { return ["st": st] }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        guard let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)) else {
            return ["st": "error"]
        }
        let now = Date()
        guard start < now else { return ["st": "ok", "n": 0, "days": 0, "sec": 0, "per": [:]] }

        let pred = ek.predicateForEvents(withStart: start, end: now, calendars: nil)
        let events = ek.events(matching: pred)

        var timed = 0, allDay = 0, seconds = 0.0, todayN = 0
        var per: [String: Int] = [:]
        var nextTime = ""
        // 节日名 + 是哪本日历给的（诊断用：空数组 = 这台机器没订阅节假日日历）
        var holi: [String: String] = [:]
        var hcal: [String] = []
        /* 这一天到底是不是放假。只认日历自己写的标记：
           1 = 明确休假（标题带「（休）」）
           0 = 明确调休上班（标题带「（班）」）
           没写 = 不知道（节气、元宵、七夕这种只在"今天是什么日子"里有意义，
                  不能拿来当"这天放假"排除统计） */
        var hoff: [String: Int] = [:]

        let t0 = cal.startOfDay(for: now)
        let t1 = cal.date(byAdding: .day, value: 1, to: t0) ?? now

        for e in events {
            if e.status == .canceled { continue }
            // 你自己点了"不参加"的，不算你的会
            if let me = e.attendees?.first(where: { $0.isCurrentUser }),
               me.participantStatus == .declined { continue }

            guard let s = e.startDate else { continue }
            let fromHoliday = isHolidayCalendar(e.calendar)
            if fromHoliday, let name = e.calendar?.title, !hcal.contains(name) {
                hcal.append(name)
            }
            if e.isAllDay {
                // 节假日日历的全天事件是"节日"，不是你的日程：
                // 混进 allday 会把「另有 50 个全天」说成你的安排，所以分开记。
                if fromHoliday {
                    let k = dayFmt.string(from: s)
                    let t = e.title ?? ""
                    if !t.isEmpty {
                        if holi[k] == nil { holi[k] = t }
                        // 「（休）」和「（班）」是日历自带的调休标记，比日期本身可靠
                        if t.contains("（休）") || t.contains("(休)") {
                            hoff[k] = 1
                        } else if t.contains("（班）") || t.contains("(班)"), hoff[k] == nil {
                            hoff[k] = 0
                        }
                    }
                } else {
                    allDay += 1
                }
                continue
            }
            let en = e.endDate ?? s
            let dur = max(0, min(en.timeIntervalSince(s), 86400))
            timed += 1
            seconds += dur
            per[dayFmt.string(from: s), default: 0] += 1

            if s >= t0 && s < t1 {
                todayN += 1
                if s >= now && nextTime.isEmpty { nextTime = hmFmt.string(from: s) }
            }
        }

        var out: [String: Any] = [
            "st": "ok",
            "n": timed,
            "allday": allDay,
            "sec": Int(seconds),
            "days": per.count,
            "today": todayN,
            "per": per,
            "year": year,
            "holi": holi,
            "hoff": hoff,
            "hcal": hcal
        ]
        if !nextTime.isEmpty { out["next"] = nextTime }
        return out
    }

    // MARK: 提醒事项

    func reminderSnapshot(year: Int, done: @escaping ([String: Any]) -> Void) {
        let st = remStatus()
        guard st == "ok" else { done(["st": st]); return }

        let pred = ek.predicateForReminders(in: nil)
        var replied = false
        ek.fetchReminders(matching: pred) { list in
            guard !replied else { return }
            replied = true

            let arr = list ?? []
            let cal = Calendar.current
            let t0 = cal.startOfDay(for: Date())
            let yearStart = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? t0

            var open = 0, overdue = 0, doneYear = 0, dueToday = 0, noDue = 0
            for r in arr {
                if r.isCompleted {
                    if let c = r.completionDate, c >= yearStart { doneYear += 1 }
                    continue
                }
                open += 1
                guard let dc = r.dueDateComponents, let dd = cal.date(from: dc) else {
                    noDue += 1
                    continue
                }
                if dd < t0 { overdue += 1 }
                else if cal.isDate(dd, inSameDayAs: t0) { dueToday += 1 }
            }

            // fetchReminders 的回调不在主线程：页面注入必须回主线程做
            let payload: [String: Any] = [
                "st": "ok",
                "total": arr.count,
                "open": open,
                "done": doneYear,
                "overdue": overdue,
                "today": dueToday,
                "nodue": noDue
            ]
            DispatchQueue.main.async { done(payload) }
        }
    }

    // MARK: 屏幕使用时间（系统 knowledgeC，需要「完全磁盘访问」）

    /// 系统自己的使用记录。/app/usage 每条是一个区间：ZVALUESTRING = bundle id。
    /// 时间戳是 Cocoa 纪元（2001-01-01 起算的秒），转 Unix 要 +978307200。
    /// 读不到就返回状态，不给 0——0 会被读成"今天没用过电脑"。
    func screenSnapshot() -> [String: Any] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Knowledge/knowledgeC.db").path

        guard FileManager.default.fileExists(atPath: path) else { return ["st": "nofile"] }

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, db != nil else {
            // 不能只说"没权限"：要留下真实原因，否则用户开了权限也看不出为什么还失败
            var why = "rc=\(rc) errno=\(errno)"
            if db != nil {
                why += " sqlite=\(sqlite3_errcode(db)):[\(String(cString: sqlite3_errmsg(db)))]"
            }
            sqlite3_close(db)
            NSLog("DeskTodo screen: open denied \(why)")
            return ["st": "nofda", "why": why]
        }
        defer { sqlite3_close(db) }

        let cal = Calendar.current
        let t0 = cal.startOfDay(for: Date())
        let t1 = cal.date(byAdding: .day, value: 1, to: t0) ?? Date()

        let sql = """
        SELECT ZVALUESTRING, SUM(ZENDDATE - ZSTARTDATE) AS S
        FROM ZOBJECT
        WHERE ZSTREAMNAME = '/app/usage'
          AND ZSTARTDATE >= ? AND ZSTARTDATE < ?
          AND ZVALUESTRING IS NOT NULL
        GROUP BY ZVALUESTRING
        ORDER BY S DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            // 能打开但读不了：通常是表结构变了，不是权限问题，别混为一谈
            let why = "prepare \(sqlite3_errcode(db)):[\(String(cString: sqlite3_errmsg(db)))]"
            NSLog("DeskTodo screen: \(why)")
            return ["st": "noschema", "why": why]
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, t0.timeIntervalSince1970 - 978307200)
        sqlite3_bind_double(stmt, 2, t1.timeIntervalSince1970 - 978307200)

        var rows: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            let bid = String(cString: c)
            let sec = Int(sqlite3_column_double(stmt, 1))
            if sec > 0 { rows.append((bid, min(sec, 86400))) }
        }

        if rows.isEmpty { return ["st": "empty"] }

        let total = rows.reduce(0) { $0 + $1.1 }
        let apps: [[String: Any]] = rows.prefix(6).map {
            ["id": $0.0, "n": appName($0.0), "sec": $0.1]
        }
        return ["st": "ok", "sec": total, "apps": apps, "src": "knowledgeC"]
    }

    // MARK: bundle id → 名字

    func appName(_ bid: String) -> String {
        if let c = nameCache[bid] { return c }
        var name = ""
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
           let b = Bundle(url: u) {
            name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? u.deletingPathExtension().lastPathComponent
        }
        if name.isEmpty {
            // 找不到就露出可辨认的一段，不要把 bundle id 整串塞进界面
            name = bid.hasPrefix("com.apple.") ? String(bid.dropFirst(10)) : bid
        }
        nameCache[bid] = name
        return name
    }
}

// MARK: - 前台 App 计时（零权限，兜底用）
//
// NSWorkspace 的激活通知不需要任何授权，就能知道"现在前台是哪个 app"。
// 只能测到 app 这一层，测不到窗口标题（那个要辅助功能权限，见说明）。
// 只统计本工具运行的时段，不回头补，也不假装知道过去。
//
// 定位：**只在系统「屏幕使用时间」读不到时才启动**（见 setNeeded）。
// 系统的 knowledgeC 覆盖全天、且锁屏期间没有使用记录，比这里准；这里只是兜底。

final class FocusTracker {

    static let shared = FocusTracker()
    private let url = supportDir.appendingPathComponent("focus.json")
    private var days: [String: [String: Int]] = [:]
    private var cur: String?
    private var since = Date()
    private var started = false
    private var dirty = false
    private var canWrite = true     // 旧文件读不出来时置 false，避免用空表覆盖
    private var timer: Timer?

    private lazy var dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @discardableResult
    func start() -> Bool {
        guard !started else { return true }
        started = true
        load()
        cur = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        since = Date()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.flush()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        return true
    }

    /// 只在需要时跑：系统屏幕使用时间能读 → 停掉，不采集、不耗电。
    /// 读不到（没给完全磁盘访问）→ 用这个兜底，否则页面上会一片空白。
    func setNeeded(_ need: Bool) {
        if need { start() } else { stop() }
    }

    func stop() {
        guard started else { return }
        flush()                        // 停之前把已计的时间落盘，别丢
        started = false
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(
            self, name: NSWorkspace.didActivateApplicationNotification, object: nil)
        cur = nil
    }

    var isRunning: Bool { started }

    @objc private func appChanged(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        roll(to: app?.bundleIdentifier)
    }

    private func roll(to bid: String?) {
        let now = Date()
        accumulate(upTo: now)
        cur = bid ?? cur
        since = now
    }

    private func accumulate(upTo now: Date) {
        guard let bid = cur else { since = now; return }
        SessionState.refresh()
        /* 锁屏/熄屏/睡眠期间前台 app 名义上没变，但人不在。
           关键是**从哪一刻开始不在**：人在 10:00 锁屏、12:00 回来，
           计时器 12:00 才发现，那 10:00–12:00 必须整段作废。
           所以截断点取 awayStartedAt，而不是拿"间隔超过 1 小时"去猜——
           猜的那种既会漏（离开 40 分钟照样被算成在用），也会误伤（长会议被丢）。 */
        var end = now
        if let awayAt = SessionState.awayStartedAt, awayAt > since, awayAt < now {
            end = awayAt
        }
        let gap = end.timeIntervalSince(since)
        since = now
        guard gap > 0, gap < 3600 else { return }
        guard bid != Bundle.main.bundleIdentifier else { return }
        guard bid != "com.apple.loginwindow" else { return }
        let k = dayFmt.string(from: end)
        var row = days[k] ?? [:]
        row[bid, default: 0] += Int(gap)
        days[k] = row
        dirty = true
    }

    func flush() {
        accumulate(upTo: Date())
        guard dirty else { return }
        prune()
        save()
    }

    func snapshot() -> [String: Any] {
        accumulate(upTo: Date())
        let k = dayFmt.string(from: Date())
        guard let row = days[k], !row.isEmpty else { return ["st": "ok", "sec": 0, "apps": []] }
        var arr = row.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
        let total = arr.reduce(0) { $0 + $1.1 }
        if arr.count > 6 { arr = Array(arr.prefix(6)) }
        let apps: [[String: Any]] = arr.map {
            ["id": $0.0, "n": ExtSources.shared.appName($0.0), "sec": $0.1]
        }
        return ["st": "ok", "sec": total, "apps": apps, "src": "focus"]
    }

    private func prune() {
        // 兜底数据不留长：7 天够回答"今天用了多久"，留 30 天只是多一份敏感面。
        let keep = 7
        guard days.count > keep else { return }
        let sorted = days.keys.sorted()
        for k in sorted.prefix(days.count - keep) { days.removeValue(forKey: k) }
    }

    private func load() {
        // 文件不存在 = 第一次跑，正常。
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Int]]
        else {
            // 文件在但读不出来：这次就别写了，否则会用一张空表把原记录盖掉。
            canWrite = false
            NSLog("DeskTodo focus: focus.json 读不出来，本次不覆盖")
            return
        }
        days = obj
    }

    private func save() {
        guard canWrite else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: days) else { return }
        do {
            try data.write(to: url, options: .atomic)
            dirty = false
        } catch {
            // 写失败保持 dirty，下一拍还会再试；不再"装作存住了"
            NSLog("DeskTodo focus: 写盘失败 \(error.localizedDescription)")
        }
    }
}
