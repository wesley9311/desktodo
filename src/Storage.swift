import Cocoa
import WebKit
import UniformTypeIdentifiers
import Darwin

/* 全 app 只有这一处知道四件事：数据放哪、怎么写进去、怎么带出去、怎么删掉。

   这条注释以前是假的：路径写在这里，读写却写在 AppDelegate.swift 里，
   而那个文件开头写着"只有状态和生命周期"——两个文件都在说谎。
   现在归位：路径 + 安全规则 + 导出 + 清空都在这个文件，
   AppDelegate.swift 只剩状态和生命周期。

   安全规则（别处不许绕）：
     1. 只有"形状对"的 JSON 才准落盘：v 是数字、nodes（或旧版 tasks）是数组。
        只验"能不能解析"不够——`null` / `{}` 都能解析，但会把整本账覆盖成空。
     2. 覆盖前把上一版留成 data.json.bak，再往前留 .bak.1 / .bak.2 两代。
     3. 每天第一笔写入留一份当日快照（snapshots/data-YYYY-MM-DD.json），只留最近 30 天。
     4. 主文件坏了先改名留证，再退备份；备份也坏了同样留证，绝不静默变成空清单。
     5. 写盘是「同目录临时文件 → fsync → rename → fsync 目录」：
        掉电最多回到上一版，不会留下半截文件。
     6. 写之前先看磁盘上那份还是不是我们上次读/写的那份；不是就报冲突、不覆盖。
        （配合单实例保护，这一条是第二道保险。）
     7. 删就是 delete——不进废纸篓、不留副本。 */

// MARK: - 路径

/// 测试/自检用：设了 DESKTODO_TEST_HOME 就把数据目录指向临时位置，
/// 真实用户数据一个字节都不碰（`--selftest` 和 build.sh 的构建闸门靠它）。
let isTestHome: Bool = {
    !(ProcessInfo.processInfo.environment["DESKTODO_TEST_HOME"] ?? "").isEmpty
}()

