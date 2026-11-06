# 开发文档

> 这份文档面向**改代码的人**。它不解释这个产品为什么存在（那在 `POSITIONING.md`），
> 只解释：代码怎么组织、数据怎么流动、口径怎么保证、改完怎么验、怎么发出去。
>
> 所有数字都是 2026-11-06 实测的，命令附在每节末尾。数字变了就更新，别让文档变成传说。

---

## 1. 三层结构，两个进程边界

```
┌─────────────────────────────────────────────────────────┐
│  Swift 壳（3269 行 / 15 个文件）                          │
│  窗口、菜单、桌面圆点、WKWebView、日历/提醒/屏幕数据源      │
└───────────────────────┬─────────────────────────────────┘
                        │  ① 原生 → 页面：evaluateJavaScript("window.__xxx(...)")
                        │  ② 页面 → 原生：webkit.messageHandlers.bridge.postMessage
┌───────────────────────┴─────────────────────────────────┐
│  页面（3789 行 JS + 924 行 CSS + 90 行 HTML）             │
│  单文件 app.js，一个 IIFE，10 个分片共享闭包               │
└─────────────────────────────────────────────────────────┘
```

**唯一的进程边界是 WKWebView。** 没有 XPC、没有 helper、没有后台服务。

### 1.1 Swift 文件职责

| 文件 | 行数 | 管什么 |
|---|---:|---|
| `AppDelegate.swift` | 155 | 生命周期、单例入口、启动装配 |
| `main.swift` | 12 | `NSApplication` 启动 |
| `AppDelegate+Window.swift` | 346 | 窗口创建、定位、尺寸、屏幕边缘约束 |
| `AppDelegate+Chrome.swift` | 161 | 窗口外观、毛玻璃、层级、失焦行为 |
| `AppDelegate+Dot.swift` | 232 | 桌面小圆点：绘制、拖动、点击展开 |
| `AppDelegate+Menu.swift` | 338 | 系统菜单全部条目与动作 |
| `AppDelegate+Bridge.swift` | 234 | 桥：收页面消息、给页面注入 |
| `AppDelegate+Sources.swift` | 247 | 日历/提醒/屏幕/前台 的数据汇总与授权入口 |
| `AppDelegate+Weather.swift` | 207 | **唯一允许联网的文件**：定位 + 取天气 |
| `AppDelegate+Files.swift` | 68 | 导出、打开数据目录、选文件 |
| `AppDelegate+Appearance.swift` | 20 | 主题应用 |
| `Storage.swift` | 330 | 读写 `data.json`、备份、损坏恢复、权限收紧 |
| `sources.swift` | 502 | EventKit / knowledgeC / 前台 app 的底层读取 |
| `Session.swift` | 126 | 空闲、锁屏、熄屏、睡眠状态 |
| `DesktopDot.swift` | 291 | 圆点的窗口与视图实现 |

**约定**（`CONTRIBUTING.md` 已写，这里给出原因）：
状态只能放在 class，方法一律进 `extension AppDelegate`。
Swift 的 extension 不能有 stored property，所以拆文件**不可能拆出隐藏状态**——
这是"拆成 15 个文件却仍然只有一个状态机"的唯一保证。

### 1.2 前端分片职责

按文件名排序拼接，顺序即加载顺序，**共享一个闭包**：

| 分片 | 行数 | 管什么 |
|---|---:|---|
| `01-core.js` | 198 | `state` 定义、`send`/`persist`、`byId`、工具函数、DOM 引用表 |
| `02-plan.js` | 469 | 日程（今天/明天）、`rollover`、日结条、欠账面板、提醒 chip 文案 |
| `03-nodes.js` | 600 | 清单渲染（任务行、项目行）、增删改、就地改名、`removeNode` |
| `04-panels.js` | 489 | 提醒抽屉、`+` 弹出菜单、文件选择回调、`checkDue` |
| `05-today.js` | 416 | **统计口径的家**：`daily` / `flow` / `byProj` / `dayObserved` / `debts` |
| `06-report.js` | 461 | 报告卡：热力图、月柱、周柱、`yearStats`、外部来源行 |
| `07-truth.js` | 502 | 三层纠错、年轮页签、判断句、`renderReport`、报告高度锁 |
| `08-anniv.js` | 154 | 年轮公告、`window.__load`（数据入口）、`tickClock` |
| `09-boot.js` | 239 | 事件绑定、拖拽/缩放、`__tick`、外部数据入口 |
| `10-data.js` | 261 | 导出包的「读我.md」、`diagText`、数据状态条 |

