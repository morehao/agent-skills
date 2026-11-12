# 卸载残留（orphans）

> 编码：`orphans`（**只报告，不参与自动清理**；删除只认 `--orphans-delete <路径>` 点名）。

## 编码归属：现状 → 终局

- **现状**：`orphans` 已是独立编码，但**只报告**——反推结果会误报，因此不自动删、不参与 `--all`。
- **终局（第 2 期不涉及）**：保持只报告语义（启发式不可靠，自动删风险高于收益）。

---

## 反推机制（为什么只报告）

macOS 没有「谁装过什么」的台账，只能反推：

- **已装名单**：`/Applications`、`/System/Applications`、`~/Applications`、`/Library/Input Methods`、`~/Library/Input Methods` 下所有 `.app` 的 bundle id + 名称（`plutil` 读 `Info.plist`，不依赖 Spotlight 索引，关掉索引也能用）；
- **候选**：`ORPHAN_ROOTS` 里的**顶层**条目（不递归，共 14 个扫描根）：

```text
~/Library/Application Support
~/Library/Caches
~/Library/Preferences
~/Library/Containers
~/Library/Group Containers
~/Library/HTTPStorages
~/Library/Logs
~/Library/LaunchAgents
/Library/Application Support
/Library/Preferences
/Library/Caches
/Library/LaunchAgents
/Library/LaunchDaemons
/Library/PrivilegedHelperTools
```

- **残留**：既匹配不上已装名单、也不属于系统共用组件的条目。

匹配规则都在 `entry_is_installed`（命中 = 属于已装 App，不列为残留）：

| 规则 | 例子 |
|---|---|
| bundle id 完全相等，或是它的子 bundle | `com.tencent.xinWeChat` ↔ `com.tencent.xinWeChat.helper` |
| 条目以 id 的某一段开头（段长 ≥6，且不是 `desktop`/`helper` 这类通用段） | `bilibili` 对应 `com.bilibili.bilibiliPC`、`mihomo-party` 以 `mihomo` 开头 |
| 条目里的某一段就是 App 名/名字前缀 | `dev.orbstack.orbstack.privhelper` ⊃ OrbStack、`com.sogou.SogouTaskManager` ⊃ SogouInput |
| 名字相同 / 条目以 App 名开头 / 条目是 App 名的前缀（≥4 字符）/ 条目是 App 名的词 | `iTerm2` ⊃ iTerm、`LarkShell` ⊃ lark、`Sogou` ⊂ SogouInput、`Code` ⊂ Visual Studio Code |
| 同厂商的 helper/daemon | `party.mihomo.helper` ↔ `party.mihomo.app` |

**为什么只报告、不自动删**：规则是启发式的，实测踩到过的误报——

- App 可以装在 `/Applications` 之外（例如项目目录里的 `Ollama.app`），脚本按标准位置取名单，会把它判成「已卸载」；
- 目录名与 App 名可能毫无关系（`GitKrakenCLI`、`app_shell_cache_6383`），也可能同名不同家；
- helper/更新器的 bundle id 未必与主 App 同厂商前缀（`com.microsoft.EdgeUpdater`、`com.openai.atlas`），只能猜；
- 漏报同样存在（目录名和 App 名都认不出来时）。

所以 `orphans` **不删任何东西**、也不参与 `--all`；删除必须按路径点名：

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh --orphans-list          # 1) 看完整清单（含 --json 的 candidates）
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --dry-run --only orphans \
  --orphans-delete "$HOME/Library/Application Support/GitKrakenCLI"     # 2) 预览
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only orphans \
  --orphans-delete "$HOME/Library/Application Support/GitKrakenCLI"     # 3) 执行
```

删除前建议反查「这个 id 是不是真的没有 App 了」，比看目录名可靠：

```bash
mdfind "kMDItemCFBundleIdentifier == 'com.gitkraken.gitkraken'"   # 无输出 = Spotlight 里没有这个 App
```

`/Library` 下的条目（LaunchDaemons、PrivilegedHelperTools、Application Support）要 sudo，agent 环境会被跳过并打印 `sudo rm -rf …` 原文，交给用户终端。

**读不到大小写「未知」，不是 0**：`~/Library/Group Containers` 与部分 Container 受 TCC 保护，`du` 直接 `Operation not permitted`；报告里单独计数并写明未计入合计。

**与其它编码的边界**：`~/Library/Caches` 里已知的纯缓存/更新器（浏览器、`*updater*`、App Store）归 `caches`；`Homebrew`/`pnpm`/`go-build` 等工具缓存归 `toolcache`/`bigbuild`；目录名恰好是 `$PATH` 上的命令（`codex`、`gk`）按 CLI 工具处理，不列为 App 残留。