let supportDir: URL = {
    if isTestHome, let h = ProcessInfo.processInfo.environment["DESKTODO_TEST_HOME"] {
        let dir = URL(fileURLWithPath: (h as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("DeskTodo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("DeskTodo", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

let storeURL = supportDir.appendingPathComponent("data.json")
let storeBackupURL = supportDir.appendingPathComponent("data.json.bak")
let snapshotDir = supportDir.appendingPathComponent("snapshots", isDirectory: true)
let lockURL = supportDir.appendingPathComponent(".desk.lock")
let focusURL = supportDir.appendingPathComponent("focus.json")

/// 数据格式版本。加字段只加不改；导出文件里也写这个数——
/// 哪天这个 app 不在了，别人靠它对得上格式。
let storeSchemaVersion = 2

/// 这一次读盘到底发生了什么。界面必须能看见，不能只有日志知道。
struct StoreStatus {
    enum Kind: String {
        case fresh       // 没有文件，当新用户
        case normal      // 主文件正常
        case recovered   // 主文件坏了，用上了备份
        case corrupt     // 主文件坏了，备份也没有
    }
    var kind: Kind = .normal
    var kept: [String] = []      // 留证下来的坏文件名
    var at = Date()
}

/// 写盘结果。调用方必须分得清"写进去了"和"被拒/有冲突"——
/// 否则"我勾完了"和"一个字节都没写"会同时成立。
enum StoreWrite: Equatable {
    case ok
    case rejected
    case conflict(String)        // 磁盘上已经是别人的版本，带上它让页面重新载入
}

// MARK: - 基础工具

private let stampFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f
}()

private let dayFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

/// 同目录临时文件 + fsync + rename + fsync 目录。
/// 返回 false 时磁盘上的旧文件保持原样（这是"宁可不写，也不写坏"）。
@discardableResult
func atomicWrite(_ data: Data, to dest: URL) -> Bool {
    let fm = FileManager.default
    let dir = dest.deletingLastPathComponent()
    let tmp = dir.appendingPathComponent(".\(dest.lastPathComponent).tmp-\(getpid())")
    do {
        if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
        try data.write(to: tmp, options: [])
        _ = chmod(tmp.path, 0o600)
        let fh = try FileHandle(forWritingTo: tmp)
        try fh.synchronize()
        try fh.close()
        if rename(tmp.path, dest.path) != 0 {
            throw NSError(domain: "DeskTodo.rename", code: Int(errno))
        }
        let dfd = open(dir.path, O_RDONLY)
        if dfd >= 0 { _ = fsync(dfd); close(dfd) }
        return true
    } catch {
        NSLog("DeskTodo atomicWrite 失败 \(dest.lastPathComponent): \(error.localizedDescription)")
        try? fm.removeItem(at: tmp)
        return false
    }
}

/// 写盘期间互斥：单实例是第一道，这把文件锁是第二道
/// （旧版本被双击、或测试里手动起两个进程时，至少有序列化，不会写出半截文件）。
func withStoreLock<T>(_ body: () -> T) -> T {
    let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
    if fd >= 0 { _ = flock(fd, LOCK_EX) }
    defer {
        if fd >= 0 { _ = flock(fd, LOCK_UN); close(fd) }
    }
    return body()
}

// MARK: - 数据读写

extension AppDelegate {

    /// 形状校验：能解析 **且** 是"账本该有的样子"。
    /// 只验解析的话，`null` / `{}` / `[]` 都能过，一次坏 payload 就能把好账覆盖成空账。
    func isValidStore(_ s: String) -> Bool {
        guard let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        // v 必须是数字（JSON 里 true/false 也是 NSNumber，用 objCType 排掉）
        guard let v = obj["v"] as? NSNumber, String(cString: v.objCType) != "c" else { return false }
        if let nodes = obj["nodes"] { return nodes is [Any] }
        if let tasks = obj["tasks"] { return tasks is [Any] }   // 早期格式，__load 里还能迁移
        return false
    }

    static func backupURL(of url: URL) -> URL {
        url.appendingPathExtension("bak")     // data.json → data.json.bak
    }

    @discardableResult
    func safeRead(_ url: URL) -> String? {
        guard let s = try? String(contentsOf: url, encoding: .utf8),
              !s.isEmpty, isValidStore(s) else { return nil }
        return s
    }

    /// 低层原子写（不碰备份、不碰冲突检测）：恢复主文件、自检时用。
    @discardableResult
    func safeWrite(_ json: String, to url: URL) -> Bool {
        guard isValidStore(json) else {
            NSLog("DeskTodo save: 拒绝写入非法数据（\(json.count) 字节，形状不对）")
            return false
        }
        guard let data = json.data(using: .utf8) else { return false }
        return atomicWrite(data, to: url)
    }

    func refreshKnownMtime() {
        if let a = try? FileManager.default.attributesOfItem(atPath: storeURL.path),
           let m = a[.modificationDate] as? Date {
            lastKnownMtime = m
            lastKnownSize = (a[.size] as? NSNumber)?.intValue ?? -1
        } else {
            lastKnownMtime = nil
            lastKnownSize = -1
        }
    }

    /// 坏文件改名留证（主文件、备份都走这一条）。
    private func quarantine(_ url: URL, prefix: String) -> String? {
        let dest = supportDir.appendingPathComponent("\(prefix)\(stampFmt.string(from: Date())).json")
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            NSLog("DeskTodo read: 已把读不出来的 \(url.lastPathComponent) 原样留成 \(dest.lastPathComponent)")
            return dest.lastPathComponent
        } catch {
            NSLog("DeskTodo read: \(url.lastPathComponent) 留证失败 \(error.localizedDescription)")
            return nil
        }
    }

    /* 读的三条规则，顺序不能换：
       1. 主文件能解析且形状对 → 用它，什么都不做；
       2. 读不出来 → 先把原文件原样挪到 data.corrupt-时间戳.json，再退回备份；
       3. 备份也坏 → 备份同样留证（data.bak.corrupt-*），返回 null 当新用户。
       同时把"发生过什么"记进 storeStatus，界面据此说话——
       用户不该在打开时看到一个空清单却不知道为什么。 */
    func readStore() -> String {
        var st = StoreStatus()
        st.at = Date()
        return withStoreLock { () -> String in
            let fm = FileManager.default

            if let s = safeRead(storeURL) {
                st.kind = .normal
                refreshKnownMtime()
                storeStatus = st
                return s
            }

            if fm.fileExists(atPath: storeURL.path) {
                if let kept = quarantine(storeURL, prefix: "data.corrupt-") { st.kept.append(kept) }
            }

            if let s = safeRead(storeBackupURL) {
                st.kind = .recovered
                NSLog("DeskTodo read: 已回退到 data.json.bak")
                if safeWrite(s, to: storeURL) {
                    NSLog("DeskTodo read: 已用备份重建 data.json")
                }
                refreshKnownMtime()
                storeStatus = st
                return s
            }

            // 备份在但读不出来：也要留证。以前这条路径悄悄把坏备份留给下一次覆盖，
            // 证据就没了（主文件坏会留证，备份坏不留，是不对称的）。
            if fm.fileExists(atPath: storeBackupURL.path) {
                if let kept = quarantine(storeBackupURL, prefix: "data.bak.corrupt-") { st.kept.append(kept) }
            }

            st.kind = (fm.fileExists(atPath: storeURL.path) || !st.kept.isEmpty) ? .corrupt : .fresh
            lastKnownMtime = nil
            lastKnownSize = -1
            storeStatus = st
            return "null"
        }
    }

    /// 备份轮转：main → .bak → .bak.1 → .bak.2（只留三代）。
    private func rotateBackups() {
        let fm = FileManager.default
        let b1 = storeBackupURL.appendingPathExtension("1")
        let b2 = storeBackupURL.appendingPathExtension("2")
        if fm.fileExists(atPath: b1.path) {
            try? fm.removeItem(at: b2)
            try? fm.moveItem(at: b1, to: b2)
        }
        if fm.fileExists(atPath: storeBackupURL.path) {
            try? fm.moveItem(at: storeBackupURL, to: b1)
        }
        if let d = try? Data(contentsOf: storeURL) {
            _ = atomicWrite(d, to: storeBackupURL)
        }
    }

    /// 每天第一笔保存留一份快照：坏了能回到"今天开始时的样子"。
    private func dailySnapshotIfNeeded() {
        let fm = FileManager.default
        guard let d = try? Data(contentsOf: storeURL) else { return }
        try? fm.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        let dest = snapshotDir.appendingPathComponent("data-\(dayFmt.string(from: Date())).json")
        guard !fm.fileExists(atPath: dest.path) else { return }
        _ = atomicWrite(d, to: dest)
        if let all = try? fm.contentsOfDirectory(atPath: snapshotDir.path) {
            let names = all.filter { $0.hasPrefix("data-") && $0.hasSuffix(".json") }.sorted()
            if names.count > 30 {
                for n in names.prefix(names.count - 30) {
                    try? fm.removeItem(at: snapshotDir.appendingPathComponent(n))
                }
            }
        }
    }

    /// 返回是否真的落盘，并区分"被拒"和"被别的实例改过"。
    @discardableResult
    func writeStore(_ json: String) -> StoreWrite {
        guard isValidStore(json) else {
            NSLog("DeskTodo save: 拒绝写入（形状不对的 JSON，\(json.count) 字节）")
            return .rejected
        }
        guard let data = json.data(using: .utf8) else { return .rejected }
        return withStoreLock { () -> StoreWrite in
            // 清空后的静默期：不让页面用内存里的旧状态把刚删掉的文件写回来
            if Date() < suppressSavesUntil {
                NSLog("DeskTodo save: 清空静默期内，忽略这次写盘")
                return .rejected
            }
            let fm = FileManager.default
            let exists = fm.fileExists(atPath: storeURL.path)

            // 冲突检测：磁盘上这份是不是我们上次读/写的那份？
            if exists, let a = try? fm.attributesOfItem(atPath: storeURL.path),
               let m = a[.modificationDate] as? Date,
               let sz = (a[.size] as? NSNumber)?.intValue {
                let drifted: Bool
                if let known = lastKnownMtime {
                    drifted = abs(m.timeIntervalSince(known)) > 0.5 || sz != lastKnownSize
                } else {
                    drifted = true      // 我们以为没有文件，磁盘上却有 → 一定是别人写的
                }
                if drifted {
                    let conflictURL = supportDir.appendingPathComponent(
                        "data.conflict-\(stampFmt.string(from: Date())).json")
                    try? fm.copyItem(at: storeURL, to: conflictURL)
                    let disk = safeRead(storeURL) ?? "null"
                    NSLog("DeskTodo save: 数据文件被另一个实例改过，拒绝覆盖（已留 \(conflictURL.lastPathComponent)）")
                    return .conflict(disk)
                }
            }

            if exists {
                rotateBackups()
                dailySnapshotIfNeeded()
            }

            if atomicWrite(data, to: storeURL) {
                refreshKnownMtime()
                return .ok
            }
            return .rejected
        }
    }

    /// 数据文件夹里都有什么（"打开文件夹"和诊断用）
    func storeFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: supportDir.path))?
            .filter { !$0.hasPrefix(".") }.sorted() ?? []
    }

    // MARK: - 导出

    /* 导出的标准只有一条：拿到这个 zip 的人，不装这个 app 也能回答
       "我这些年干了什么"。所以里面是原始 data.json + 一份人能读的说明，
       外加 focus.json（前台 App 计时也是你的数据），
       不用数据库、不用压缩包内嵌结构。 */
    func exportData(readme: String, completion: @escaping (Bool) -> Void) {
        // 排查用：`defaults write local.desktodo.app dbgExport -string /tmp/x.zip`
        // 跳过面板直接导，验证"导出来的包到底能不能读"。用完会自己删掉这个开关。
        if devMode, let p = UserDefaults.standard.string(forKey: "dbgExport"), !p.isEmpty {
            UserDefaults.standard.removeObject(forKey: "dbgExport")
            let ok = buildExport(to: URL(fileURLWithPath: p), readme: readme)
            NSLog("DeskTodo export(dbg): \(p) ok=\(ok)")
            completion(ok)
            return
        }

        let panel = NSSavePanel()
        panel.title = "导出全部数据"
        panel.prompt = "导出"
        panel.message = "一个 zip：原始 data.json + focus.json + 一份人能读的说明。\n解压不需要这个 app，用文本编辑器就能看。"
        panel.nameFieldStringValue = "浮窗待办-\(dayFmt.string(from: Date())).zip"
        panel.canCreateDirectories = true
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.zip] }

        NSApp.activate(ignoringOtherApps: true)
        suppressCount += 1
        cancelPendingAutoHide()
        panel.begin { [weak self] resp in
            guard let self = self else { return }
            let ok: Bool = {
                guard resp == .OK, let dest = panel.url else { return false }
                return self.buildExport(to: dest, readme: readme)
            }()
            completion(ok)
            self.window?.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.suppressCount = max(0, self.suppressCount - 1)
            }
        }
    }

    private func buildExport(to dest: URL, readme: String) -> Bool {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("desktodo-export-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: tmp)
        defer { try? fm.removeItem(at: tmp) }

        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

            // 原始数据优先原样拷贝（字节一致才算"原始"）；
            // 主文件不在就从备份补一份。两个都没有 → 直接失败，导出一个空包没有意义。
            let dst = tmp.appendingPathComponent("data.json")
            var wrote = false
            if fm.fileExists(atPath: storeURL.path) {
                try? fm.copyItem(at: storeURL, to: dst)
                wrote = fm.fileExists(atPath: dst.path)
            }
            if !wrote, let s = safeRead(storeBackupURL) {
                wrote = (try? s.write(to: dst, atomically: true, encoding: .utf8)) != nil
                NSLog("DeskTodo export: 主文件不可用，导出的是备份")
            }
            guard wrote else {
                NSLog("DeskTodo export: 主文件和备份都不可用，拒绝导出空包")
                return false
            }

            if fm.fileExists(atPath: focusURL.path), let f = try? Data(contentsOf: focusURL) {
                try? f.write(to: tmp.appendingPathComponent("focus.json"))
            }

            try readme.write(to: tmp.appendingPathComponent("读我.md"), atomically: true, encoding: .utf8)

            // 面板已经问过"要替换吗"，这里替换就是用户点过的那个意思
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            // --norsrc --noextattr：这两个文件没有需要保留的扩展属性，
            // 带上就会多出一堆 __MACOSX/._* 垃圾，解压的人一脸问号
            p.arguments = ["-c", "-k", "--norsrc", "--noextattr", tmp.path, dest.path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                NSLog("DeskTodo export: ditto 退出码 \(p.terminationStatus)")
                return false
            }
            NSLog("DeskTodo export ok: \(dest.path)")
            return true
        } catch {
            NSLog("DeskTodo export 失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 页面生成说明文本再回来导出（统计口径都在前端，原生侧不重算）
    func exportViaPage(completion: @escaping (Bool) -> Void) {
        guard let wv = webView else { completion(false); return }
        wv.evaluateJavaScript("window.__exportReadme ? window.__exportReadme() : ''") { [weak self] val, err in
            guard let self = self else { return }
            if err != nil { NSLog("DeskTodo export: 说明生成失败 \(String(describing: err))") }
            let md = (val as? String) ?? ""
            let text = md.isEmpty
                ? "（说明没生成出来，但 data.json 是完整可读的原始数据）\n"
                : md
            self.exportData(readme: text, completion: completion)
        }
    }

    // MARK: - 清空

    /* "删"必须真的是删：主文件、三代备份、留证文件、冲突副本、每日快照、
       前台计时记录，一起走。偏好里的位置/城市/天气缓存也有一起清——
       "清空全部数据"里的"全部"不能只覆盖清单。
       不进废纸篓、不留副本——留了就等于没删，那条承诺是假的。 */
    @discardableResult
    func wipeAllData() -> [String] {
        let fm = FileManager.default
        var targets: [URL] = [
            storeURL, storeBackupURL,
            storeBackupURL.appendingPathExtension("1"),
            storeBackupURL.appendingPathExtension("2"),
            focusURL, lockURL
        ]
        if let all = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
            // 留证/冲突/临时文件有好几代命名，少删一个就等于"删了但还留着"
            for u in all {
                let n = u.lastPathComponent
                if n.hasPrefix("data.corrupt-") || n.hasPrefix("data.bak.corrupt-")
                    || n.hasPrefix("data.backup-") || n.hasPrefix("data.conflict-")
                    || n.contains(".tmp-") {
                    targets.append(u)
                }
            }
        }
        if fm.fileExists(atPath: snapshotDir.path) { targets.append(snapshotDir) }

        var gone: [String] = []
        var failed: [String] = []
        for u in targets where fm.fileExists(atPath: u.path) {
            do {
                try fm.removeItem(at: u)
                gone.append(u.lastPathComponent)
            } catch {
                failed.append(u.lastPathComponent)
                NSLog("DeskTodo wipe: \(u.lastPathComponent) 删不掉 \(error.localizedDescription)")
            }
        }

        // 位置与天气缓存（经纬度、城市名、最后一次天气）也是用户数据
        if !isTestHome {
            for k in ["wxLat", "wxLon", "wxCity", "wxJSON", "wxAt", "wxAuto"] {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }

        storeStatus = StoreStatus()
        lastKnownMtime = nil
        lastKnownSize = -1
        NSLog("DeskTodo wipe: 已删 \(gone.joined(separator: ", "))"
              + (failed.isEmpty ? "" : "；失败 \(failed.joined(separator: ", "))"))
        return failed
    }

    // MARK: - 自检（构建闸门）

    /// `DESKTODO_TEST_HOME=$(mktemp -d) DeskTodo --selftest`
    /// 只跑数据层规则，不起界面；每条规则一个 PASS/FAIL，任一 FAIL 退出码 1。
    func runStorageSelfTest() -> Bool {
        guard isTestHome else {
            print("FAIL selftest 必须在 DESKTODO_TEST_HOME 指向的临时目录里跑")
            return false
        }
        var allOk = true
        func check(_ name: String, _ cond: Bool) {
            print("\(cond ? "PASS" : "FAIL") \(name)")
            if !cond { allOk = false }
        }

        let good1 = "{\"v\":2,\"nodes\":[]}"
        let good2 = "{\"v\":2,\"nodes\":[{\"id\":1,\"type\":\"task\",\"text\":\"a\"}]}"

        check("坏 JSON 被拒", !isValidStore("{\"nodes\":[{\"text\":\"半截"))
        check("null 被拒", !isValidStore("null"))
        check("空对象被拒（缺 v/nodes）", !isValidStore("{}"))
        check("数组被拒", !isValidStore("[]"))
        check("合法数据通过", isValidStore(good2))

        check("首写成功", writeStore(good1) == .ok)
        check("坏数据被拒且不改盘", writeStore("{\"v\":2,\"nodes\":\"x\"}") == .rejected)
        check("内容没被改", safeRead(storeURL) == good1)

        check("二写成功", writeStore(good2) == .ok)
        check("上一版在 .bak", safeRead(storeBackupURL) == good1)

        check("三写成功", writeStore(good1) == .ok)
        check("上一版在 .bak", safeRead(storeBackupURL) == good2)
        check("再上一版在 .bak.1", safeRead(storeBackupURL.appendingPathExtension("1")) == good1)
        check("每日快照存在", (try? FileManager.default.contentsOfDirectory(atPath: snapshotDir.path))?.isEmpty == false)

        // 主文件坏掉 → 留证 + 退备份
        try? Data("这不是 JSON".utf8).write(to: storeURL)
        let recovered = readStore()
        check("坏主文件时退回备份", recovered == good2 || recovered == good1)
        check("坏主文件已留证",
              ((try? FileManager.default.contentsOfDirectory(atPath: supportDir.path)) ?? [])
                .contains { $0.hasPrefix("data.corrupt-") })

        // 冲突：磁盘被别人改过 → 拒绝覆盖，磁盘内容保持别人的
        let external = "{\"v\":2,\"nodes\":[{\"id\":9,\"type\":\"task\",\"text\":\"other\"}]}"
        try? Data(external.utf8).write(to: storeURL)
        let outcome = writeStore(good2)
        var conflictOk = false
        if case .conflict(let disk) = outcome { conflictOk = (disk == external) }
        check("外部改动时报冲突", conflictOk)
        check("冲突时没覆盖别人的文件", (try? String(contentsOf: storeURL, encoding: .utf8)) == external)
        check("冲突副本已留证",
              ((try? FileManager.default.contentsOfDirectory(atPath: supportDir.path)) ?? [])
                .contains { $0.hasPrefix("data.conflict-") })

        // 清空：数据文件、备份、快照、focus 全部消失
        try? Data("{\"2026-01-01\":{\"com.example.app\":3}}".utf8).write(to: focusURL)
        let failed = wipeAllData()
        check("清空无残留失败", failed.isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: supportDir.path)) ?? []
        let dataLeft = left.filter { $0.hasPrefix("data") || $0 == "focus.json" || $0 == "snapshots" }
        check("清空后目录里没有数据文件", dataLeft.isEmpty)

        print(allOk ? "selftest ALL PASS" : "selftest FAILED")
        return allOk
    }
}