**为什么不能 ES module**：WKWebView 用 `file://` 加载，`import` 会撞 CORS。
绕路要起本地 HTTP 服务，为了模块化引入一个常驻进程，不值得。

**为什么 `window.__load` 在 `08-anniv.js`**：历史原因，它本该在 `01-core.js`。
见第 9 节技术债。

---

## 2. 启动链路（顺序很关键）

```
NSApplication 启动
  └→ AppDelegate 装配
      └→ 创建 WKWebView，loadFileURL(index.html)
          └→ 页面加载 app.js，闭包执行（此时 state 全是空值）
              └→ webView 加载完成
                  └→ pushStore() / pushData()
                      └→ evaluateJavaScript("window.__load(<data.json 内容>)")
                          ├→ state 逐字段填充
                          ├→ rollover()   跨夜继承 + 顺延计数
                          ├→ render()     清单 + 日程 + 页脚
                          ├→ tickClock()
                          └→ maybeAnniversary()
                      └→ evaluateJavaScript("window.__ext(<系统数据>)")
                      └→ evaluateJavaScript("window.__onWeather(...)")（若已取到）
```

**这条顺序是硬约束**：`__load` 之前**任何** `render()` 都不能触发 `persist()`，
否则空 state 会覆盖磁盘上的 `data.json`。

目前的保证是"顺序正确"，不是"结构正确"——
见 `docs/audits/2026-11-06.md` 第 4 节，建议加一道闸门。

---

## 3. 桥协议

### 3.1 页面 → 原生

```js
send(type, obj)   // 内部：bridge.postMessage(Object.assign({type}, obj))
// bridge 为 null（在浏览器里跑）时静默返回，不抛错
```

| type | 载荷 | 原生做什么 |
|---|---|---|
| `save` | `{payload: JSON字符串}` | 写 `data.json`，失败回调 `__saveFail()` |
| `status` | `{pending: N}` | 更新菜单栏显示的未完成数 |
| `resize` | `{height: 点}` | 调整窗口高度（`contentHeight()` 已按 zoom 折算） |
| `resizeStart` / `resizeDrag` / `resizeEnd` | `{edge, dw, dh}` | 手动拉窗口边缘 |
| `dragStart` / `dragMove` | — | 拖动窗口 |
| `collapse` | `{value: bool}` | 收起 / 展开窗口 |
| `menu` | — | 在鼠标位置弹系统菜单 |
| `theme` | `{mode}` | 切窗口材质 |
| `weatherRefresh` | — | 重新取天气（受「不联网」闸门约束） |
| `extRefresh` | — | 重读日历/提醒/屏幕 |
| `extAuth` | `{kind: 'cal'\|'rem'\|'both'}` | 请求系统授权 |
| `privacy` | `{pane}` | 打开对应隐私设置页 |
| `fda` | — | 打开「完全磁盘访问」设置 |
| `pick` | `{mode, for, path}` | 弹文件/文件夹选择框 |
| `open` | `{path}` | 用默认程序打开文件，或在访达中显示 |
| `reveal` / `revealStore` | — | 在访达中显示 / 打开数据目录 |
| `export` | — | 导出 zip |
| `copyDiag` | — | 复制诊断信息 |
| `alert` | `{...}` | 弹原生提示 |
| `log` | `{msg}` | 写调试日志（仅排查用） |
| `quit` | — | 退出 |

### 3.2 原生 → 页面

| 入口 | 何时调用 | 作用 |
|---|---|---|
| `window.__load(json)` | 首次载入、清空后重置 | 填 state → rollover → render |
| `window.__ext(obj)` | 系统数据刷新后 | 报告卡的日历/提醒/屏幕行 |
| `window.__onWeather(w)` | 取到天气 / 关掉联网 | `{off:true}` 时清空天气，不留旧温度 |
| `window.__storeState(o)` | 读盘结果 | 数据出问题时的橙色提示条 |
| `window.__saveFail()` | 写盘失败 | 8 秒内提示一次，故意做得吵 |
| `window.__tick()` | 每秒一次（原生驱动） | 补 seen 戳、rollover、检查提醒、年轮 |
| `window.__onShow()` / `__onBlur()` | 窗口显示 / 失焦 | 重绘 / 收面板 |
| `window.__beforeBlur()` | 即将失焦 | 返回 `false` 表示"可以收" |
| `window.__setTheme` / `__setZoom` / `__setManual` | 菜单操作 | 外观与尺寸 |
| `window.__setCollapsed(v)` / `__toggleCollapse()` | 菜单操作 | 收起态 |
| `window.__openReport(tab)` | 菜单「预览年轮」等 | 直接打开某一页签 |

