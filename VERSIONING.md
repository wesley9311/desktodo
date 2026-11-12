# 版本号规则

本文件是发布流程的唯一版本规则来源。`VERSION`、`src/Info.plist`、git tag、CHANGELOG、
CI 与发布脚本都以本文件为准；出现冲突时先改这里，再改代码。

## 0. 三个编号，各管一件事

| 编号 | 例子 | 管什么 | 谁生成 |
|---|---|---|---|
| 版本号（marketing version） | `0.1.1`、`0.2.0-rc.1` | 给人看：这一版变了什么 | 维护者按第 3 节判断 |
| 构建号（build number） | `2026111201` | 系统判断新旧、排序、唯一性；格式 `YYYYMMDDnn` | 发布时递增 |
| 数据格式版本（schemaVersion） | `2` | 账本 JSON 的结构；只由 `src/Storage.swift` 的 `storeSchemaVersion` 表示 | 改数据结构时升 |

三者互不替代：

- 构建号变大 **不代表** 数据兼容；
- 版本号是 `PATCH` **不代表** 可以改 `schemaVersion`；
- `schemaVersion` 变化必须走次版本（见第 3 节），并带迁移与回滚方案。

## 1. 版本号格式

```
MAJOR.MINOR.PATCH[-alpha.N|-beta.N|-rc.N]
```

- 数字段不允许前导零（`0.1.01` 非法）。
- `VERSION` 文件保存**完整**版本号（含预发布后缀，如果有）。
- `src/Info.plist` 的 `CFBundleShortVersionString` 保存**数字核心**
  （`MAJOR.MINOR.PATCH`，不含后缀）。
- git tag 保存 `v` + **完整**版本号：`v0.1.1`、`v0.2.0-rc.1`。
- `CHANGELOG.md` 条目标题用完整版本号：`## 0.1.1 · 2026-11-12`。

四同步的准确含义见第 6 节；`scripts/version-check.sh` 会机械校验上述映射。

## 2. 构建号格式与递增

- 格式：`YYYYMMDDnn`，10 位；`YYYYMMDD` 必须是真实日期，`nn` 为 `01`–`99`。
- 同一天多次发版用 `nn` 递增（`2026111201` → `2026111202`）。
- **单调递增**：新构建号必须严格大于所有既有 tag 的构建号（按数值比较，不是字符串）。
- **唯一**：任何两个 tag 不得使用同一个构建号；也不得复用曾经出现过的构建号。
- 构建号永不回退、永不重置（包括 0.x → 1.0.0）。
- 不要把构建号写进版本号、CHANGELOG 标题或 tag 名——它只属于 `CFBundleVersion`。

自动检查：

```bash
./tools/version-check.sh --mode auto
```

## 3. 升位判据

| 变什么 | 升哪一位 | 例子 |
|---|---|---|
| 架构重写、对外接口不兼容、老用户需要重新学 | 主版本 +1 | `1.2.0 → 2.0.0` |
| 新增一组连贯能力（3–5 个用户可见变化 + 一条故事线） | 次版本 +1，修正号归零 | `0.2.3 → 0.3.0` |
| 只修缺陷 / 安全 / 文案 / 打包，无新增能力 | 修正号 +1 | `0.3.0 → 0.3.1` |
| 只改数据格式（新增/删除/改写字段语义） | 次版本 +1，并带迁移与旧版只读说明 | `0.2.0 → 0.3.0` |
| 只重新打包 / 换签名 / 调构建配置，代码未变 | 见第 4 节（**发布前后规则不同**） | — |

### 0.x 的修正号例外

0.x 尚未承诺兼容，但 PATCH **不得改变数据格式/API/对外文件格式**。原“单个小功能”例外保留，
并收紧为：

- 不构成“一组连贯能力”（否则 MINOR +1）；
- 不改 `schemaVersion`、不改数据语义、不改对旧版/新版的文件约定；
- CHANGELOG 必须写进「新增」，不能混在「修复」里；
- 1.0.0 之后取消本例外。

0.1.1 只含缺陷修复，不使用本例外。

## 4. 同版本重签名 / 重新构建

这是旧规则最容易自相矛盾的地方，按“发布前/发布后”拆开：

