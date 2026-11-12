import Cocoa
import CryptoKit

/* 存储层：唯一知道数据放哪、怎么写、怎么备份、怎么删的地方。
   四个约束：
     1. 写入走同一条串行队列；
     2. 落盘用「临时文件 → fsync → rename → fsync 目录」，权限 600；
     3. 读取方必须忽略未知字段（只验证 v 与 nodes/tasks 的形状）；
     4. schemaVersion > 2 时只读、拒绝写入，并给出可读原因。 */

struct StoreLoad {
    var kind: StoreStatus.Kind = .normal
    var kept: [String] = []
    var json: String = "null"
    var readOnlyReason: String? = nil
}

enum StoreSave: Equatable {
    case ok
    case rejected
    case conflict(String)
}

final class Store {
    let dir: URL
    let ledgerURL: URL
    let backupsURL: URL
    let snapshotsURL: URL
    let logsURL: URL
    let logURL: URL
    let focusURL: URL
    let lockURL: URL

    private let queue = DispatchQueue(label: "local.desktodo.store")
    private var knownMtime: Date?
    private var knownSize: Int = -1
    private var knownHash: String?
    private var readOnly = false
    /// 旧账本迁移失败时置位：fail-closed，禁止写新账本，每次启动重试。
    private(set) var migrationPending = false
    private(set) var migrationReason: String?
    private var usedBackupNames = Set<String>()
    private let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"