**为什么 `__tick` 由原生驱动**：窗口收成小圆点时，系统会降低页面定时器的频率，
自己 `setInterval` 会走偏。原生那一侧有可靠的 1 秒定时器。

---

## 4. 数据格式

文件：`~/Library/Application Support/DeskTodo/data.json`，权限 `600`。

```json
{
  "v": 2,
  "nodes": [], "seq": 1,
  "log": [], "daily": {}, "flow": {}, "byProj": {},
  "seen": {}, "seenFrom": "", "settle": "",
  "gap": {}, "gapOff": 0,
  "hide": {}, "fb": [], "said": {}, "saidN": {}, "vote": {},
  "anniv": {}
}
```

### 4.1 字段表

| 键 | 类型 | 含义 | 谁写 |
|---|---|---|---|
| `v` | int | 格式版本，当前 **2** | `persist()` |
| `nodes` | array | 全部条目（任务、项目、文件节点） | 增删改 |
| `seq` | int | 下一个可用 id | `addTask` 等 |
| `log` | array | 最近 **60 天**的完成明细 `{id, at, d}` | `markDone` |
| `daily` | object | `{"YYYY-MM-DD": 完成件数}` **唯一账本** | `bumpDay` |
| `flow` | object | `{"日期": {n, x, q}}` 新写 / 删掉 / 认赔 | `bumpFlow` |
| `byProj` | object | `{"年份": {"项目id": 件数}}` | `bumpProj` |
| `seen` | object | `{"日期": 1}` 这天 app 开着，最多留 **800** 天 | `markSeen` |
| `seenFrom` | string | 最早一次写 `seen` 的日期，裁剪时不动 | `markSeen` |
| `settle` | string | 日结条已经给哪一天看过 | `renderAgenda` |
| `gap` | object | 日级对账：`0`=确实没做，`1`=忘了记 | `doGap` |
| `gapOff` | number | 从哪天起 14 天不问 | `doGap` |
| `hide` | object | 被用户永久藏掉的来源行 | `doFb` |
| `fb` | array | 用户点过「数不对」的记录，**只存档，不改变任何输出** | `doFb` |
| `said` | object | `{"YYYY-MM": {判断类别: 原话}}` 月级投票的素材 | `noteSaid` |
| `saidN` | object | 某类判断被说「不准」的次数，≥2 永久静音 | `doVote` |
| `vote` | object | `{"YYYY-MM": {判断类别: 'ok'\|'no'}}` 防重复打扰 | `doVote` |
| `anniv` | object | `{"seen2026": 1}` 哪一年的年轮公告看过 | `annivSeen` |

### 4.2 节点（`nodes[]`）

| 字段 | 用于 | 说明 |
|---|---|---|
| `id` | 全部 | 单调递增，删除后不复用 |
| `type` | 全部 | `task` / `project` |
| `text` | 全部 | 标题，上限 90 字 |
| `parentId` | task | 挂在哪个项目下，`null` 是顶层 |
| `path` | task / project | 绑定的本地文件/文件夹，可空 |
| `kind` | project | `folder` / `file` |
| `collapsed` | project | 折叠状态 |
| `done` | task | 是否完成 |
| `doneAt` | task | 完成时刻。**取消勾选时靠它退账**（见 AUDIT A1） |
| `due` | task | 到期日。**由系统写，不是用户设的**，每天被 rollover 重写 |
| `carried` | task | 顺延天数，跨夜未完成时 +1，上界 **366** |
| `created` | task / project | 创建时刻，用于折算 `carried` |
| `remindAt` | task | 单次提醒的时刻戳 |
| `range` | task | 时间段提醒 `{from, to, hh, mm}` |
| `fired` | task | 是否已响过 |
| `custom` | task / project | 用户亲手改过名，换绑路径时不再被文件名覆盖 |
| `moved` | task | 用户手动顺延过 |

### 4.3 格式演进的唯一规则

> **只加字段，不改、不删。**

