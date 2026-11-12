# macOS 系统级清理（非工具类）

> 覆盖编码：`caches`、`logs`、`tmp`、`varfolders`、`snapshots`、`trash`、`appcache`、`updaters`。这些是系统/应用层面的清理对象，不专属某个开发工具。

## 编码与策略

| 编码 | 覆盖对象 | 策略 / 阈值 | sudo | 删除后代价 |
|---|---|---|---|---|
| `caches` | `~/Library/Caches` | 纯缓存目录（浏览器/更新器/App Store）整删——Chrome 只删 `Google/Chrome` 子目录、不删整个 `Google`；其余只删 1 天前未改动的文件 | 否 | 应用首次打开变慢 |
| `logs` | `~/Library/Logs` | 只删 7 天前的文件，以及因此变空的旧目录（`find -delete` 的行为）；保留 `~/Library/Logs` 本身 | 否 | 基本无感 |
| `tmp` | `/private/tmp` | 只删 1 天前的陈旧内容 | **是** | 运行中程序的临时文件会重建 |
| `varfolders` | 当前用户 `/var/folders` 容器 | `T`/`C` 清 7 天以上；`X` 清 `*code_sign_clone*` 与 7 天前的顶层条目；`T/go-build*` 清 1 天前的顶层目录 | 否 | 无 |
| `snapshots` | Time Machine 本地快照 | 存在快照时 `tmutil thinlocalsnapshots / 999999999999 4` | **是** | 回滚粒度变粗，系统会重建 |
| `trash` | `~/.Trash` | 清空（含隐藏项，`-print0` 遍历） | 否 | **不可恢复** |
| `appcache` | `~/Library/Application Support/*/{Cache,GPUCache,Code Cache,CachedData,CachedExtensionVSIXs,Service Worker/CacheStorage,…}` | 整目录删，<10 MB 不入清单 | 否 | app 首次启动重建缓存；不动配置/登录态 |
| `updaters` | `crx_cache`、`auto-updater`、`app-recovery-cache`、`UpdateCache` | 整目录删，<10 MB 不入清单 | 否 | 重新下载更新包 |

## 编码归属：现状 → 终局

- **现状**：这 8 个编码本身就按「清理动作」划分，粒度合理，无需按工具拆分。
- **终局（第 2 期不涉及）**：保持不变。
- 说明：Go 的 `/var/folders/T/go-build*` 也在此编码，工具视角见 [tools/go.md](tools/go.md)；`Toolcache` 白名单里的浏览器/无头运行时缓存（`ms-playwright`、`Cypress`、`puppeteer`、`electron`、`codex-runtimes`）见下「其他可再生缓存」。

## 其他可再生缓存（归 `toolcache`）

以下不专属某门语言，按 `toolcache` 编码清理（见 [tools/node.md](tools/node.md) 的 `SAFE_CACHE_DIRS` 全表）：`~/Library/Caches/ms-playwright`、`~/Library/Caches/Cypress`、`~/Library/Caches/electron`、`~/.cache/puppeteer`、`~/.cache/codex-runtimes`。

## `tmp` 为什么走 `/private/tmp`

macOS 的 `/tmp` 是软链 → `private/tmp`，而 `find` **对作为起始点的软链默认不跟进**：

```bash
find /tmp  -mindepth 1 -maxdepth 1 | wc -l   # → 0     （旧写法，清理永久空转）
find /tmp/ -mindepth 1 -maxdepth 1 | wc -l   # → 非 0  （尾斜杠才对）
find /private/tmp -mindepth 1 -maxdepth 1 | wc -l   # → 非 0（与 /tmp/ 一致）
```

旧版本用 `find /tmp …` 删了但从没删到东西，还照样打「✅ 已执行」。现在统一用真实路径 `/private/tmp`。
给脚本加新路径时同理：起始点先确认不是软链。

## 纯缓存整删白名单

判据只有一条：**内容是仍可从服务端重新下载的副本**。目前覆盖
Edge / Chrome / Chromium / Brave / Vivaldi / Opera / Firefox / Safari、任何名字里带 `updater` 的目录、App Store 下载缓存。
这些目录不套 `mtime` 阈值——浏览器会持续 touch 缓存条目，套阈值等于清不动。

