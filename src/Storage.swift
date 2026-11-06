import Cocoa
import WebKit
import UniformTypeIdentifiers

/* 全 app 只有这一处知道四件事：数据放哪、怎么写进去、怎么带出去、怎么删掉。

   这条注释以前是假的：路径写在这里，读写却写在 AppDelegate.swift 里，
   而那个文件开头写着"只有状态和生命周期"——两个文件都在说谎。
   现在归位：路径 + 安全规则 + 导出 + 清空都在这个文件，
   AppDelegate.swift 只剩状态和生命周期。

   安全规则（别处不许绕）：
     1. 只有解析得动的 JSON 才准落盘；
     2. 覆盖前把上一版留成 data.json.bak，一次一份；
     3. 主文件坏了先改名留证，再退备份，绝不静默变成空清单；
     4. 删就是 delete——不进废纸篓、不留副本、不留"云备份"。 */

// MARK: - 路径

let supportDir: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("DeskTodo", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

let storeURL = supportDir.appendingPathComponent("data.json")

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

// MARK: - 数据读写

extension AppDelegate {

    func isValidStore(_ s: String) -> Bool {
        guard let d = s.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: d)) != nil
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

    @discardableResult
    func safeWrite(_ json: String, to url: URL) -> Bool {
        guard isValidStore(json) else {
            NSLog("DeskTodo save: 拒绝写入非法 JSON（\(json.count) 字节）")
            return false
        }
        let fm = FileManager.default
        let bak = AppDelegate.backupURL(of: url)
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: url, to: bak)
        }
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("DeskTodo save: 写盘失败 \(error.localizedDescription)")
            return false
        }
    }

    /* 读的三条规则，顺序不能换：
       1. 主文件能解析 → 用它，什么都不做；
       2. 读不出来 → 先把损坏的原文件原样挪到 data.corrupt-时间戳.json，
          再退回备份。挪这一步是关键：不挪，前端就会拿到 null 显示成空清单，
          下一次任意操作 persist 一遍，好数据就真没了；
       3. 备份也没有 → 返回 null 当新用户，但坏文件已经留在这儿了。

       同时把"发生过什么"记进 storeStatus，界面据此说话——
       用户不该在打开时看到一个空清单却不知道为什么。 */
    func readStore() -> String {
        let fm = FileManager.default
        let bak = AppDelegate.backupURL(of: storeURL)
        var st = StoreStatus()
        st.at = Date()

        if let s = safeRead(storeURL) {
            st.kind = .normal
            storeStatus = st
            return s
        }

        let bakJSON = safeRead(bak)

        if fm.fileExists(atPath: storeURL.path) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            let bad = supportDir.appendingPathComponent("data.corrupt-\(f.string(from: Date())).json")
            do {
                try fm.moveItem(at: storeURL, to: bad)
                st.kept.append(bad.lastPathComponent)
                NSLog("DeskTodo read: data.json 读不出来，已原样保留为 \(bad.lastPathComponent)")
            } catch {
                // 连改名都失败（磁盘满 / 权限）——原文件原地不动，但必须留痕
                st.kept.append(storeURL.lastPathComponent)
                NSLog("DeskTodo read: data.json 读不出来，且留证失败 \(error.localizedDescription)")
            }
        }

        if let s = bakJSON {
            st.kind = .recovered
            NSLog("DeskTodo read: 已回退到 data.json.bak")
            storeStatus = st
            // 立刻把备份写回主文件：不然这一次运行里主文件一直是缺的，
            // 用户下次再出问题就没有"上一版"可退了。
            if safeWrite(s, to: storeURL) {
                NSLog("DeskTodo read: 已用备份重建 data.json")
            }
            return s
        }

        st.kind = fm.fileExists(atPath: storeURL.path) || !st.kept.isEmpty ? .corrupt : .fresh
        storeStatus = st
        return "null"
    }

    /// 返回是否真的落盘。调用方必须把 false 告诉用户，
    /// 不能让"我勾完了"和"其实一个字节都没写"同时成立。
    @discardableResult
    func writeStore(_ json: String) -> Bool {
        safeWrite(json, to: storeURL)
    }

    /// 数据文件夹里都有什么（"打开文件夹"和诊断用）
    func storeFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: supportDir.path))?
            .filter { !$0.hasPrefix(".") }.sorted() ?? []
    }

    // MARK: - 导出

    /* 导出的标准只有一条：拿到这个 zip 的人，不装这个 app 也能回答
       "我这些年干了什么"。所以里面是原始 data.json + 一份人能读的说明，
       不用数据库、不用压缩包内嵌结构。 */
    func exportData(readme: String, completion: @escaping (Bool) -> Void) {
        // 排查用：`defaults write local.desktodo.app dbgExport -string /tmp/x.zip`
        // 跳过面板直接导，验证"导出来的包到底能不能读"。用完会自己删掉这个开关。
        if let p = UserDefaults.standard.string(forKey: "dbgExport"), !p.isEmpty {
            UserDefaults.standard.removeObject(forKey: "dbgExport")
            let ok = buildExport(to: URL(fileURLWithPath: p), readme: readme)
            NSLog("DeskTodo export(dbg): \(p) ok=\(ok)")
            completion(ok)
            return
        }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let panel = NSSavePanel()
        panel.title = "导出全部数据"
        panel.prompt = "导出"
        panel.message = "一个 zip：原始 data.json + 一份人能读的说明。\n解压不需要这个 app，用文本编辑器就能看。"
        panel.nameFieldStringValue = "浮窗待办-\(f.string(from: Date())).zip"
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
            // 主文件不在就从备份或内存里补一份，宁可导出到备份也不能导出一个空包。
            let dst = tmp.appendingPathComponent("data.json")
            if fm.fileExists(atPath: storeURL.path) {
                try? fm.copyItem(at: storeURL, to: dst)
            }
            if !fm.fileExists(atPath: dst.path) {
                let s = safeRead(storeURL) ?? safeRead(AppDelegate.backupURL(of: storeURL)) ?? "null"
                try s.write(to: dst, atomically: true, encoding: .utf8)
                NSLog("DeskTodo export: 主文件不可用，导出的是备份/当前内存数据")
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

    /* "删"必须真的是删：主文件、备份、坏文件留证、前台计时记录，一起走。
       不进废纸篓、不留副本——留了就等于没删，那条承诺是假的。 */
    @discardableResult
    func wipeAllData() -> [String] {
        let fm = FileManager.default
        var targets: [URL] = [
            storeURL,
            AppDelegate.backupURL(of: storeURL),
            supportDir.appendingPathComponent("focus.json")
        ]
        if let all = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
            // 留证文件有好几代命名（data.corrupt-* / 早期的 data.backup-*），
            // 少删一个就等于"删了但还留着"，那条承诺就假了。
            for u in all {
                let n = u.lastPathComponent
                if n.hasPrefix("data.corrupt-") || n.hasPrefix("data.backup-") { targets.append(u) }
            }
        }
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
        NSLog("DeskTodo wipe: 已删 \(gone.joined(separator: ", "))"
              + (failed.isEmpty ? "" : "；失败 \(failed.joined(separator: ", "))"))
        storeStatus = StoreStatus()
        return failed
    }

    // MARK: - 排查用

    /// `defaults write local.desktodo.app dbgSaveTest -bool true` 后重启，
    /// 在 /tmp 里跑一遍写盘规则，用日志回答"坏数据到底能不能覆盖好数据"。
    func runSaveSelfTestIfAsked() {
        guard UserDefaults.standard.bool(forKey: "dbgSaveTest") else { return }
        UserDefaults.standard.removeObject(forKey: "dbgSaveTest")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("desktodo-selftest")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("data.json")
        let good1 = "{\"nodes\":[],\"v\":1}"
        let good2 = "{\"nodes\":[],\"v\":2}"
        let bad = "{\"nodes\":[{\"text\":\"半截"
        var r: [String] = []
        r.append("首写=\(safeWrite(good1, to: f))")
        r.append("坏数据被拒=\(!safeWrite(bad, to: f))")
        let after = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        r.append("内容没被改=\(after == good1)")
        r.append("二写=\(safeWrite(good2, to: f))")
        let bak = (try? String(contentsOf: AppDelegate.backupURL(of: f), encoding: .utf8)) ?? ""
        r.append("备份是上一版=\(bak == good1)")
        r.append("主文件是新版=\(((try? String(contentsOf: f, encoding: .utf8)) ?? "") == good2)")
        try? FileManager.default.removeItem(at: dir)
        debugLog("saveSelfTest " + r.joined(separator: " "))
    }
}