- 新增字段必须有默认值语义（读不到就当作 `0` / `''` / `{}`）。
- 新版写的数据，老版本必须还能读（老版本会忽略不认识的键）。
- `SCHEMA_V` 只在**破坏性**变更时 +1。到目前为止是 2（加 `daily` 与 `settle` 那两次）。
- 老数据**不重算、不反推**。典型例子：`flow.q`（认赔）是 0.4.0 那批才有的，
  所以 `yearFlow` 里用 `anyQ` 判断"这一年到底有没有记过 q"，没有就不显示「认赔 N 件」，
  而不是把 `x` 拆一部分出来假装是 `q`。

---

## 5. 统计口径（这个产品最容易搞坏的地方）

### 5.1 唯一的定义

```js
dayDone(day)      // 那天完成了几件。读 daily，只此一处
daySeen(day)      // 那天 app 开着吗
dayObserved(day)  // 那天我"看得见"吗 = daily 有数 | seen 有戳 | flow 有 n/x/q
dataStart()       // 最早一条数据是哪天
```

`tools/audit.sh` 第 6 项强制：`dayDone` / `dayObserved` **各只允许有一处实现**，
且除 `05-today.js` 外**不许**直接 `dailyMap()[...]` 取值。

**为什么用脚本锁死**：这个产品已经三次把"没记录"算成 0 件。
三次都不是算术写错，而是**同一件事有两份实现，改了一份忘另一份**。

### 5.2 七条规则

| # | 规则 | 违反会怎样 |
|---|---|---|
| 1 | **没记录 ≠ 0 件。** 任何进图表、进百分比、进平均、进连续天数的数，先过 `dayObserved` | 空白被画成"那天你什么都没干" |
| 2 | **日均的分母是 `observed`，不是日历天数** | 用日历天数会把"不知道"稀释成"很少" |
| 3 | **`due` 不能进历史统计。** 它每天被 rollover 重写，只代表"现在排在哪天" | 昨天的数会跟着今天变 |
| 4 | **真正的拖延看 `carried`，不看 `due`** | 用 `due` 判积压永远返回"没有积压" |
| 5 | **`daily` 只增不减地累加，但"取消勾选"必须真减回来** | 账目永久偏高，详见 AUDIT A1 |
| 6 | **下界必须说出来。** 「最长连续」是下界（遇到"不知道"就断），不能当精确值展示 | 用户以为那就是真实值 |
| 7 | **不补记、不反推、不猜。** 用户说"忘了记"，只标一下，不替他填数 | 历史一旦不能信，产品就没有存在意义 |

### 5.3 已知的分子分母陷阱（都踩过）

- **项目占比**：`byProj` 是后加的功能，早于它的完成没有归属。
  所以当"挂过项目的件数 < 全年完成数 × 0.9"时，**不报百分比**，改说"还算不了"。
- **有会 vs 没会**：只比**确定的工作日**。周末、日历标了「休」的、以及"有名字但没说休还是班"的
  （节气与除夕混在一起）全部排除。两组各不足 5 天才不出这行。
- **月柱**：整月没有 `observed` 的日子时，不写"0 件"，写"没记录"。
- **节日**：只认系统里真实订阅的节假日日历，且只认「休 / 班」标记。
  节气（小寒、立春）不是假期，不许当放假处理。

---

## 6. 构建与运行

### 6.1 三条路，用途完全不同

| 命令 | 做什么 | 什么时候用 | 会不会掉权限 |
|---|---|---|---|
| `./tools/hot.sh` | 只替换 `index.html` / `styles.css` / `app.js` 到已安装的 app，重启 | **只改 HTML/CSS/JS** | 不会（不重签） |
| `./build.sh` | `swiftc` 编译 + 组装 app + 本机自签证书签名 + 安装到 `~/Applications` | 改了 Swift | 不会（证书固定） |
| `./tools/dist.sh` | 组装 + **ad-hoc 签名** + 打 zip 到 `dist/` | 发版给别人的时候 | 与权限无关（对方首次运行要右键） |

**为什么 `build.sh` 和 `dist.sh` 的签名不一样**：

- `build.sh` 用本机固定自签证书（`~/Library/Keychains/desktodo-signing.keychain-db`），
  TCC 授权（日历 / 提醒 / 磁盘）绑的是这个证书的指定要求，所以**重建不掉权限**。
- `dist.sh` 用 ad-hoc（`codesign -s -`），任何机器都能跑，没有证书依赖。
  代价是对方第一次要右键打开，且每次更新可能重新授权即可。

