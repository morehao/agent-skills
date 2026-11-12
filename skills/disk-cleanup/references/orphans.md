# 卸载残留（orphans）

> 编码：`orphans`（**只报告，不参与自动清理**；删除只认 `--orphans-delete <路径>` 点名）。

## 编码归属：现状 → 终局

- **现状（v2）**：`orphans` 仍是独立编码且**只报告**——A 档过三路证明、B 档标低置信，两条都不自动删、不参与 `--all`。
- **终局**：保持只报告语义（启发式再严也不如人工确认，自动删的风险高于收益）。

---

## A/B 两档（先看置信度，再看清单）

只报告，但报告分两档——低置信的不能当高置信的用：

| 档 | 扫描范围 | 名字条件 | 活跃度 | 置信 |
|---|---|---|---|---|
| **A 档** | 只有 3 根：`~/Library/Caches`、`~/Library/Logs`、`~/Library/Saved Application State` | 反向域名 `^(com\|org\|net\|io)\.[A-Za-z0-9.-]+$` | 全树 ≥30 天无改动（`tree_active` 判假；树内只要有一个近期文件就算活跃，不进 A 档） | `confidence: high`，默认展示 |
| **B 档** | 其余 12 根（合计 15 个扫描根）：`~/Library/` 下的 `Application Support`、`Preferences`、`Containers`、`Group Containers`、`HTTPStorages`、`LaunchAgents`，以及 `/Library` 下的 `Application Support`、`Preferences`、`Caches`、`LaunchAgents`、`LaunchDaemons`、`PrivilegedHelperTools` | 反向域名，或与已装名单的匹配规则 | 按 `--orphans-age-days`（默认 30 天） | `confidence: low`，措辞必须是「需人工确认」 |

- A 档必须同时过下面的**三路归属证明**才进榜单；B 档不过证明，只按名字与已装名单反推。
- B 档**不计入「可删」总量**（`items[].deletable_kb` 不含它），也不给「一次全删」选项。
- 两档都只报告：`orphans` 不参与 `--all`，删除只认 `--orphans-delete` 点名。

## 反推机制（为什么只报告）

macOS 没有「谁装过什么」的台账，只能反推：

- **已装名单**：`/Applications`、`/System/Applications`、`~/Applications`、`/Library/Input Methods`、`~/Library/Input Methods` 下所有 `.app` 的 bundle id + 名称（`plutil` 读 `Info.plist`，不依赖 Spotlight 索引，关掉索引也能用）；
- **候选**：上面 A/B 两档扫描根里的**顶层**条目（不递归）；
- **残留**：既匹配不上已装名单、也不属于系统共用组件的条目——再按名字与活跃度过 A/B 分档。

匹配规则都在 `entry_is_installed`（命中 = 属于已装 App，不列为残留）：

| 规则 | 例子 |
|---|---|
| bundle id 完全相等，或是它的子 bundle | `com.tencent.xinWeChat` ↔ `com.tencent.xinWeChat.helper` |
| 条目以 id 的某一段开头（段长 ≥6，且不是 `desktop`/`helper` 这类通用段） | `bilibili` 对应 `com.bilibili.bilibiliPC`、`mihomo-party` 以 `mihomo` 开头 |
| 条目里的某一段就是 App 名/名字前缀 | `dev.orbstack.orbstack.privhelper` ⊃ OrbStack、`com.sogou.SogouTaskManager` ⊃ SogouInput |
| 名字相同 / 条目以 App 名开头 / 条目是 App 名的前缀（≥4 字符）/ 条目是 App 名的词 | `iTerm2` ⊃ iTerm、`LarkShell` ⊃ lark、`Sogou` ⊂ SogouInput、`Code` ⊂ Visual Studio Code |
| 同厂商的 helper/daemon | `party.mihomo.helper` ↔ `party.mihomo.app` |

## 三路归属证明（A 档必过）

名字像「反向域名」只说明它长得像个 App 目录，不说明 App 没了。A 档必须三条证据交叉验证，任何一条说不清就降到 B 档：

