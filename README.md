# DeskTodo

**桌面上一本只记「你给自己派的活，最后做成了什么样」的日账本。**

`0.1.0` · MIT · macOS 12+ · Universal（Apple Silicon / Intel）· 195 条断言

## 下载

**[⬇ 下载 macOS 版（Universal）](https://github.com/wesley9311/desktodo/releases/latest)** — 一个包同时支持 Apple Silicon 与 Intel，不需要 Xcode。

安装三步：

1. 打开 dmg，把 `DeskTodo.app` 拖进「应用程序」。
2. 第一次打开会被系统拦住（未做 Apple 公证）：到「系统设置 → 隐私与安全性」点「仍要打开」。
3. 完成。它没有 Dock 图标，看菜单栏图标或桌面右下角的小圆点。

细节、卸载、备份恢复见 [docs/MANUAL.md](docs/MANUAL.md)。

## 四个动作

| | 做什么 | 在哪看见 |
|---|---|---|
| **记** | 写一件，回车进清单；过夜的自动接到今天 | 输入框 |
| **划** | 划掉一件；划错了能退账 | 清单 + 顶上的 `2/5` |
| **结** | 每天第一次打开结一句；拖过两天的进欠账面板 | 顶部灰条与橙条 |
| **稽** | 今日 / 本周 / 30 天 / 半年 / 年度 | 报告卡五个页签 |

## 三条承诺

| 承诺 | 怎么验 |
|---|---|
| 数据只在本地 | `open ~/Library/Application\ Support/DeskTodo/ledger.json`，明文 JSON |
| 随时能带走 | 菜单 →「导出账本…」，得到一个含 `meta` 的 JSON |
| 不联网也能用 | 菜单 →「不联网（天气停更）」，然后 `lsof -nP -a -p $(pgrep -f DeskTodo) -i` 无输出 |

没有账号、没有云同步、没有埋点、没有崩溃上报、不调用模型。

## 它读你什么

只读用量，不读内容：

- 日历 / 提醒事项（只读；用于「有会 vs 没会」对照）
- 屏幕使用时间（需要「完全磁盘访问」，可选）
- 前台 App 的 bundle id 与秒数（仅在屏幕使用时间读不到时兜底，7 天自动裁）
- 天气：`ipwho.is` 定位 + `open-meteo` 取数，一键可关

不读窗口标题、剪贴板、截图、网页内容。

## 它不做什么

不做番茄钟 / 专注计时、不拆解任务、不自动补记、不做连续天数激励、不做排行榜、不做社交、不做云同步、不读内容级屏幕信息、不做主题商店。

完整边界与判断标准见 [docs/POSITIONING.md](docs/POSITIONING.md)。

## 代码结构

```
src/*.swift              原生壳（3654 行 / 15 个文件）：窗口、圆点、菜单、桥、数据源
src/js/01..10-*.js       页面（3911 行 / 10 个分片），构建时拼成单个 IIFE
src/styles.css           样式（926 行）
tools/bundle.sh          分片 → 单文件（WKWebView 用 file://，不能用 ES module）
tools/audit.sh           边界审计八类
tools/check.js           195 条行为断言（headless Chrome，21 个用例）
tools/package.sh         universal 构建 + dmg + sha256
tools/release.sh         发版前预检（不 push、不打 tag）
tools/integrity.sh       产物完整性矩阵（9 项）
tools/docs-check.sh      文档数字与实测一致
```

## 文档

| 想知道 | 看 |
|---|---|
| 怎么装、怎么用、出问题怎么办 | [docs/MANUAL.md](docs/MANUAL.md) |
| 版本号怎么定 | [VERSIONING.md](VERSIONING.md) |
| 为什么这样做、不做什么 | [docs/POSITIONING.md](docs/POSITIONING.md) |
| 数据在哪、卸载后怎么处理 | [docs/ABOUT.md](docs/ABOUT.md) |
| 改代码、发版 | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) |

## 许可

代码 MIT；名称与图标保留。见 [LICENSE](LICENSE) 与 [NOTICE.md](NOTICE.md)。