### 6.2 前端打包

```bash
./tools/bundle.sh
# 输出：build/Resources/{index.html, styles.css, app.js}
# 自检：IIFE 包裹存在、语法可解析、5 个关键定义都在
```

自检那一步不是形式主义：`../js/*.js` 拼错一个顺序，页面会静默白屏。

---

## 7. 测试

### 7.1 两层，各管一件事

| 层 | 命令 | 管什么 | 现在 |
|---|---|---|---|
| 边界 | `./tools/audit.sh` | **不能做的事有没有被偷偷做** | 6 类 |
| 行为 | `node tools/check.js` | **该做的事有没有做对** | 129 条 / 13 个用例 |

`audit.sh` 的六类：

1. **网络出口**：除 `AppDelegate+Weather.swift` 外不许出现 `URLSession` 等；
   页面里不许出现 `fetch` / `XMLHttpRequest` / `WebSocket` / `sendBeacon`；
   域名白名单只有 `open-meteo` / `ipwho.is`（`DOCTYPE plist` 例外）。
2. **反遥测**：出现 `analytics|telemetry|sentry|firebase|umeng|...` 直接失败。
3. **权限面**：`Info.plist` 的键必须全在白名单里，**多一个就红**。
4. **数据不入库**：`git ls-files` 里不许有 `data.json` / `*.keychain*` / `dist/` / `build/`。
5. **可移植性**：源码里不许出现 `/Users/<名字>`。
6. **口径唯一**：`dayDone` / `dayObserved` 各只一处；除 `05-today.js` 外禁止直接索引 `daily`。

**`audit.sh` 失败等于不能合。** 它就是为"有人顺手加一行 `URLSession`"准备的。

### 7.2 怎么写一条新断言

`tools/check.js` 的模型：生成一个带假数据的页面 → headless Chrome 打开 →
页面里跑断言 → 从 `<pre id="out">` 读回 `PASS/FAIL` 行。

```js
const caseXxx = makePage('__t_xxx.html', {
  load: { /* 完整 data.json 结构，缺字段会被当成空 */ },
  ext: null,                       // 或 extFull（日历/提醒/屏幕夹具）
  body: `
  var t = txt();                    // 报告卡的 textContent
  ok('断言名', 条件, '失败时给的证据');
  tab('yr');                        // 切页签
  // ...
  `
});
// 最后在文件末尾的运行器数组里加一项：['用例名', caseXxx]
```

可用的页面内辅助函数：`txt()`、`tab(k)`、`ask(k)`、`ok(name, cond, extra)`、
`window.__sent`（所有发给原生的消息）、`window.__debugState()`（当前 state）、
`window.__tick()`、`window.__openReport(tab)`。

**写断言的规矩**（这一条比写法重要）：

> 断言要钉**行为**，不要钉**实现**。
> 反例：`ok('有 .a-settle 这个节点', !!document.querySelector('.a-settle'))`
> —— 节点在，但 CSS 把它藏了，断言照样绿，用户照样看不见。
> 正例：先断言 `getBoundingClientRect().height > 0`，再断言文案。

同理，涉及数字的断言要**成对**写：既断言"该有的有"，也断言"不该有的没有"。
例：导出包里**有**任务正文，诊断信息里**没有**任务正文。

### 7.3 十三组用例（当前）

| 用例 | 管什么 |
|---|---|
| 三层纠错 | 行级 `?` / 日级对账 / 月级投票 |
| 授权状态 | `ask` / `denied` / 无 ext 时的话术与入口 |
| 页签渲染 | 五个页签都能出内容，不报错 |
| 欠账与日结 | 欠账能点开、能放回今天、能销账；日结只报实数 |
| 本周页签 | 周一起算，不拿 7 天当分母 |
| 开着但没勾 | 整周开着却 0 件时，不许说成"没有记录"（同一屏两句话不能打架） |
| 连续是下界 | 区间里有看不见的日子时，「最长连续」必须标 `≥` |
| 手动顺延记账 | 「→」和日期 chip 都要累加 `carried`，欠账不能被手动点干净 |
| 观测口径 | 没记录不写成 0；`seen` 戳真的写进去且只写日期 |
| 积压与占比 | `carried` 判积压；项目占比残缺时不出假数 |
| 口径一致 | 月度 / 对照 / 区间文案三处口径一致 |
| 导出与状态 | 导出含正文、诊断不含正文、数据状态条 |
| **账本自洽** | 60 天后取消勾选能退账；`carried` 上界；认赔算观测；报告高度只增不减 |

