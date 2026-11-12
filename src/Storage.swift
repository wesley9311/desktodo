import Cocoa
import WebKit
import UniformTypeIdentifiers
import Darwin

/* 全 app 的存储入口。真正的规则在 Store.swift；这里只做三件事：
   1. 把 Store 的结果翻译成界面能懂的状态；
   2. 导出（要弹面板，属于 UI）；
   3. 自检（构建闸门）。 */

// MARK: - 路径

/// 测试/自检用：设了 DESKTODO_TEST_HOME 就把数据目录指向临时位置。
let isTestHome: Bool = {
    !(ProcessInfo.processInfo.environment["DESKTODO_TEST_HOME"] ?? "").isEmpty
}()

let supportDir: URL = {
    if isTestHome, let h = ProcessInfo.processInfo.environment["DESKTODO_TEST_HOME"] {
        let d = URL(fileURLWithPath: (h as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("DeskTodo", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let d = base.appendingPathComponent("DeskTodo", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}()

/// 兼容别名：导出与夹具用它。真身由 Store 决定。
let storeURL = supportDir.appendingPathComponent("ledger.json")
let snapshotDir = supportDir.appendingPathComponent("snapshots", isDirectory: true)

let storeSchemaVersion = 2

/// 这一次读盘到底发生了什么。界面必须能看见，不能只有日志知道。
struct StoreStatus {
    enum Kind: String {
        case fresh
        case normal
        case recovered
        case corrupt
        case migrationPending
    }
    var kind: Kind = .normal
    var kept: [String] = []
    var at = Date()
}

/// 写盘结果。调用方必须分得清"写进去了"和"被拒/有冲突"。
enum StoreWrite: Equatable {
    case ok
    case rejected
    case conflict(String)
}

// MARK: - AppDelegate 包装

extension AppDelegate {

    func readStore() -> String {
        let r = store.load()
        storeStatus = StoreStatus(kind: r.kind, kept: r.kept, at: Date())
        storeReadOnlyReason = r.readOnlyReason
        if let reason = r.readOnlyReason {
            NSLog("DeskTodo store: read-only — \(reason)")
        }
        return r.json
    }

    @discardableResult
    func writeStore(_ json: String) -> StoreWrite {
        if Date() < suppressSavesUntil {
            NSLog("DeskTodo store: suppressed (wipe window)")
            return .rejected
        }
        switch store.save(json) {
        case .ok: return .ok
        case .rejected: return .rejected
        case .conflict(let disk): return .conflict(disk)
        }
    }

    func storeFiles() -> [String] { store.files() }

    /// 清空全部数据：账本、备份、快照、日志、前台计时、锁文件；偏好里的位置缓存一并清。
    @discardableResult
    func wipeAllData() -> [String] {
        let failed = store.wipe()
        if !isTestHome {
            for k in ["wxLat", "wxLon", "wxCity", "wxJSON", "wxAt", "wxAuto"] {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
        storeStatus = StoreStatus()
        storeReadOnlyReason = nil
        return failed
    }

    // MARK: 导出

    func exportData(readme: String, completion: @escaping (Bool) -> Void) {
        if devMode, let p = UserDefaults.standard.string(forKey: "dbgExport"), !p.isEmpty {
            UserDefaults.standard.removeObject(forKey: "dbgExport")
            let ok = buildExport(to: URL(fileURLWithPath: p), readme: readme)
            NSLog("DeskTodo export(dbg): \(p) ok=\(ok)")
            completion(ok)
            return
        }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        let panel = NSSavePanel()
        panel.title = "导出账本"
        panel.prompt = "导出"
        panel.message = "账本原样 + 一份 meta（导出时间、版本、构建号、schemaVersion）。"
        panel.nameFieldStringValue = "ledger-\(appVersion)-\(f.string(from: Date())).json"
        panel.canCreateDirectories = true
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.json] }

        NSApp.activate(ignoringOtherApps: true)
        suppressCount += 1
        cancelPendingAutoHide()
        panel.begin { [weak self] resp in
            guard let self = self else { return }
            let ok: Bool = {
                guard resp == .OK, let dest = panel.url else { return false }
                return self.buildExport(to: dest, readme: readme)
            }()
            // buildExport 内部已经备份一次；这里不再备（P2-7：一次导出只多一份备份）
            completion(ok)
            self.window?.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.suppressCount = max(0, self.suppressCount - 1)
            }
        }
    }

    var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// 账本 + meta 段。自检与导出面板共用。
    func exportPayload() -> Data? {
        var obj: [String: Any] = [:]
        var source = "ledger"
        let raw = store.load().json
        if let d = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            obj = parsed
        } else if let fallback = store.newestBackupJSON() {
            source = "backup"
            if let d = fallback.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                obj = parsed
            }
        } else if let quarantined = store.newestQuarantineJSON() {
            // P2-5：坏账本且没有可用备份时，把留证的原始字节一起带走，避免"导出得到空账本"
            source = "quarantine"
            obj = ["v": storeSchemaVersion, "nodes": [], "daily": [:], "quarantineRaw": quarantined]
            NSLog("DeskTodo export: quarantine raw included")
        } else {
            // 新用户/空账本：导出一个合法的空账本，而不是失败
            source = "fresh"
            obj = ["v": storeSchemaVersion, "nodes": [], "daily": [:]]
            NSLog("DeskTodo export: empty ledger")
        }
        // P2-6：meta.schemaVersion 用账本真实 v（含高版本只读账本），不再写死编译期常量
        let ledgerSchema = (obj["v"] as? NSNumber)?.intValue ?? storeSchemaVersion
        obj["meta"] = [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": appVersion,
            "buildNumber": (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0",
            "schemaVersion": ledgerSchema,
            "source": source
        ]
        return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])
    }

    /// P1-4：旧版兼容导出。把当前账本写成旧版认识的文件名（见 LegacyPaths；不含 meta，v 不超过当前支持版本），
    /// 供"回滚到上一版"时先落一份旧版可读的数据。
    func legacyExportPayload() -> Data? {
        let raw = store.load().json
        guard let d = raw.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        obj.removeValue(forKey: "meta")
        let v = (obj["v"] as? NSNumber)?.intValue ?? storeSchemaVersion
        obj["v"] = min(v, storeSchemaVersion)
        return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])
    }

    func buildLegacyExport(to dest: URL) -> Bool {
        guard let data = legacyExportPayload() else {
            NSLog("DeskTodo legacy export: no payload")
            return false
        }
        do {
            try data.write(to: dest, options: .atomic)
            NSLog("DeskTodo legacy export ok")
            return true
        } catch {
            NSLog("DeskTodo legacy export failed")
            return false
        }
    }

    /// 写盘 + 导出成功后触发一次备份。
    private func buildExport(to dest: URL, readme: String) -> Bool {
        guard let data = exportPayload() else {
            NSLog("DeskTodo export: no payload")
            return false
        }
        do {
            try data.write(to: dest, options: .atomic)
            store.backupNow("export")
            NSLog("DeskTodo export ok")
            return true
        } catch {
            NSLog("DeskTodo export failed")
            return false
        }
    }

    func backupReviewText() -> String {
        store.review().lines.joined(separator: "\n")
    }

    /// 诊断信息：只有版本、构建、系统、架构、备份审阅结果和最近 50 行日志。
    /// 用户名、邮箱、临时目录在代码里脱敏；不含任何任务内容。
    func diagnosticText() -> String {
        var arch = "unknown"
        var uts = utsname()
        if uname(&uts) == 0 {
            arch = withUnsafePointer(to: &uts.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
            }
        }
        var text = "DeskTodo 诊断\n"
        text += "版本：\(appVersion)（构建 \((Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0")）\n"
        text += "系统：\(ProcessInfo.processInfo.operatingSystemVersionString)  架构：\(arch)\n"
        let ledger = store.load().json
        let n = (try? JSONSerialization.jsonObject(with: Data(ledger.utf8))) as? [String: Any]
        let count = (n?["nodes"] as? [Any])?.count ?? 0
        text += "账本：\(count) 条 · 备份 \(store.backupFileList().count) 份 · 快照 \(snapshotCount())\n"
        text += "备份审阅：\n\(backupReviewText())\n"
        text += "最近日志（50 行）：\n"
        text += store.logTail(50).joined(separator: "\n")
        return sanitize(text)
    }

    private func sanitize(_ s: String) -> String {
        var t = s
        // 用运行时拼接，避免编译进二进制后 strings 里出现真实的用户名路径样式
        let userPrefix = ["/", "Users", "/"].joined()
        let userPattern = userPrefix + "[^/\\s]+"
        let userReplacement = ["/", "Users", "/", "<user>"].joined()
        t = t.replacingOccurrences(of: userPattern, with: userReplacement, options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#, with: "<email>", options: .regularExpression)
        let tmpPattern = ["/", "var", "/", "folders", "/", "[^\\s]+"].joined()
        t = t.replacingOccurrences(of: tmpPattern, with: "<tmp>", options: .regularExpression)
        return t
    }

    func snapshotCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: snapshotDir.path)) ?? []).filter { $0.hasSuffix(".json") }.count
    }

    func exportViaPage(completion: @escaping (Bool) -> Void) {
        guard let wv = webView else { completion(false); return }
        wv.evaluateJavaScript("window.__exportReadme ? window.__exportReadme() : ''") { [weak self] val, _ in
            guard let self = self else { return }
            let text = (val as? String) ?? ""
            self.exportData(readme: text, completion: completion)
        }
    }

    // MARK: 自检（构建闸门）

    func runStorageSelfTest() -> Bool {
        guard isTestHome else {
            print("FAIL selftest 需要 DESKTODO_TEST_HOME")
            return false
        }
        var allOk = true
        func check(_ name: String, _ cond: Bool) {
            print("\(cond ? "PASS" : "FAIL") \(name)")
            if !cond { allOk = false }
        }

        let good1 = "{\"v\":2,\"nodes\":[]}"
        let good2 = "{\"v\":2,\"nodes\":[{\"id\":1,\"type\":\"task\",\"text\":\"a\"}]}"

        check("坏 JSON 被拒", !store.isValid("{\"nodes\":[{\"text\":\"半截"))
        check("null 被拒", !store.isValid("null"))
        check("空对象被拒", !store.isValid("{}"))
        check("数组被拒", !store.isValid("[]"))
        check("合法数据通过", store.isValid(good2))

        check("首写成功", writeStore(good1) == .ok)
        check("坏数据被拒且不改盘", writeStore("{\"v\":2,\"nodes\":\"x\"}") == .rejected)
        check("内容没被改", readStore().contains("\"nodes\":[]"))
        check("二写成功", writeStore(good2) == .ok)
        check("备份存在", !store.backupFiles().isEmpty)
        check("每日快照存在", (try? FileManager.default.contentsOfDirectory(atPath: snapshotDir.path))?.isEmpty == false)

        // 坏主文件 → 留证 + 退备份
        try? Data("这不是 JSON".utf8).write(to: storeURL)
        let recovered = readStore()
        check("坏主文件时退回备份", recovered.contains("\"nodes\""))
        check("坏文件已留证", (try? FileManager.default.contentsOfDirectory(atPath: store.backupsURL.path))?.isEmpty == false)

        // 冲突：磁盘被别人改过
        let external = "{\"v\":2,\"nodes\":[{\"id\":9,\"type\":\"task\",\"text\":\"other\"}]}"
        try? Data(external.utf8).write(to: storeURL)
        var conflictOk = false
        if case .conflict(let disk) = writeStore(good2) { conflictOk = disk == external }
        check("外部改动时报冲突", conflictOk)
        check("冲突时没覆盖别人的文件", (try? String(contentsOf: storeURL, encoding: .utf8)) == external)

        // 未知字段宽容
        try? Data(good2.utf8).write(to: storeURL)
        _ = readStore()
        check("未知字段容忍", writeStore("{\"v\":2,\"nodes\":[],\"extra\":{\"x\":1}}") == .ok)
        check("未知字段被原样保留", readStore().contains("\"extra\""))

        // 备份轮转上限
        for _ in 0..<7 { _ = writeStore(good2) }
        check("备份最多 5 份", store.backupFiles().count <= 5)

        // 权限 600
        let attrs = try? FileManager.default.attributesOfItem(atPath: storeURL.path)
        let perm = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        check("账本权限 600", perm == 0o600)

        // schemaVersion 更高 → 只读、拒写、文件不变
        let future = "{\"v\":3,\"nodes\":[{\"id\":1,\"type\":\"task\",\"text\":\"future\"}]}"
        try? Data(future.utf8).write(to: storeURL)
        let ro = store.load()
        check("高版本数据判为只读", ro.readOnlyReason != nil)
        check("高版本拒写", store.save(good2) == .rejected)
        check("高版本文件未被改", (try? String(contentsOf: storeURL, encoding: .utf8)) == future)
        try? Data(good2.utf8).write(to: storeURL)
        _ = store.load()

        // 迁移：旧文件名 → 新文件名（复制，保留原件）
        let mig = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dt-mig-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: mig)
        try? FileManager.default.createDirectory(at: mig, withIntermediateDirectories: true)
        let legacyName = LegacyPaths.ledgerFileName
        let legacyFile = mig.appendingPathComponent(legacyName)
        try? Data(good2.utf8).write(to: legacyFile)
        let migrated = Store(dataDirectory: mig)
        check("迁移生成新账本", FileManager.default.fileExists(atPath: migrated.ledgerURL.path))
        check("迁移保留原文件", FileManager.default.fileExists(atPath: legacyFile.path))
        try? FileManager.default.removeItem(at: mig)

        // 导出：可被自身解析，条数一致
        let payload = exportPayload()
        let parsed = payload.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let exportNodes = (parsed?["nodes"] as? [Any])?.count ?? -1
        let meta = parsed?["meta"] as? [String: Any]
        check("导出可被本身解析", parsed != nil)
        check("导出条数与原数据一致", exportNodes == 1)
        check("导出带 meta", meta?["appVersion"] != nil && meta?["schemaVersion"] != nil)

        // 备份审阅 7 项
        let review = store.review()
        check("审阅是 7 项", review.lines.count == 7)
        check("审阅全部通过", review.passed)

        // 诊断信息：无任务内容、无用户名/邮箱/临时目录
        try? Data("{\"v\":2,\"nodes\":[{\"id\":1,\"type\":\"task\",\"text\":\"待办XYZ\"}]}".utf8).write(to: storeURL)
        _ = store.load()
        try? FileManager.default.createDirectory(at: store.logsURL, withIntermediateDirectories: true)
        let fakePath = ["/", "Users", "/", "alice/work", " a@b.com /var/folders/zz/T/x\n"].joined()
        try? Data(fakePath.utf8).write(to: store.logURL)
        let diag = diagnosticText()
        check("诊断不含任务内容", !diag.contains("待办") && !diag.contains("title") && !diag.contains("task"))
        let leakPattern = ["/", "Users", "/", "[a-z]"].joined()
        let leak = diag.range(of: leakPattern, options: .regularExpression) != nil
        check("诊断已脱敏用户名", !leak && diag.contains("<user>"))
        check("诊断已脱敏邮箱", !diag.contains("a@b.com") && diag.contains("<email>"))
        check("诊断已脱敏临时目录", !diag.contains("/var/folders/"))

        // 恢复：先备份当前，再写回
        store.backupNow("test")
        let target = store.backupFileList().last.map { store.backupsURL.appendingPathComponent($0) }
        var restored = false
        if let u = target {
            try? Data("{\"v\":2,\"nodes\":[]}".utf8).write(to: storeURL)
            _ = store.load()
            let r = store.restore(from: u)
            restored = r.ok && r.after >= 0
        }
        check("恢复备份可用", restored)

        // 篡改拦截：改一份备份，审阅第 5 项应拦下
        if let u = store.backupFileList().last.map({ store.backupsURL.appendingPathComponent($0) }),
           let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile()
            h.write(Data("x".utf8))
            try? h.close()
            let tampered = store.review()
            check("篡改被第 5 项拦下", !tampered.passed && tampered.lines.contains { $0.contains("tampered") })
        } else {
            check("篡改被第 5 项拦下", false)
        }

        // ── P1-1：只读账本拒绝恢复 ──
        let futureV3 = "{\"v\":3,\"nodes\":[{\"id\":1,\"type\":\"task\",\"text\":\"future\"}]}"
        try? Data(futureV3.utf8).write(to: storeURL)
        _ = store.load()
        store.backupNow("ro-test")
        let roTarget = store.backupFileList().last.map { store.backupsURL.appendingPathComponent($0) }
        var roRestoreOk = true
        if let u = roTarget { roRestoreOk = store.restore(from: u).ok }
        check("只读账本拒绝恢复", roRestoreOk == false)
        check("拒绝后只读账本未被覆盖", (try? String(contentsOf: storeURL, encoding: .utf8)) == futureV3)

        // ── P2-4：从低版本备份恢复后只读状态应清除 ──
        try? Data(good2.utf8).write(to: storeURL)
        _ = store.load()
        store.backupNow("v2-ro")
        try? Data(futureV3.utf8).write(to: storeURL)
        _ = store.load()                                   // readOnly = true
        try? Data("坏账本".utf8).write(to: storeURL)
        let recoveredRO = store.load()                     // 从 v2 备份恢复
        check("从低版本备份恢复后只读状态清除", recoveredRO.readOnlyReason == nil && store.save(good2) == .ok)

        // ── P1-2：恢复前备份失败 → 中止，不覆盖 ──
        try? Data(good2.utf8).write(to: storeURL)
        _ = store.load()
        store.backupNow("pre")
        let preTarget = store.backupFileList().last.map { store.backupsURL.appendingPathComponent($0) }
        var abortedRestore = false
        if let u = preTarget {
            _ = chmod(store.backupsURL.path, 0o500)
            let r = store.restore(from: u)
            _ = chmod(store.backupsURL.path, 0o700)
            abortedRestore = (r.ok == false)
        }
        check("恢复前备份失败时中止恢复", abortedRestore)
        check("中止后主账本未被覆盖", (try? String(contentsOf: storeURL, encoding: .utf8)) == good2)

        // ── P2-1：保存失败不删旧备份 ──
        let nBeforeFail = store.backupFileList().count
        _ = chmod(supportDir.path, 0o500)
        let failedSave = writeStore(good2)
        _ = chmod(supportDir.path, 0o700)
        check("保存失败时备份历史不变", failedSave == .rejected && store.backupFileList().count == nBeforeFail)

        // ── P2-3：同大小、同 mtime 的外部改动也必须报冲突 ──
        try? Data(good2.utf8).write(to: storeURL)
        _ = store.load()
        let mt0 = (try? FileManager.default.attributesOfItem(atPath: storeURL.path))?[.modificationDate] as? Date
        let sameLen = good2.replacingOccurrences(of: "\"a\"", with: "\"b\"")
        try? Data(sameLen.utf8).write(to: storeURL)
        if let mt0 { try? FileManager.default.setAttributes([.modificationDate: mt0], ofItemAtPath: storeURL.path) }
        var sameSizeConflict = false
        if case .conflict = writeStore(good2) { sameSizeConflict = true }
        check("同大小同 mtime 的外部改动也报冲突", sameSizeConflict)
        try? Data(good2.utf8).write(to: storeURL)
        _ = store.load()

        // ── P2-2：审阅只读，不新增/删除备份、不留探针 ──
        let filesBeforeReview = store.backupFileList().count
        let rv = store.review()
        check("审阅 7 项", rv.lines.count == 7)
        check("审阅不新增备份", store.backupFileList().count == filesBeforeReview)
        check("审阅不留探针文件", !FileManager.default.fileExists(atPath: supportDir.appendingPathComponent(".write-probe").path))

        // ── P2-7：一次导出只多一份备份 ──
        for f in store.backupFileList() { try? FileManager.default.removeItem(at: store.backupsURL.appendingPathComponent(f)) }
        store.backupNow("zero")
        let nExp0 = store.backupFileList().count
        let expDest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dt-exp-\(getpid()).json")
        let expOK = buildExport(to: expDest, readme: "x")
        let nExp1 = store.backupFileList().count
        try? FileManager.default.removeItem(at: expDest)
        check("导出成功", expOK)
        check("一次导出只多一份备份", nExp1 - nExp0 == 1)

        // ── P1-4：旧版兼容导出（回滚用）──
        let legacyDest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dt-legacy-\(getpid()).json")
        let legacyOK = buildLegacyExport(to: legacyDest)
        let legacyData: Data? = try? Data(contentsOf: legacyDest)
        let legacyObj = legacyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let legacyNodes = (legacyObj?["nodes"] as? [Any])?.count ?? -1
        try? FileManager.default.removeItem(at: legacyDest)
        check("旧版兼容导出成功", legacyOK)
        check("旧版兼容导出无 meta 且条数一致", legacyObj != nil && legacyObj?.index(forKey: "meta") == nil && legacyNodes == 1)

        // ── P2-5：坏账本且无备份时，导出要带回留证的原始字节 ──
        for f in store.backupFileList() { try? FileManager.default.removeItem(at: store.backupsURL.appendingPathComponent(f)) }
        try? Data("这不是 JSON".utf8).write(to: storeURL)
        _ = readStore()
        let qParsed = exportPayload().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check("坏账本无备份时导出带原始字节", ((qParsed?["quarantineRaw"] as? String)?.isEmpty == false))

        // ── P2-6：高版本账本导出的 meta.schemaVersion 用真实 v ──
        try? Data(futureV3.utf8).write(to: storeURL)
        _ = store.load()
        let v3Parsed = exportPayload().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let v3Meta = v3Parsed?["meta"] as? [String: Any]
        check("v3 账本导出 meta.schemaVersion = 3", (v3Meta?["schemaVersion"] as? NSNumber)?.intValue == 3)
        try? Data(good2.utf8).write(to: storeURL)
        _ = store.load()

        // ── P1-3：迁移失败 fail-closed；旧文件修好后下次启动重试 ──
        let migFail = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dt-migfail-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: migFail)
        try? FileManager.default.createDirectory(at: migFail, withIntermediateDirectories: true)
        let unreadable = migFail.appendingPathComponent(LegacyPaths.ledgerFileName)
        try? Data(good2.utf8).write(to: unreadable)
        _ = chmod(unreadable.path, 0o000)
        let pendingStore = Store(dataDirectory: migFail)
        check("迁移失败时不创建新账本", !FileManager.default.fileExists(atPath: pendingStore.ledgerURL.path))
        check("迁移失败时状态为待迁移", pendingStore.load().kind == .migrationPending)
        check("迁移失败时拒绝写入", pendingStore.save(good2) == .rejected)
        _ = chmod(unreadable.path, 0o600)
        let retryStore = Store(dataDirectory: migFail)
        check("旧文件可读后下次启动迁移成功", FileManager.default.fileExists(atPath: retryStore.ledgerURL.path))
        try? FileManager.default.removeItem(at: migFail)

        // 清空
        try? Data("{\"2026-01-01\":{}}".utf8).write(to: store.focusURL)
        let failed = wipeAllData()
        check("清空无残留失败", failed.isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: supportDir.path)) ?? []
        // 空目录不算数据；目录里还有文件才算残留
        let dataLeft = left.filter { name -> Bool in
            if name == "ledger.json" || name == "focus.json" { return true }
            if name == "snapshots" || name == "backups" || name == "logs" {
                let c = (try? FileManager.default.contentsOfDirectory(atPath: supportDir.appendingPathComponent(name).path)) ?? []
                return !c.isEmpty
            }
            return name.hasPrefix("ledger") || name.hasPrefix("data")
        }
        check("清空后没有数据文件", dataLeft.isEmpty)

        print(allOk ? "selftest ALL PASS" : "selftest FAILED")
        return allOk
    }
}