    private let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f
    }()
    private let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    init(dataDirectory: URL) {
        dir = dataDirectory
        ledgerURL = dir.appendingPathComponent("ledger.json")
        backupsURL = dir.appendingPathComponent("backups", isDirectory: true)
        snapshotsURL = dir.appendingPathComponent("snapshots", isDirectory: true)
        logsURL = dir.appendingPathComponent("logs", isDirectory: true)
        logURL = logsURL.appendingPathComponent("desktodo.log")
        focusURL = dir.appendingPathComponent("focus.json")
        lockURL = dir.appendingPathComponent(".desk.lock")
        prepare()
        migrate()
    }

    // MARK: - 准备与迁移

    private func prepare() {
        let fm = FileManager.default
        for d in [dir, backupsURL, snapshotsURL, logsURL] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    /// 三条硬规则：复制不删原文件；升级后首次写入前备份一次；解析失败只读。
    private func migrate() {
        let fm = FileManager.default

        // 1) 旧账本 → ledger.json（先读入内存并校验，成功才落盘；失败 fail-closed）
        let legacyLedger = dir.appendingPathComponent(LegacyPaths.ledgerFileName)
        if !fm.fileExists(atPath: ledgerURL.path), fm.fileExists(atPath: legacyLedger.path) {
            if let data = try? Data(contentsOf: legacyLedger),
               let s = String(data: data, encoding: .utf8), isValid(s),
               atomicWrite(data, to: ledgerURL) {
                NSLog("DeskTodo store: migrated from legacy#1")
            } else {
                // 旧数据读不到/写不进：不创建空账本，禁止后续写入，下次启动重试。
                migrationPending = true
                migrationReason = "旧数据还没导入（读不到旧文件或写不进新账本）"
                NSLog("DeskTodo store: migration pending (legacy#1)")
            }
        }

        // 2) 旧备份 → backups/ledger.bak.<时间>.json（复制，保留原件）
        for suffix in ["", ".1", ".2"] {
            let src = dir.appendingPathComponent(LegacyPaths.backupPrefix + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let mtime = (try? fm.attributesOfItem(atPath: src.path))?[.modificationDate] as? Date ?? Date()
            let dst = backupsURL.appendingPathComponent("ledger.bak.\(stampFmt.string(from: mtime)).json")
            let dst2 = fm.fileExists(atPath: dst.path)
                ? backupsURL.appendingPathComponent("ledger.bak.\(stampFmt.string(from: mtime))-2.json") : dst
            if !fm.fileExists(atPath: dst2.path), (try? fm.copyItem(at: src, to: dst2)) != nil {
                NSLog("DeskTodo store: migrated from legacy#2")
            }
        }

        // 3) 旧日志 → logs/desktodo.log（复制，保留原件）
        if !isTestHome, !fm.fileExists(atPath: logURL.path) {
            let oldDir = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent(LegacyPaths.oldLogFolder, isDirectory: true)
            let oldLog = oldDir.appendingPathComponent("desktodo.log")
            if fm.fileExists(atPath: oldLog.path), (try? fm.copyItem(at: oldLog, to: logURL)) != nil {
                _ = chmod(logURL.path, 0o600)
                NSLog("DeskTodo store: migrated from legacy#5")
            }
        }
    }

    // MARK: - 校验

    func isValid(_ s: String) -> Bool {
        guard let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        guard let v = obj["v"] as? NSNumber, String(cString: v.objCType) != "c" else { return false }
        if let nodes = obj["nodes"] { return nodes is [Any] }
        if let tasks = obj["tasks"] { return tasks is [Any] }
        return false
    }

    private func schemaVersion(_ s: String) -> Int? {
        guard let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let v = obj["v"] as? NSNumber else { return nil }
        return v.intValue
    }

    // MARK: - 读

    func load() -> StoreLoad {
        var out = StoreLoad()
        queue.sync {
            let fm = FileManager.default
            // 迁移未完成：不读、不写、不迁移，界面明确告知（fail-closed）。
            if migrationPending, !fm.fileExists(atPath: ledgerURL.path) {
                out.kind = .migrationPending
                out.readOnlyReason = migrationReason
                knownMtime = nil
                knownSize = -1
                knownHash = nil
                NSLog("DeskTodo store: migration pending, write refused")
                return
            }
            if let s = safeRead(ledgerURL) {
                if let v = schemaVersion(s), v > storeSchemaVersion {
                    out.kind = .normal
                    out.json = s
                    readOnly = true
                    out.readOnlyReason = "账本 schemaVersion=\(v)，高于当前应用支持的 \(storeSchemaVersion)"
                    refreshKnown()
                    NSLog("DeskTodo store: read-only (schema#1)")
                    return
                }
                readOnly = false
                out.kind = .normal
                out.json = s
                refreshKnown()
                return
            }

            if fm.fileExists(atPath: ledgerURL.path) {
                if let kept = quarantine(ledgerURL) { out.kept.append(kept) }
            }

            if let bak = newestBackup(), let s = safeRead(bak) {
                out.kind = .recovered
                out.json = s
                if atomicWrite(Data(s.utf8), to: ledgerURL) {
                    NSLog("DeskTodo store: recovered from backup")
                }
                // P2-4：恢复出的数据版本才是当前真实版本，只读状态按它重算
                readOnly = (schemaVersion(s) ?? storeSchemaVersion) > storeSchemaVersion
                refreshKnown()
                return
            }

            out.kind = (fm.fileExists(atPath: ledgerURL.path) || !out.kept.isEmpty) ? .corrupt : .fresh
            knownMtime = nil
            knownSize = -1
            knownHash = nil
        }
        return out
    }

    private func safeRead(_ url: URL) -> String? {
        guard let s = try? String(contentsOf: url, encoding: .utf8), !s.isEmpty, isValid(s) else { return nil }
        return s
    }

    private func quarantine(_ url: URL) -> String? {
        let dst = backupsURL.appendingPathComponent("ledger.corrupt-\(stampFmt.string(from: Date())).json")
        do {
            try FileManager.default.moveItem(at: url, to: dst)
            NSLog("DeskTodo store: bad file kept as a quarantined copy")
            return dst.lastPathComponent
        } catch {
            NSLog("DeskTodo store: quarantine failed")
            return nil
        }
    }

    // MARK: - 写

    func save(_ json: String) -> StoreSave {
        guard isValid(json) else {
            NSLog("DeskTodo store: rejected (shape)")
            return .rejected
        }
        guard let data = json.data(using: .utf8) else { return .rejected }
        var result: StoreSave = .rejected
        queue.sync {
            if readOnly {
                NSLog("DeskTodo store: rejected (read-only)")
                result = .rejected
                return
            }
            if migrationPending {
                NSLog("DeskTodo store: rejected (migration pending)")
                result = .rejected
                return
            }
            if let v = schemaVersion(json), v > storeSchemaVersion {
                NSLog("DeskTodo store: rejected (schema#1)")
                result = .rejected
                return
            }
            let fm = FileManager.default
            let exists = fm.fileExists(atPath: ledgerURL.path)
            // P2-3：用内容 hash 判外部改动（0.5s 内、字节数相同也逃不掉）
            if exists, let diskData = try? Data(contentsOf: ledgerURL) {
                let diskHash = sha256Hex(diskData)
                let drifted: Bool
                if let known = knownHash { drifted = (diskHash != known) } else { drifted = true }
                if drifted {
                    let copy = backupsURL.appendingPathComponent("ledger.conflict-\(stampFmt.string(from: Date())).json")
                    try? fm.copyItem(at: ledgerURL, to: copy)
                    let disk = safeRead(ledgerURL) ?? "null"
                    NSLog("DeskTodo store: conflict, keep disk version")
                    result = .conflict(disk)
                    return
                }
            }

            backupBeforeWriteIfNeeded(exists: exists)
            // P2-1：先把"写之前的内容"备份成新文件（不删旧备份），主文件写成功后才轮转。
            // 主文件写失败时，备份历史保持原样，不会出现"新备份已写、最旧一份被删、保存却失败"。
            var pendingBackup: URL?
            if exists, let cur = try? Data(contentsOf: ledgerURL) {
                let dst = nextBackupURL()
                if atomicWrite(cur, to: dst) { pendingBackup = dst }
            }
            if atomicWrite(data, to: ledgerURL) {
                if exists {
                    trimBackups(keep: 5)
                    writeDailySnapshotIfNeeded()
                }
                refreshKnown()
                refreshIndexLocked()
                result = .ok
            } else {
                // 主文件没写成：把刚写的临时备份撤掉，备份历史保持原样（P2-1）
                if let pb = pendingBackup { try? FileManager.default.removeItem(at: pb) }
                NSLog("DeskTodo store: write failed, backups untouched")
                result = .rejected
            }
        }
        return result
    }

    /// 升级后第一次写入前备份一次；同一次升级只做一次。
    private func backupBeforeWriteIfNeeded(exists: Bool) {
        guard exists else { return }
        if isTestHome { return }
        let key = "backupOnceVersion"
        if UserDefaults.standard.string(forKey: key) == version { return }
        if let data = try? Data(contentsOf: ledgerURL) {
            let dst = nextBackupURL()
            if atomicWrite(data, to: dst) {
                UserDefaults.standard.set(version, forKey: key)
                NSLog("DeskTodo store: backup before first write")
            }
        }
    }

    /// 把备份收敛到 keep 份，只删最旧。调用方保证主文件已写成功（P2-1）。
    private func trimBackups(keep: Int) {
        let names = backupFileList()
        guard names.count > keep else { return }
        for n in names.prefix(names.count - keep) {
            try? FileManager.default.removeItem(at: backupsURL.appendingPathComponent(n))
        }
    }

    private func writeDailySnapshotIfNeeded() {
        guard let data = try? Data(contentsOf: ledgerURL) else { return }
        let dst = snapshotsURL.appendingPathComponent("ledger-\(dayFmt.string(from: Date())).json")
        guard !FileManager.default.fileExists(atPath: dst.path) else { return }
        _ = atomicWrite(data, to: dst)
        pruneSnapshots(keep: 5)
    }

    private func pruneSnapshots(keep: Int) {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(atPath: snapshotsURL.path) else { return }
        let names = all.filter { $0.hasSuffix(".json") }.sorted()
        if names.count > keep {
            for n in names.prefix(names.count - keep) {
                try? fm.removeItem(at: snapshotsURL.appendingPathComponent(n))
            }
        }
    }

    private func newestBackup() -> URL? { backupURLs().last }

    func backupFiles() -> [URL] {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(atPath: backupsURL.path) else { return [] }
        return all.filter { $0.hasPrefix("ledger.bak.") && $0.hasSuffix(".json") }
            .sorted().map { backupsURL.appendingPathComponent($0) }
    }

    func newestBackupJSON() -> String? {
        guard let url = newestBackup() else { return nil }
        return safeRead(url)
    }

    /// 最新一份坏文件留证（可能不是合法 JSON，只读原始字节；P2-5）。
    func newestQuarantineJSON() -> String? {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(atPath: backupsURL.path) else { return nil }
        let names = all.filter { $0.hasPrefix("ledger.corrupt-") && $0.hasSuffix(".json") }.sorted()
        guard let last = names.last else { return nil }
        return try? String(contentsOf: backupsURL.appendingPathComponent(last), encoding: .utf8)
    }

    /// 导出成功后触发一次备份（三个触发点之一）。
    func backupNow(_ reason: String) {
        queue.sync {
            guard let data = try? Data(contentsOf: ledgerURL) else { return }
            let dst = nextBackupURL()
            _ = atomicWrite(data, to: dst)
            trimBackups(keep: 5)
            refreshIndexLocked()
            NSLog("DeskTodo store: backup (\(reason))")
        }
    }


    // MARK: - 备份索引与审阅

    private var indexURL: URL { backupsURL.appendingPathComponent("index.json") }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func entryCount(of json: String) -> Int {
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return -1 }
        if let n = o["nodes"] as? [Any] { return n.count }
        if let t = o["tasks"] as? [Any] { return t.count }
        return 0
    }

    private func fileDate(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? Date()
    }

    func loadIndex() -> [BackupEntry] {
        guard let d = try? Data(contentsOf: indexURL),
              let idx = try? JSONDecoder().decode([String: [BackupEntry]].self, from: d),
              let list = idx["entries"] else { return [] }
        return list
    }

    private func saveIndex(_ list: [BackupEntry]) {
        guard let data = try? JSONEncoder().encode(["entries": list]) else { return }
        _ = atomicWrite(data, to: indexURL)
    }

    /// 索引只记 hash、字节数、条数、时间；不记任何内容。
    func refreshIndex() {
        queue.sync { refreshIndexLocked() }
    }

    private func refreshIndexLocked() {
        do {
            let files = backupFileList()
            let old = Dictionary(uniqueKeysWithValues: loadIndex().map { ($0.file, $0) })
            var list: [BackupEntry] = []
            for f in files {
                let u = backupsURL.appendingPathComponent(f)
                guard let d = try? Data(contentsOf: u) else { continue }
                let s = String(data: d, encoding: .utf8) ?? ""
                let hash = sha256Hex(d)
                var e = old[f] ?? BackupEntry(file: f, sha256: hash, bytes: d.count,
                                              entries: entryCount(of: s),
                                              createdAt: ISO8601DateFormatter().string(from: fileDate(u)))
                if e.sha256 != hash { e.status = "tampered" }
                list.append(e)
            }
            saveIndex(list)
        }
    }

    private func nextBackupURL() -> URL {
        let base = "ledger.bak.\(stampFmt.string(from: Date()))"
        var name = "\(base).json"
        var i = 2
        while usedBackupNames.contains(name) || FileManager.default.fileExists(atPath: backupsURL.appendingPathComponent(name).path) {
            name = "\(base)-\(i).json"
            i += 1
        }
        usedBackupNames.insert(name)
        return backupsURL.appendingPathComponent(name)
    }

    private func backupURLs() -> [URL] {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(atPath: backupsURL.path) else { return [] }
        let urls = all.filter { $0.hasPrefix("ledger.bak.") && $0.hasSuffix(".json") }
            .map { backupsURL.appendingPathComponent($0) }
        return urls.sorted { a, b in
            let da = fileDate(a), db = fileDate(b)
            if abs(da.timeIntervalSince(db)) < 0.001 { return a.lastPathComponent < b.lastPathComponent }
            return da < db
        }
    }

    func backupFileList() -> [String] { backupURLs().map { $0.lastPathComponent } }

    /// 恢复：先校验只读状态与 schema，再**成功备份并校验**当前账本，最后写回。
    /// 只有备份确认写成功，才允许覆盖主文件（P1-1 / P1-2 / P2-4）。
    func restore(from url: URL) -> (before: Int, after: Int, ok: Bool) {
        var result = (before: 0, after: 0, ok: false)
        queue.sync {
            // 只读账本（更高 schema）不允许被旧备份覆盖
            guard !readOnly else {
                NSLog("DeskTodo store: restore rejected (read-only)")
                return
            }
            guard let d = try? Data(contentsOf: url),
                  let s = String(data: d, encoding: .utf8), isValid(s) else { return }
            // 目标备份的 schema 不得高于当前支持，避免越权写回"未来"数据
            if let v = schemaVersion(s), v > storeSchemaVersion {
                NSLog("DeskTodo store: restore rejected (backup schema too new)")
                return
            }
            let before = (try? String(contentsOf: ledgerURL, encoding: .utf8)).map { entryCount(of: $0) } ?? 0
            // 恢复前备份必须成功且可读回一致；失败就中止，绝不静默覆盖
            if let cur = try? Data(contentsOf: ledgerURL) {
                let dst = nextBackupURL()
                guard atomicWrite(cur, to: dst),
                      (try? Data(contentsOf: dst)) == cur else {
                    NSLog("DeskTodo store: restore aborted (pre-backup failed)")
                    return
                }
            } else if FileManager.default.fileExists(atPath: ledgerURL.path) {
                // 主文件存在但读不出来：无法安全备份，拒绝恢复
                NSLog("DeskTodo store: restore aborted (ledger unreadable)")
                return
            }
            guard atomicWrite(d, to: ledgerURL) else { return }
            // 恢复后按恢复出的 schema 重算只读状态（P2-4）
            readOnly = (schemaVersion(s) ?? storeSchemaVersion) > storeSchemaVersion
            refreshKnown()
            refreshIndexLocked()
            result = (before, entryCount(of: s), true)
        }
        return result
    }

    /// 七项自动审阅：只报计数与状态，不报内容。
    /// readOnly=true（默认）：只读；不创建/删除文件、不写索引 —— 供「备份自检」和诊断使用。
    /// readOnly=false：允许自动补齐备份（仅测试/维护显式调用）。
    func review(readOnly: Bool = true) -> BackupReview {
        var r = BackupReview()
        let fm = FileManager.default
        if !readOnly { refreshIndex() }

        // 1 目录可写
        let probe = dir.appendingPathComponent(".write-probe")
        let writable: Bool
        if readOnly {
            writable = fm.isWritableFile(atPath: dir.path)
        } else {
            writable = (try? Data("x".utf8).write(to: probe)) != nil
            try? fm.removeItem(at: probe)
        }
        r.lines.append("1/7 目录可写 " + (writable ? "✓" : "✗"))

        // 2 备份数 ≤ 5（只读模式不删；超限照实报 ✗）
        var files = backupFileList()
        if files.count > 5 && !readOnly {
            trimBackups(keep: 5)
            files = backupFileList()
            refreshIndex()
        }
        r.lines.append("2/7 备份数 \(files.count)/5 " + (files.count <= 5 ? "✓" : "✗"))

        // 3 最新备份可解析
        let newest = files.last.map { backupsURL.appendingPathComponent($0) }
        let newestJSON = newest.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let newestOK = newestJSON.map { isValid($0) } ?? false
        r.lines.append("3/7 最新备份可解析 " + (newestOK ? "✓" : (files.isEmpty ? "—（还没有备份）" : "✗")))

        // 4 最新备份条数 vs 当前账本（只读模式不自动补备份，避免"自检改变现场"）
        let current = (try? String(contentsOf: ledgerURL, encoding: .utf8)) ?? ""
        let curN = entryCount(of: current)
        var newestN = newestJSON.map { entryCount(of: $0) } ?? -1
        var matched = (curN == newestN)
        if !matched && !readOnly && curN > 0 {
            backupNow("auto")
            files = backupFileList()
            if let last = files.last, let s = try? String(contentsOf: backupsURL.appendingPathComponent(last), encoding: .utf8) {
                newestN = entryCount(of: s)
            }
            matched = (curN == newestN)
        }
        if matched {
            r.lines.append("4/7 最新备份条数 = 当前账本（\(curN)） ✓")
        } else if readOnly {
            // 上次写入之后还没备份，是正常中间态：下次保存/备份会补齐
            r.lines.append("4/7 备份 \(newestN) 条 / 当前 \(curN) 条 —（下次保存自动补齐）")
        } else {
            r.lines.append("4/7 最新备份条数 = 当前账本（\(curN)） ✗")
        }

        // 5 sha256 与索引一致（不一致标记 tampered，不删除）
        let idx = loadIndex()
        var tampered = 0
        for e in idx where e.status == "tampered" { tampered += 1 }
        if tampered == 0 {
            for f in backupFileList() {
                let u = backupsURL.appendingPathComponent(f)
                guard let d = try? Data(contentsOf: u) else { continue }
                if let e = idx.first(where: { $0.file == f }), e.sha256 != sha256Hex(d) { tampered += 1 }
            }
        }
        r.lines.append("5/7 备份未被篡改 " + (tampered == 0 ? "✓" : "✗（\(tampered) 份标记 tampered）"))

        // 6 账本非空但备份缺失（只读模式只报，不补）
        var missing = (curN > 0 && backupFileList().isEmpty)
        if missing && !readOnly {
            backupNow("auto")
            missing = backupFileList().isEmpty
        }
        r.lines.append("6/7 账本非空时有备份 " + (missing ? "✗" : "✓"))

        // 7 最新备份超过 30 天提醒
        var stale = false
        if let u = backupFileList().last.map({ backupsURL.appendingPathComponent($0) }) {
            stale = Date().timeIntervalSince(fileDate(u)) > 30 * 86400
        }
        r.lines.append("7/7 最新备份在 30 天内 " + (stale ? "✗（备份 30 天未更新）" : "✓"))

        return r
    }

    func indexReport() -> [String] {
        queue.sync {
            loadIndex().map { e in
                let u = backupsURL.appendingPathComponent(e.file)
                let d = (try? Data(contentsOf: u)) ?? Data()
                let h = sha256Hex(d)
                return "\(e.file) status=\(e.status ?? "-") match=\(h == e.sha256) bytes=\(d.count)/\(e.bytes)"
            }
        }
    }

    func logTail(_ n: Int) -> [String] {
        guard let s = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return String(s).split(separator: "\n", omittingEmptySubsequences: false).map(String.init).suffix(n).map { $0 }
    }

    // MARK: - 清空

    func wipe() -> [String] {
        var failed: [String] = []
        queue.sync {
            let fm = FileManager.default
            var targets: [URL] = [ledgerURL, focusURL, lockURL]
            for d in [backupsURL, snapshotsURL, logsURL] { targets.append(d) }
            if let all = try? fm.contentsOfDirectory(atPath: dir.path) {
                for n in all where n.hasPrefix("ledger.") || n.hasPrefix("data.") || n.hasPrefix(".") {
                    targets.append(dir.appendingPathComponent(n))
                }
            }
            var seen = Set<String>()
            for u in targets where !seen.contains(u.path) {
                seen.insert(u.path)
                guard fm.fileExists(atPath: u.path) else { continue }
                do { try fm.removeItem(at: u) } catch { failed.append(u.lastPathComponent) }
            }
            knownMtime = nil
            knownSize = -1
            prepare()
            NSLog("DeskTodo store: wiped")
        }
        return failed
    }

    // MARK: - 文件与工具

    func files() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { !$0.hasPrefix(".") }.sorted() ?? []
    }

    private func refreshKnown() {
        if let a = try? FileManager.default.attributesOfItem(atPath: ledgerURL.path),
           let m = a[.modificationDate] as? Date {
            knownMtime = m
            knownSize = (a[.size] as? NSNumber)?.intValue ?? -1
            knownHash = (try? Data(contentsOf: ledgerURL)).map { sha256Hex($0) }
        } else {
            knownMtime = nil
            knownSize = -1
            knownHash = nil
        }
    }

    @discardableResult
    private func atomicWrite(_ data: Data, to dest: URL) -> Bool {
        let fm = FileManager.default
        let dir = dest.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(dest.lastPathComponent).tmp-\(getpid())")
        do {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
            try data.write(to: tmp)
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
            NSLog("DeskTodo store: write failed")
            try? fm.removeItem(at: tmp)
            return false
        }
    }
}

struct BackupEntry: Codable {
    var file: String
    var sha256: String
    var bytes: Int
    var entries: Int
    var createdAt: String
    var status: String?
}

struct BackupReview {
    var lines: [String] = []
    var passed: Bool { !lines.contains { $0.contains("✗") } }
}