---

## 8. 发版

### 8.1 版本号

**版本号是给使用者的可信度信号，不是变更日志。** 判断只有一条：**有没有外人连续用过这个包。**

```
0.y.z   还没有外人连续用过。第一份公开包必须落在这里。
1.0.0   门槛是外部事实，不是自我感觉：
        3 个体验官连用 7 天，没丢数据、没崩、没算错口径。在此之前一律不进 1。
y       加功能，或改统计口径（口径一改，账目就不可比，必须能被识别出来）
z       只修问题。不动口径、不加功能。
```

一句话记住：**小活走尾号，大升级才动次号。**

- **小活**（永远只加 `z`）：修 bug、改文案、调样式、性能优化、补断言、改注释、重打包。
  这类改动一天做十件，也只有一个尾号。
- **大升级**（才动 `y`）：多了用户能看见的一件能力，或者账目口径变了。
  后者必须动次号——同一份数据用两种口径算，两个数都"对"，人对不上就会怀疑整个账本。

0.5.0 就是个例子：只改了一处行为（手动顺延计账），但 `carried` 的含义变了，
所以是 `y` 不是 `z`。只改文案的那几处，跟着它一起发，不单独开号。

三条禁令，按它建号就不会出现"一天六个号"：

1. **一天最多一个号。** 修 bug 攒着，一个号装一批。
2. **唯一例外：发出去的包已经坏了**（装不上、打不开、数据写坏）——立刻换号，允许一天两次。
3. **号码只往大走。** 发出去就不撤回，有问题靠下一个号修，不靠删。

> **截至目前破例过一次，判据写在这里。** 0.4.0（编号归一）与 0.5.0（口径修正）
> 同在 2026-11-06 发出。理由不是"情况特殊"，而是禁令 1 的本意：
> **别让同一个体验官一天换两次包。** 0.4.0 发布时下载量是 0，没有任何人装过它，
> 所以体验官手上出现的第一个包仍然是 0.5.0。
> 判据是**下载量为零**，不是"我觉得急"。下次想破例，先去看下载量。

`CFBundleVersion` 是系统用来比新旧的整数，每次 **+1**，**永不回退**。
`CFBundleShortVersionString` 可以换形状（甚至重编号），它不行——
一旦回退，LaunchServices 会认为新包比已装的旧，覆盖安装不生效。

改 `Info.plist` 的两处：

```bash
grep -A1 "CFBundleShortVersionString\|CFBundleVersion" src/Info.plist
```

**0.4.0 之前的编号已作废，不在任何地方引用。** 那 6 个号是同一天 5 小时内打出来的，
把 `1.0.0` 当成了"功能齐了"——它的真实含义是"可以交给不看你代码的人"，当时一个外人都没有。
零下载时归一到 0.4.0，旧 release 与 tag 已删。写文档时不要回指旧号：
要说明某个行为是哪批加的，就写"0.4.0 那批"，不要写旧编号，否则读者会去找一个不存在的东西。

### 8.2 流程

```bash
# 0. 三闸全绿（缺一不发）
./tools/audit.sh && node tools/check.js

# 1. 升版本号（Info.plist 两处）+ 在 CHANGELOG.md 顶部加一节

# 2. 打包
./tools/dist.sh
shasum -a 256 dist/DeskTodo-<版本>.zip

# 3. 验证包里没有数据（每次都要跑）
rm -rf /tmp/pkgcheck && mkdir -p /tmp/pkgcheck
cd /tmp/pkgcheck && unzip -q <repo>/dist/DeskTodo-<版本>.zip
find . -name "*.json" | wc -l        # 必须是 0
ls 浮窗待办-<版本>/                   # 必须是 4 项：app / 安装.command / 读我.txt / 体验清单.md

# 4. 提交 + 推送
git add -A && git commit -m "..." && git push

# 5. 建 Release（附件名必须 ASCII）
gh release create v<版本> dist/DeskTodo-<版本>.zip --title "..." --notes-file /tmp/rel.md

# 6. 下载回验
curl -sL -o /tmp/dl.zip https://github.com/.../releases/download/v<版本>/DeskTodo-<版本>.zip
shasum -a 256 /tmp/dl.zip            # 必须和第 2 步一致
```

### 8.3 更新日志

