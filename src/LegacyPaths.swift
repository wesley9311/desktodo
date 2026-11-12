import Foundation

/* 迁移需要识别上一版的路径，但旧路径字符串只允许出现在这里。
   日志、诊断、界面一律用占位符（legacy#1…）输出，不把旧文件名带给用户。 */
enum LegacyPaths {
    /// legacy#1：上一版账本文件名（与新版同目录）
    static let ledgerFileName = "data.json"
    /// legacy#2：上一版备份前缀（data.json.bak / .bak.1 / .bak.2）
    static let backupPrefix = "data.json.bak"
    /// legacy#3：上一版坏文件留证前缀
    static let corruptPrefix = "data.corrupt-"
    /// legacy#4：上一版快照文件名前缀（snapshots/data-*.json）
    static let snapshotPrefix = "data-"
    /// legacy#5：上一版日志目录（~/Library/Logs/DeskTodo）
    static let oldLogFolder = "DeskTodo"
}
