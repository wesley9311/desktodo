# 开发文档

## 1. 结构

```
src/*.swift        原生壳 18 个文件 / 4357 行
  main.swift                 入口、单实例守卫、自检模式
  AppDelegate.swift          状态与生命周期（存储状态、窗口、计时器）
  AppDelegate+Window.swift   窗口、缩放、拖拽
  AppDelegate+Dot.swift      桌面小圆点、收起/展开
  AppDelegate+Chrome.swift   菜单栏图标、诊断日志
  AppDelegate+Menu.swift     菜单、清空、导出、回退
  AppDelegate+Bridge.swift   页面 ↔ 原生桥、读盘注入
  AppDelegate+Sources.swift  日历/提醒/屏幕时间/会话的数据源接线、权限自检
  AppDelegate+Weather.swift  天气（唯一网络出口）
  Storage.swift              存储入口的包装、导出、自检
  Store.swift                存储层：读/写/备份/快照/冲突/清空/迁移
  LegacyPaths.swift          旧路径常量（只在这里出现）
  Fixtures.swift             夹具（仅 DEBUG 编译，用于字节比对）
  sources.swift              EventKit / knowledgeC / 前台 App 计时
  Session.swift              锁屏、熄屏、睡眠、屏保、会话
  DesktopDot.swift           圆点窗口
src/js/01..10-*.js 页面 10 个分片 / 3911 行（构建时拼成单个 IIFE）
src/styles.css     样式 926 行
src/index.html     标记 90 行
tools/             构建、审计、断言、打包、发布、完整性、文档校验
```

## 2. 启动链路

```
main.swift
  └─ 单实例检查（同 bundle id 已有进程 → 激活它并退出）
  └─ NSApplication + AppDelegate
       ├─ didFinishLaunching：设置、菜单栏、窗口、心跳、外观
       ├─ WKWebView 加载 index.html（file://）
       └─ didFinish：readStore() → window.__load(json) → 推送状态/主题/缩放
```

页面只通过 `window.webkit.messageHandlers.bridge.postMessage` 与原生通信，类型：`save`、`load`、`menu`、`resize`、`collapse`、`weather`、`picker`、`export`、`quit` 等。

## 3. 数据

路径（常量，不从可变字段推导）：

```
~/Library/Application Support/DeskTodo/
├── ledger.json          主数据，schemaVersion=2
├── snapshots/           轮转快照，保留 5 份
├── backups/             备份 + index.json（只记 hash/时间/条数）
├── logs/desktodo.log    诊断日志（600，512 KB 轮转）
├── focus.json           前台 App 计时（7 天）
└── .desk.lock           写锁
```

字段（只加不改）：

| 键 | 含义 |
|---|---|
| `v` | 格式版本，当前 2 |
| `nodes` | 条目（任务、项目、文件节点） |
| `seq` | 下一个 id |
| `daily` | `{"日期": 划掉件数}`，账本，只累加 |
| `log` | 最近 60 天明细 `{id, at, d, p}` |
| `flow` | 每天进出 `{n, x, q}` |
| `seen` | 哪天开着过（永久保留） |
| `byProj` | 按项目汇总（记 id） |
| `fb` / `hide` / `gap` / `gapOff` / `said` / `saidN` / `vote` / `anniv` | 纠错与判断记录 |

**读取方必须忽略未知字段；只有删改语义时才升 `v`。**

## 4. 存储层

- 写入走同一条串行队列；落盘用「临时文件 → fsync → rename → fsync 目录」，权限 600。
- 覆盖前备份：`backups/ledger.bak.<YYYYMMDD>T<HHmmss>.json`，轮转 5 份；`index.json` 只记 hash、字节数、条数、时间。
- 每日快照：`snapshots/`，5 份。
- 冲突：写前比对磁盘版本；被其他进程改过则留副本、不覆盖，页面按磁盘版本重载。
- 解析失败：只读，界面给文件路径、备份路径、「导出原始文件」。绝不按空账本重建。
- `schemaVersion > 2`：只读、可导出、拒绝写入，并给可读原因。

## 5. 测试与闸门

| 层 | 命令 | 内容 |
|---|---|---|
| 边界审计 | `./tools/audit.sh` | 8 类 16 项 |
| 行为断言 | `./tools/bundle.sh && node tools/check.js` | 195 条 / 21 用例 |
| 文档数字 | `./tools/docs-check.sh` | 行数、断言数与实测一致 |
| 数据层自检 | `DESKTODO_TEST_HOME=$(mktemp -d) · --selftest` | 存储规则 |
| 构建闸门 | `./build.sh` | 自检不过不安装 |
| 发布预检 | `./tools/release.sh` | 四同步、干净工作区、不 push/不打 tag |
| 产物完整性 | `./tools/integrity.sh` | 9 项矩阵 |
| 一键验证 | `./tools/verify.sh [--artifact <dmg>]` | 上面能自动化的全部 + 夹具金标 + 对抗审查 |
| 对抗审查 | `./tools/adversarial.sh` | 只跑可自动化项；其余标 MANUAL/CI 与方法 |
| 夹具金标 | `tools/fixtures/expected/*.json` | 10 组场景的规范化输出，`verify.sh` 逐个 diff |
| Git 审查 | `./tools/git-audit.sh` | 工作区、四同步、措辞、提交规范、数据/密钥/产物、卫生 |

**已知盲区**：断言全部在页面 DOM/逻辑层；原生窗口、浮窗、小圆点、菜单栏、桥协议没有运行时断言。不得用「断言通过」推断界面正常。

## 6. 构建与发布

| 命令 | 用途 | 是否改本机安装 |
|---|---|---|
| `./tools/hot.sh` | 只改页面时热替换 | 改已安装 app 的三个资源文件 |
| `./build.sh` | 本机开发构建（自签证书） | 是，装到 `~/Applications` |
| `./tools/package.sh` | universal 构建 + dmg + sha256 | 否，只写 `dist/` |
| `./tools/release.sh` | 发版预检 | 否，且不 push、不打 tag |

发版：打 tag `v<版本>` → CI 跑 preflight/audit/behavior/build-arm64/build-intel/package/release → 上传 dmg 与 SHA256SUMS.txt 并勾 Pre-release。

## 7. 文档规范

- 数字一律写实测值；`docs-check.sh` 会拦过期数字。
- 同一件事只允许一处写；其余文档指过去。
- 产品文案：不评价、不催促、不用感叹号、量词统一为「件」。
- 不写计划，只写已发生。

## 8. 边界

- 零第三方运行时依赖；只链接系统框架。
- 唯一网络出口是 `AppDelegate+Weather.swift` 的 `httpJSON`，闸门在第一行；`audit.sh` 会拦其他调用。
- 数据文件 600；日志 600；仓库不收数据、不收私钥、不收构建产物。