`CHANGELOG.md` 是发版的一部分。**不许事后补写**：补写的日志只会记得住"改了什么文件"，
记不住"用户在哪里看得见"，而那才是唯一值得写的东西。

格式固定，没有例外：

```markdown
## 0.5.0 · 2026-11-06

**变了什么账：<一句话，人话>。**

### <功能域>

- <我能在哪里看见它>：<改了什么>，<为什么这样改>。

### 影响面

- 老数据怎么办、阈值变没变、谁需要做什么。
```

七条要求：

1. 标题只写 `版本号 · 日期`，**不写代号**。代号是发布会的装饰；0.x 每一号只是一次修正，
   起了名字反而让一个补丁听起来像里程碑。
2. 第一节必须是**一句人话**，说清这版到底变了什么账。
   「若干优化与修复」「提升稳定性」这类不算——它们可以套在任何一个版本上。
3. 功能域用固定的几个词：`记` / `划` / `结` / `稽` / `清单与顺延` / `报告` / `安装与数据` / `细节`。
   想造新词之前，先确认它不是已经有一个了。
4. 每条都要能被验证。写"打开欠账面板能看见三条"、"`lsof` 没有输出"；
   不写"优化了性能"、"体验更顺"——那是没人能核对的话，也是将来无法反驳的话。
5. 只写已发生的。不写"计划支持"、"下一步会"。
6. 修掉的问题要写**为什么它是问题**，不只写"修复了 X"。下一个改这段代码的人需要的是原因，
   不是一句已经完成的陈述。
7. Release 正文直接抄这一版的小节，不另写一份。两处文案一旦分家，早晚互相矛盾。

### 8.4 五个必须知道的坑

1. **附件名用 ASCII**。中文名会被 GitHub 整个替换成连字符（`-.-<版本>.zip`），谁也不敢下。
   zip **内部**的文件名照旧中文。
2. **`ditto` 要带 `--keepParent`**。不带的话打出来的是目录**内容**，
   四个文件散在「下载」里，用户不知道点哪个。
3. **沙箱里推不了 GitHub**，要走本机代理：
   `HTTPS_PROXY=http://127.0.0.1:7890 git -c http.version=HTTP/1.1 push`。
4. **`push` 报 `cannot lock ref` 时别急着重推**，先 `git ls-remote origin refs/heads/main`
   对一下——多半已经成功了，只是本地 remote-tracking ref 落后，`git fetch` 即可。
5. **撤掉发错的版本**：`gh release delete vX --yes --cleanup-tag`。
   发出去两小时内发现隐私缺陷时这么干，别"发个新版本算了"——
   中间那段时间里装的人不会知道。

---

## 9. 技术债（按优先级）

详细分析在 `docs/audits/2026-11-06.md`，这里只列清单：

| # | 债务 | 影响 |
|---|---|---|
| 1 | 月级投票入口太深（要 1-7 号 + 打开年轮） | 三层纠错里最深的一层几乎不可达 |
| 2 | `renderAgenda` 在渲染里 `persist()` | 结构隐患：空 state 覆盖磁盘的可能是"靠顺序"挡住的 |
| 3 | `byId` 线性扫描被用在循环里 → O(n²)，且 `refreshChips` 每秒跑 | 任务上千时每秒百万次比较 |
| 4 | `bumpProj` 用"现在"的项目归属退账 | 任务换过项目时占比失真 |
| 5 | ~~「最长连续」是下界但展示成确定值~~ | **已修**：区间内有看不见的日子时标 `≥` |
| 6 | `window.__load` 在 `08-anniv.js` | 位置误导，本该在 `01-core.js` |
| 7 | 无纯键盘路径 | 无障碍欠账 |

---

## 10. 文档规范（这份文档之所以存在）

### 10.0 目录怎么分

```
docs/
  MANUAL.md  DEVELOPMENT.md  POSITIONING.md  PRODUCT-BOUNDARY.md   长期文档，路径不动
  audits/YYYY-MM-DD.md            每一轮对抗性诊断各一份，按日期命名
  briefs/YYYY-MM-DD-<用途>.md      一次性任务书（给外部审阅者的），按日期命名
  images/                         文档里引用的图，文件名说明内容（today.png / year.png）
```

分法只有一条：**docs/ 根只放"随时会被人点开"的四份长期文档。**
带日期的文件会越攒越多，堆在根目录里，一年后光是列表就没人愿意看。
一次性材料（审阅任务书）用完就归档，不占根目录的位置。