Chrome 的缓存在 `~/Library/Caches/Google/Chrome`，不在 `~/Library/Caches` 顶层，所以整删目标是 `Google` 下的
`Chrome` 子目录：**只整删 Chrome 缓存，不整删整个 `Google`**；不存在 `Chrome` 子目录时该条目按普通缓存走 mtime 阈值。
白名单键里保留了 `google`，删除时由 `cache_purge_targets` 展开成子目录。

**新增白名单必须在脚本里加（`is_purge_cache`；需要展开子目录时同步 `cache_purge_targets`），不要在任务里临时 `rm -rf` 不了解的路径。**

## `/var/folders` 为什么不能一把梭

这里混有当前用户与系统/其他用户的沙箱数据。脚本通过 `stat -f '%u'` 找出 **owner uid == 当前登录用户** 的那个容器目录（如 `/var/folders/_w/<hash>`），只清它下面的：

- `T` / `C`：7 天以上的过期缓存（`find -mindepth 1 -mtime +7 -delete`）；
- `X`：顶层 `*code_sign_clone*` 代码签名残留（应用更新会自动重建）与 7 天前的顶层条目，逐个 `rm -rf --`；
- `T/go-build*`：顶层 Go 编译缓存目录（1 天前），同样 `rm -rf --`。

「本次可删」按与删除谓词一致的口径量：`T`/`C` 用 `-type f` 求和，`X` 与 `go-build` 按**顶层条目** `du -sk` 求和，
避免「报的可删量与实际删除对不上」。

系统/他人沙箱（`_zz` 下的 WebKit、ScreenTime 等受 TCC 保护）会被跳过，既不误删，也不刷 `Operation not permitted` 噪音。

## 只报告、不代删（系统级大户）

判据：**删掉之后用户能不能自己恢复**。不可逆或含用户数据的 → 只报告，**不进勾选列表**。下列系统级项由脚本查询输出自动报告（只读段「只报告：系统级大户」；`--json` 里是 `reports[]`，读不到时 `kb=-1` 且 `note` 写「读不到（…）」，不影响退出码、不计入可删量）：

| 类别 | 典型路径 | 交给用户的方式 |
|---|---|---|
| iOS 设备备份 | `~/Library/Application Support/MobileSync/Backup` | Finder / iTunes「设备」里删旧备份 |
| 虚拟机/容器镜像 | `~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data` | OrbStack 内删 machine，或 `orb delete <machine>`；**不要**在 Finder 里删目录 |
| 浏览器配置 | `~/Library/Application Support/<Browser>` | 浏览器「清除浏览数据 → 缓存」 |
| 邮件 / 信息附件 | `~/Library/Mail`、`~/Library/Messages/Attachments` | 应用内删除 |
| 动态壁纸素材 | `~/Library/Application Support/com.apple.wallpaper/aerials` | 系统设置里换壁纸后由系统回收 |
| 崩溃转储 | `/cores` | root 属主；确认后交用户终端：`sudo rm -f /cores/core.*` |
| Apple Intelligence | `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_*`、`/private/var/db/AppleIntelligencePlatform`、`~/Library/Caches/com.apple.intelligence` | 系统托管，**只能看不能删**；入口「系统设置 → 通用 → 储存空间」 |
| 交换/睡眠镜像 | `/private/var/vm` | **不要手删**，系统自行回收 |
| 系统统一日志 | `/private/var/db/diagnostics`、`/private/var/db/uuidtext` | **不要手删**，系统自行轮转 |
| 系统更新暂存 | `/Library/Updates` | **不要动** |
| 应用体积 | `/Applications` | 只报告；卸载不需要的 App 由用户决定 |
| iCloud 本地副本 | `~/Library/Mobile Documents` | 应用内「移除下载」 |

只读探测（先量后说）：

```bash
du -sh ~/Library/Application\ Support/MobileSync/Backup 2>/dev/null
du -sh ~/Library/Containers/com.tencent.xinWeChat/Data/Documents 2>/dev/null
du -sh ~/Library/Group\ Containers/HUAQ24HBR6.dev.orbstack/data 2>/dev/null
du -sh ~/Library/Application\ Support/* 2>/dev/null | sort -hr | head -20
```

路径含空格必须加引号。给出具体数字时注明是**本次实测**——不同机器差异很大，别把某次快照当通用结论。