### 4.1 发布前（tag 未创建、资产未上传）

- 允许同一版本号、递增构建号重新构建（换签名、调编译参数、修打包脚本）。
- 本地产物必须带 `-local` 后缀，不得冒充正式发行物（见第 7 节）。
- 不创建 tag、不上传资产。

### 4.2 发布后（tag 已推送或 Release 已存在）

- **版本号、tag、资产字节一律不可修改、不可复用。**
- 不能“同版本号 + 新构建号”重新发布：tag 不能移动，资产不能替换。
- 需要重签名/重打包才能修的问题，按下一个版本发布：
  - 修缺陷 → `PATCH` +1；
  - 预发布阶段 → 下一个后缀序号（`-rc.1` → `-rc.2`）；
  - 改数据格式 → `MINOR` +1。
- 唯一例外是“发布物损坏到无法安装”的 P0：仍然发新版本，不替换旧资产；旧 Release 可标记
  Pre-release 或改说明，但不删除、不改字节。

## 5. 预发布与正式版

- 预发布后缀序列：`-alpha.N` → `-beta.N` → `-rc.N`，同号内递增；同一后缀发布后不得重发。
- **去掉后缀才是正式版。** 正式版从 `1.0.0` 开始；0.x 的交付物是体验包，不叫正式版。
- 0.x 的 Release 一律勾 **Pre-release**；`latest` 只给正式版（`MAJOR >= 1` 且无后缀）。
- GitHub 的 `latest` 不能指向 Pre-release（API 会返回 422）。因此：
  - 0.x / `-alpha` / `-beta` / `-rc`：**不执行** `gh release edit --latest`；
  - 正式版发布后才执行 `gh release edit vX.Y.Z --latest`。
- 版本号中的后缀同时出现在 `VERSION`、CHANGELOG 标题、tag；`Info.plist` 只放数字核心，
  预发布身份由 tag + Release 的 Pre-release 标记表达。

## 6. 四同步与 CI

以下四处必须一致：

1. `VERSION` 文件（完整版本号）
2. `src/Info.plist` 的 `CFBundleShortVersionString`（数字核心）
3. `CHANGELOG.md` 最新条目标题（完整版本号）
4. git tag `v<完整版本号>`

补充约束：

- tag 必须指向 `main` 上的提交（发布后 main 可以继续前进，tag 作为祖先保留）。
- tag 必须是 annotated tag；tag 消息只写版本，不写构建号。
- `CFBundleVersion` 必须通过第 2 节的格式/递增/唯一检查。
- `schemaVersion` 必须在 `src/Storage.swift`；PATCH 不得改变它（见第 10 节检查）。
- CI 在 tag 构建时运行 `version-check.sh --mode tag`；在 main 的发布后复验运行
  `--mode main`（tag 作为祖先即可，**不再要求 tag == HEAD**）。

## 7. 追溯：本地构建 vs 正式发行物

| 类型 | 生成方式 | 命名 | 可否上传 Release |
|---|---|---|---|
| 本地构建 | `./tools/package.sh`（默认 `--channel local`） | `DeskTodo-<版本>-universal-local.dmg` | 否 |
| 正式发行物 | CI 从 tag 构建，`./tools/package.sh --channel release` | `DeskTodo-<版本>-universal.dmg` | 是 |

- `package.sh` 在 `dist/build-info.json` 记录 `version`、`build`、`channel`、`commit`、
  `dirty`、`toolchain`、`schemaVersion`、`createdAt`。
- `--channel release` 必须满足：工作区干净、HEAD 正好是 `v<版本>`、`version-check --mode tag` 通过。
- 本地构建即使版本号与已发布版相同，也因 `-local` 后缀而不会与正式资产混淆。
- Release 资产只允许来自 tag + CI；维护者本机不直接上传。
- Release 同时附 `build-info.json`（commit、toolchain、dirty、schemaVersion），与 dmg、SHA256SUMS 一起构成追溯三元组。

## 8. 不可变与历史

- 已发布的版本号不可修改、不可复用；发布后的资产不替换。
- 不删除、不移动、不重写已发布的 tag 与 Release（降级 Pre-release、改说明除外）。
- 发现历史缺失时：**记录事实**，不伪造；恢复需要维护者明确授权，且不得重写提交历史。
- 发布历史（tag、Release、资产 SHA-256）与 CHANGELOG 一样属于事实记录，不是营销材料。