1. **运行中进程**：`app_bundle_ids_running` 取运行中 App 的 bundle id（`osascript` 查 System Events，被 TCC 拒时退到 `lsappinfo list`）。候选名命中运行中的 id 或它的子 id → 还有活的 App，不算残留。
2. **内嵌次级 id**：`embedded_bundle_ids <app>` 扫 `.app/Contents` 下的 xpc/appex/LoginItems/PlugIns 的 `Info.plist`。helper、更新器常与主 App 不同前缀，这一路专治 `com.microsoft.EdgeUpdater` 这类认不出来的名字。
3. **pkgutil receipts**：`pkg_apps` 从 `pkgutil --pkgs` + `--files` 找出装在 `/opt`、`/usr/local` 等非标准位置的 pkg App，补「只按标准位置取名单」的漏。

删除前也建议自己反查一次，比看目录名可靠：

```bash
mdfind "kMDItemCFBundleIdentifier == 'com.gitkraken.gitkraken'"   # 无输出 ≈ Spotlight 里没有这个 App
```

`mdfind` 非 0 退出表示**查询失败**，实现按「App 还在」处理（fail-closed）；不要把「查不到」当「没装」。

**为什么只报告、不自动删**：规则是启发式的，实测踩到过的误报——

- App 可以装在 `/Applications` 之外（例如项目目录里的 `Ollama.app`），脚本按标准位置取名单，会把它判成「已卸载」；
- 目录名与 App 名可能毫无关系（`GitKrakenCLI`、`app_shell_cache_6383`），也可能同名不同家；
- helper/更新器的 bundle id 未必与主 App 同厂商前缀（`com.microsoft.EdgeUpdater`、`com.openai.atlas`），只能猜；
- 漏报同样存在（目录名和 App 名都认不出来时）。

所以 `orphans` **不删任何东西**、也不参与 `--all`；删除必须按路径点名：

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh --orphans-list          # 1) 看完整清单（默认只展示最大的 15 项）
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --dry-run --only orphans \
  --orphans-delete "$HOME/Library/Application Support/GitKrakenCLI"     # 2) 预览
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only orphans \
  --orphans-delete "$HOME/Library/Application Support/GitKrakenCLI"     # 3) 执行
```

`--orphans-delete` 的路径在校验阶段就会被拦（任一不过 `exit 1`，且错误信息说明原因）：

1. 必须是绝对路径、**不接受尾斜杠**、不含 `..`/`.` 组件；
2. 必须**存在**，父目录可访问；
3. 不能指向扫描根本身，父目录必须是某个扫描根的**直接子项**；
4. 必须落在**本次扫描的候选集合**里（名字像残留不算，旧清单里的路径也不算）。

所以不要自己拼路径，也不要拿上一次的清单直接删——这中间可能已经装了 App。

`/Library` 下的条目（LaunchDaemons、PrivilegedHelperTools、Application Support）在候选里就标 `sudo: true`；当前环境拿不到 sudo 时该条被跳过，脚本会打印**可在用户终端重跑的同一条命令**（仍走同一漏斗），把命令原样交给用户。

**读不到大小写「未知」，不是 0**：`~/Library/Group Containers` 与部分 Container 受 TCC 保护，`du` 直接 `Operation not permitted`；报告里单独计数并写明未计入合计。

**置信度要带到报告里**：`--json` 的 `orphans` 条目给 `confidence`、`a_count`/`b_count`、`b_total_kb`、`unknown_size`、`age_days`，每个候选（`candidates[]`）再带 `tier: a|b`、`confidence`、`kb`、`age_days`、`sudo`、`size_unknown`。回执里如实写，别把 B 档的路径说成「确定是残留」；B 档不计入「可删」总量。

默认每档只展示最大的 15 个候选（`--orphans-list` 看全部），文本里也会说明「每档只显示最大的 15 项」——别把截断后的条数当成总量。

**与其它编码的边界**：`~/Library/Caches` 里已知的纯缓存/更新器（浏览器、`*updater*`、App Store）归 `caches`；`Homebrew`/`pnpm`/`go-build` 等工具缓存归对应工具编码（`homebrew`/`node`/`go`）；目录名恰好是 `$PATH` 上的命令（`codex`、`gk`）按 CLI 工具处理，不列为 App 残留。