命名规则：

| 类型 | 规则 | 例子 |
|---|---|---|
| 长期文档 | 全大写，讲清楚主题 | `PRODUCT-BOUNDARY.md` |
| 按日期产生 | 小写，日期在前 | `audits/2026-11-06.md` |
| 图片 | 说内容不说版本，换图不换名 | `images/year.png` |

图片**不带版本号**（不要 `window-0.5.0.png`）。界面变了就覆盖同一张，
否则一年后目录里躺着一堆过期截图，谁也不知道哪张是真的。

### 10.1 文档各管一件事

**同一件事只允许在一处写，别处只能引用。**

| 文档 | 只回答一个问题 | 不该出现的内容 |
|---|---|---|
| `README.md` | 这是什么、怎么装、怎么验证三条承诺 | 内部实现细节 |
| `CHANGELOG.md` | 每一版改了什么、为什么这么改 | 计划、路线图 |
| `docs/MANUAL.md` | 使用者每一步会看到什么、出问题怎么办 | 设计理由、代码 |
| `docs/POSITIONING.md` | 为什么是账本不是清单；新功能的准入标准 | 安装步骤、字段表 |
| `docs/PRODUCT-BOUNDARY.md` | 每一次取舍的决策记录（含被否决的方案） | 使用教程 |
| `docs/audits/2026-11-06.md` | 这一轮审出了什么、修了没、没修的为什么 | 长期稳定的规则 |
| `docs/briefs/2026-11-06-review.md` | （不属于产品文档）给外部审阅者的任务书与边界 | 产品自身的规则 |
| `CONTRIBUTING.md` | 提 PR 必须守什么、不可加清单 | 面向使用者的说明 |
| `SECURITY.md` | 威胁模型、它不防什么 | 功能清单 |
| `docs/DEVELOPMENT.md` | 代码怎么组织、改完怎么验、怎么发 | 产品定位 |

### 10.2 改代码时必须同步改的地方

| 你改了什么 | 必须同步 |
|---|---|
| 加/删一个统计口径 | `docs/DEVELOPMENT.md` 第 5 节 + `audit.sh` 第 6 项 |
| 加一个数据字段 | 第 4 节字段表 + `10-data.js` 的导出字段表 |
| 加一条断言或一个用例 | 第 7 节 + `README.md` / `CONTRIBUTING.md` / `PRODUCT-BOUNDARY.md` 里的条数 |
| 加一个菜单项 | `docs/MANUAL.md` 第 8 节 |
| 改一处界面文案 | `docs/MANUAL.md` 对应小节（要能逐字对上） |
| 改 `Info.plist` 权限 | `audit.sh` 第 3 项的白名单 + `SECURITY.md` |
| 升版本号 | `CHANGELOG.md` 顶部加一节 + `docs/MANUAL.md` 顶部"对应版本" |
| 改界面布局或主要画面 | `docs/images/` 对应截图重截（同名覆盖，不加版本号） |
| 加一个联网出口 | **不允许**。先读 `CONTRIBUTING.md` 的不可加清单 |

### 10.3 数字的唯一来源

文档里所有"多少行 / 多少条 / 多少个用例"都必须能复现：

```bash
cat src/*.swift | wc -l                    # Swift 行数
cat src/js/*.js | wc -l                    # JS 行数
wc -l src/styles.css src/index.html        # CSS / HTML
node tools/check.js | grep -c '^【'         # 用例数
node tools/check.js | grep -oE 'PASS [0-9]+' | awk '{s+=$2} END {print s}'   # 断言数
grep -cE '^echo "\[[0-9]\]' tools/audit.sh  # 审计项数
```

**不许写"约"。** 要么给准确数，要么写"以命令输出为准"。
上一版 README 写"页面（约 4700 行）"，实际是 3789——多报了 900 行。
数字虚报不会让产品更好，只会让读的人不再信这份文档。

### 10.4 写法三条

1. **同一句话不许有两种说法。** 例如"没记录 ≠ 0 件"，七份文档里必须是同一个说法、
   同一个反例（空心描边格）。
2. **承诺必须指向可执行的验证。** 写"不联网"就要给 `lsof` 命令；
   写"数据是明文"就要给 `open` 路径。给不出命令的承诺，删掉。
3. **不确定的写"未修"或"不知道"，不写模棱两可。** 本文档里"未修""没做""待验证"
   都是正式标记，不是客套。