## 9. 历史版本引用规则

旧规则“任何提交/文档/Release 不得引用历史版本号”会让 CHANGELOG、迁移说明、安全审计失去
可核对性，也会诱导删除真实历史。现在改为：

- **允许**在以下文件中准确引用历史版本号（必须带上下文，不得冒充当前版本）：
  - `CHANGELOG.md`
  - `VERSIONING.md`（本文件）
  - `SECURITY.md` 的兼容/受影响版本矩阵
  - `docs/MIGRATION*.md`、`docs/audits/**`
  - `README.md` / `docs/MANUAL.md` 的“历史/兼容”小节（仅限明确标注历史）
- **禁止**在面向当前用户的默认文案、当前版本文档、提交消息、tag 消息、Release 标题里
  把历史版本写成当前版本或“最新版”。
- 自动检查：`version-check.sh` 只允许上述文件出现非当前版本号；其他文件出现即失败。
- 历史版本号不得从 CHANGELOG 中删除来“通过扫描”。

## 10. 历史与重置（实际记录）

本仓库的版本序列在 0.1.0 重新起算，但**历史发布没有被抹掉**：

| 时间 | 事实 | 证据 |
|---|---|---|
| 2026-11-06 | 曾发布 `v0.4.0`（构建号 8）与 `v0.5.0`（构建号 9） | 本地 tag `v0.4.0` / `v0.5.0`；11-10 审计记录的 Release 下载数 4 / 3 |
| 2026-11-11 | 发布 `v0.1.0`（构建号 `2026111101`），当前序列从 0.1.0 起 | tag `v0.1.0`、Release、SHA256SUMS |
| 2026-11-12 | 复核时远端只剩 `v0.1.0`；远端 `v0.4.0` / `v0.5.0` 的 tag 与 Release 已不存在 | `git ls-remote --tags origin`、`gh release list`；本地 tag 仍在 |

- 上表是事实记录，不是“旧号作废”的营销话术；不据此删除任何仍存在的东西。
- 远端历史缺失属于治理事件：是否恢复由维护者授权；恢复时不得重写提交、不得改 0.1.0 资产。
- 构建号 8/9 与 2026111101 不连续，是重置的已知结果；0.1.1 起继续按第 2 节递增。

## 11. 保护配置（实际状态，2026-11-12 复核）

以下为 GitHub 实际配置，**不以文档声明代替**：

| 项 | 实际值 |
|---|---|
| `main` 分支保护 | force push 禁用、删除禁用；无 required status checks、无 required PR、无线性历史要求、admin 未强制 |
| tag 保护 / rulesets | 无 tag ruleset，无 tag protection（旧 API 404） |
| Release latest | 只有 `v0.1.0`，Pre-release；`latest` 未设置（也不该设置） |
| Actions 默认权限 | `contents: read`（release job 局部 `contents: write`） |

在补齐保护之前，发布纪律只能靠脚本与人工：`version-check.sh`、`release.sh`、CI。

## 12. 禁止事项

- 不修改、不替换已发布资产；不移动、不删除已发布 tag/Release。
- 不为通过版本扫描而删除 CHANGELOG/迁移/审计中的真实历史。
- 不在 0.x / 预发布上执行 `--latest`。
- 不用构建号代替数据兼容证明；不让 PATCH 改 `schemaVersion`。
- 不让本地构建冒充正式发行物；不把 `-local` 产物上传 Release。
- 不在提交消息、tag 消息、Release 标题中把历史版本写成当前版本。

## 13. 自动验证

```bash
./tools/version-check.sh --mode auto     # 本地/当前分支
./tools/version-check.sh --mode tag      # 在 tag 提交上
./tools/version-check.sh --mode main     # 发布后 main 复验（tag 祖先即可）
./tools/version-check.sh --check-github  # 额外读 GitHub 实际保护配置（只读）
```

`version-check.sh` 检查：版本格式、VERSION/Info.plist/CHANGELOG/tag 映射、构建号格式/日期/
递增/唯一、schemaVersion 的 PATCH 约束、历史版本引用范围、是否误用 latest。
