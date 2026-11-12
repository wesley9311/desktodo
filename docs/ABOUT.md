# 关于 DeskTodo

桌面上一本只记「你给自己派的活，最后做成了什么样」的日账本。

## 数据在哪

全部在你自己的硬盘上：

```
~/Library/Application Support/DeskTodo/
├── ledger.json          账本主文件（明文 JSON）
├── snapshots/           最近 5 份轮转快照
├── backups/             备份 + index.json（只记 hash/时间/条数，不记内容）
├── logs/desktodo.log    诊断日志
├── focus.json           前台 App 计时（最近 7 天）
└── .desk.lock           写锁
```

不上传、不联网、无账号。唯一的外部连接是天气（IP 定位 + open-meteo），可以在菜单里一键关掉；关掉之后进程不再发起任何请求。

## 带走

菜单 →「导出账本…」得到 `ledger-<版本>-<日期>.json`，含账本原样与 `meta` 段（导出时间、版本、构建号、schemaVersion）。不装这个 app 也能用文本编辑器读。

## 卸载之后

把 `DeskTodo.app` 拖进废纸篓即可。**数据默认保留**，下次装回来还能读。

要彻底清掉：先打开 app → 菜单「清空全部数据…」，再删 app。清空会连同快照、备份、日志、`focus.json` 与偏好里的位置缓存一起删除，不进废纸篓。

## 反馈

单一入口：<https://github.com/wesley9311/desktodo/issues>。附上菜单「复制诊断信息」的内容即可，那段只有版本、构建号、系统版本、架构、备份自检结果和最近 50 行日志，不含任何任务内容。

## 支持

- macOS 12 及以上
- Apple Silicon 与 Intel（同一个 universal 包）
- 未做 Apple 公证：首次打开需要手动允许一次，见 `MANUAL.md` 第 1 节
