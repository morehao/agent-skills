# 清理对象与执行方式

macOS 本机磁盘是主战场：系统缓存、日志、临时文件、Time Machine 快照、开发工具缓存通常就是大头；
**项目层**（node_modules、构建产物、`.dsh/tmp` 过程产物、Go/pnpm 编译缓存）与**应用内缓存**（Electron 壳 app 自己的 Cache）往往比系统缓存更大；
本地数据库（如 opencode）属于「个别应用数据膨胀」，在同一套流程里按对象处理，不单开一条线。

## 一、macOS 磁盘（`scripts/mac_cleanup.sh`）

### 模式语义（先看懂再跑）

| 模式 | 行为 | 什么时候用 |
|---|---|---|
| 无参数 | **只查询**：统计并打印各目录占用，不删任何东西 | 用户选择「只看占用」或「选勾清理」后先跑这个 |
| `--list` | 只打印清理项编码与说明（`--list --json` 为机器可读版） | 核对勾选结果与编码 |
| `--top [N]` | 只读：列出 `$HOME` 下最大的 N 个目录与 >100 MB 文件 | 用户问「什么最占地方」 |
| `--clean --dry-run [--only ids]` | 打印每项的计划命令与预计可删量，不实际删除；**必须搭配 `--clean`**，单独使用时 `--dry-run` 不生效（按查询模式运行） | 勾选后、执行前自查 |
| `--clean --only ids` | 只执行勾选的清理项 | 用户勾选完成后 |
| `--clean --all` | 执行全部清理项 | **只允许用户本人在终端手动使用** |
| `--orphans-list` | 只读：显示**全部**疑似卸载残留（默认只显示最大的 15 项） | 用户问「哪个 App 卸了还留着东西」 |
| `--clean --only orphans --orphans-delete <路径>` | 只删点名的路径（可重复传）；路径须存在、是扫描根直接子项且在本次候选里 | 用户挑完具体残留后 |
| `--json` | stdout 只输出 JSON（进度信息与外部命令输出走 stderr；结构见「`--json` 输出结构」） | agent 需要结构化结果时 |

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh                                       # 1) 清单
bash skills/disk-cleanup/scripts/mac_cleanup.sh --top 10                              # 2) 谁最占地方
bash skills/disk-cleanup/scripts/mac_cleanup.sh --list                                # 3) 编码
bash skills/disk-cleanup/scripts/mac_cleanup.sh --json                                # 4) 结构化
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --dry-run --only caches,trash  # 5) 自查
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only caches,trash            # 6) 执行
bash skills/disk-cleanup/scripts/mac_cleanup.sh --orphans-list                        # 7) 卸载残留全清单
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --dry-run --only orphans \
  --orphans-delete "$HOME/Library/Application Support/Foo"                            # 8) 残留预览/执行
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --dry-run --only dshtmp,projectcache  # 9) 项目内过程产物/编译缓存
```

> `--dry-run` 只在 `--clean` 下生效（单独使用时 `--dry-run` 不生效，按查询模式运行）；`--only/--skip` 不带 `--clean` 也不生效（脚本会提示仍是只读查询）。
> 编码写错时脚本直接 `exit 1` 并列出可用编码——避免「以为清了其实没清」。
> 退出码：`0` 成功（含未勾选任何项）/ `1` 有 `partial`/`failed` 项，或参数、`--orphans-delete` 路径校验失败 / `2` `--clean` 缺 `--only/--skip/--all`（防盗清全部的手刹）。

### 选择语义（用户勾选怎么落到命令）

- `--only a,b,c`：**只跑列出的项**，其余每步打印 `[跳过]`，报告里汇总为「未勾选（未执行）」。重复传 `--only` 会合并，不会互相覆盖。
- `--skip a,b`：排除指定项；与 `--only` 同给时，先取 `--only` 再减 `--skip`。同样支持重复传。
- 两个都不给 = 必须配 `--all`。**agent 代跑时必须显式给 `--only`**，这就是「最终清理项由用户决定」的落地方式。
- 编码是**勾选单位，不能拆到编码内部**：例如 `bigbuild` 里 Homebrew 与 Gradle 同进同出。用户只想清其中一项时，只能该项整组不勾、由用户自己在终端跑那条具体命令；**不要**为了满足粒度在任务里临时 `rm -rf`。
- 组合示例：`--clean --skip docker,bigbuild --only caches,logs`。

### 参数与默认值

| 参数 | 默认 / 说明 |
|---|---|
| `--clean` | 执行实际清理；不带它一律只查询 |
| `--dry-run` | 只打印计划命令与预计可删量；**需搭配 `--clean`**，单独使用不生效（按查询模式运行） |
| `--only <ids>` / `--skip <ids>` | 只跑 / 排除指定编码，英文逗号分隔；均可重复传、会合并；两者同给时先取 `--only` 再减 `--skip` |
| `--all` | 显式全清；`--clean` 不带 `--only/--skip` 时必须加，否则 exit 2；agent 侧不用（见 SKILL.md 铁律） |
| `--list` / `--list --json` | 列出编码与说明（机器可读版）后退出 |
| `--top [N]` | 只读：列出 `$HOME` 下最大的 N 个目录与 >100 MB 文件（默认 10，较慢） |
| `--json` | stdout 只输出 JSON，进度与外部命令输出走 stderr |
| `--cache-age-days N` | `caches` 与 `tmp` 的 mtime 阈值，默认 1 天 |
| `--log-age-days N` | `logs` 的 mtime 阈值，默认 7 天 |
| `--projects-age-days N` | `projects` 的年龄阈值，默认 30 天 |
| `--dshtmp-age-days N` | `dshtmp` 的年龄阈值，默认 0 天（= 全部可删） |
| `--projectcache-age-days N` | `projectcache` 的年龄阈值，默认 3 天 |
| `--projects-roots <p>` | `projects`/`dshtmp`/`projectcache` 的扫描根，默认 `~/Documents`；可用冒号分隔多个 |
| `--projects-keep <p>` | 排除具体项目路径（可重复传），三个项目类编码都生效 |
| `--orphans-list` | 只读：显示全部疑似残留（默认只显示最大的 15 项） |
| `--orphans-age-days N` | 残留报告的年龄过滤，默认 0（= 不限年龄） |
| `--orphans-delete <p>` | 要删除的残留路径（可重复传）；校验规则见下 |
| `--help` / `-h` | 打印用法 |

五个 `*-age-days` 参数都支持 `--flag=value` 等号形式：`--cache-age-days=N`、`--log-age-days=N`、`--projects-age-days=N`、`--dshtmp-age-days=N`、`--projectcache-age-days=N`；值必须是非负整数，否则 `exit 1`。

`--orphans-delete` 的路径校验（任一不满足即 `exit 1`，错误信息会说明原因）：

1. 必须是绝对路径，且**不接受尾斜杠**；
2. 不含 `..`、`.` 组件（字符串预检，快速失败）；
3. 用真实路径归一化后，必须是某个扫描根（`ORPHAN_ROOTS`）的**直接子项**，不能等于扫描根本身；
4. 必须存在于**本次扫描的候选集合**里（不是「名字看着像残留」就能删）；
5. 命中 `/Library` 下的路径时走 sudo（见「权限与 sudo 交接」）。

### `--json` 输出结构

stdout 是**单个** JSON 对象（`--clean` 下外部命令输出一律走 stderr，可直接 `JSON.parse`）；`--list --json` 是另一套 `codes` 结构，不在这里。

```json
{
  "schema": 1,
  "mode": "query | dry-run | clean",
  "disk": {
    "free_before_kb": 0,
    "free_after_kb": 0,
    "freed_kb": 0,
    "estimated_freed_kb": 0,
    "df_delta_kb": 0
  },
  "exit_code": 0,
  "failed_count": 0,
  "codes": [
    {"id": "bigbuild", "status": "done", "total_kb": 0, "deletable_kb": 0, "items": 7}
  ],
  "reports": [
    {"id": "cores", "label": "崩溃转储", "kb": 0, "note": "…"}
  ],
  "items": [
    {"id": "caches", "label": "…", "status": "queried", "total_kb": 0,
     "deletable_kb": 0, "path": "…", "note": "…"}
  ]
}
```

- `codes[]`：按编码聚合的视图（`items[]` 里同一编码可能因分步执行有多条，如 `bigbuild`、`toolcache`）：`total_kb`/`deletable_kb` 求和、`items` 是出现次数；`status` 取最严重（`failed` > `partial` > `done` > `dry-run` > `reported` > `queried` > `skipped-sudo` > `skipped-unselected`），顺序按编码首次出现；
- `reports[]`：只报告段的机器可读视图（`/cores`、`/Applications` 等系统级大户），每项 `{id,label,kb,note}`；**`kb=-1` 表示读不到**（不是 0）；不进 `items[]`、不计入可删量、不影响退出码；

- `freed_kb`：只有 `--clean` 且非 `--dry-run` 时等于 `estimated_freed_kb`；**查询/预览恒为 0**；
- `estimated_freed_kb`：本次状态为 `done` 的项，其 `deletable_kb` 之和；`partial`/`failed` 不计入（实际删除量无法确认）；
- `df_delta_kb`：前后 `df` 差值，**始终**给出，作为旁证（含系统自身回收、其它进程写入等噪声，不能当成清理成果）；
- `exit_code`：与进程退出码一致（JSON 只在通过手刹校验后输出，所以这里是 `0` 或 `1`；`2` 的情况见上，此时没有 JSON）；`failed_count`：状态为 `partial`/`failed` 的项数，`exit_code=1` 时至少为 1；
- `items[].status` ∈ `queried` / `dry-run` / `skipped-unselected` / `skipped-sudo` / `done` / `partial` / `failed`（`orphans` 另有 `reported`）；同一编码可能因分步执行出现多条（如 `bigbuild`、`toolcache`），要按编码汇总用 `codes[]`（见上）；
- `items[].total_kb` / `deletable_kb` 是 KB 整数。

### 两个口径：目录总量 ≠ 本次可删量

报告里每项都给两个数字，**回执必须都写**：

- **目录总量**：`du -sk <path>`，这目录有多大；
- **本次可删量**：按该项自己的阈值/白名单实测出来「这次真的会删掉多少」。

为什么必须分开：`caches` 只删 1 天前的未知应用缓存，而浏览器会持续 touch 缓存条目。实测一台机器上
`~/Library/Caches` 总量 2.3 GB，套 `mtime +1` 只剩 210 MB 可删——只报 2.3 GB 就是帮用户虚报收益。
因此脚本对**已知纯缓存目录**（浏览器、更新器、App Store 下载）改成整目录清理、不套阈值，可删量才回到 GB 级。

测量细节（改脚本时别踩）：

- 可删量用 `find -type f -mtime +N -exec du -k {} +` 求和，**只统计文件**。
  对 `-mindepth 1 -mtime +N` 的**目录**求和会连同子树重复计入（曾算出「可删 3.4G > 总量 2.3G」）。
- 硬链接按条目各计一次，结果为近似值；对缓存场景够用，别当成精确值对外承诺。
- 遍历被 TCC/权限拒绝的条目（Safari、CloudKit、HomeKit 等）单独计数，报告里写「N 个受保护子目录未计入」，**不当成 0**（`caches`/`logs` 两项各报一次；其它编码不做这项计数）。

### 清理项编码

| 编码 | 覆盖对象 | 策略 / 阈值 | sudo | 删除后代价 |
|---|---|---|---|---|
| `caches` | `~/Library/Caches` | 纯缓存目录（浏览器/更新器/App Store）整删——Chrome 只删 `Google/Chrome` 子目录、不删整个 `Google`；其余只删 1 天前未改动的文件 | 否 | 应用首次打开变慢 |
| `logs` | `~/Library/Logs` | 只删 7 天前的文件，以及因此变空的旧目录（`find -delete` 的行为）；保留 `~/Library/Logs` 本身 | 否 | 基本无感 |
| `tmp` | `/private/tmp` | 只删 1 天前的陈旧内容 | **是** | 运行中程序的临时文件会重建 |
| `varfolders` | 当前用户 `/var/folders` 容器 | `T`/`C` 清 7 天以上；`X` 清 `*code_sign_clone*` 与 7 天前的顶层条目；`T/go-build*` 清 1 天前的顶层目录 | 否 | 无 |
| `snapshots` | Time Machine 本地快照 | 存在快照时 `tmutil thinlocalsnapshots / 999999999999 4` | **是** | 回滚粒度变粗，系统会重建 |
| `trash` | `~/.Trash` | 清空（含隐藏项，`-print0` 遍历） | 否 | **不可恢复** |
| `xcode` | Xcode `DerivedData` | 整个删掉 | 否 | 下次构建全量重编 |
| `toolcache` | 语言工具链/包管理器白名单 + `pnpm store prune` | 删目录（只读缓存先 `chmod -R u+w`）；pnpm 只回收未引用包 | 否 | 重新下载/编译 |
| `bigbuild` | ipsw、Homebrew、CocoaPods、Gradle、iOS DeviceSupport、CoreSimulator/Caches、不可用模拟器 | 删目录；`brew cleanup --prune=all` + `autoremove`；`xcrun simctl delete unavailable` | 否 | 重新下载/构建；Homebrew 旧版本不能回滚 |
| `docker` | 未使用镜像、停止的容器、构建缓存、未用网络 | `docker system prune -a --force` | 否 | 镜像要重新 pull；**Docker.raw 不缩小** |
| `appcache` | `~/Library/Application Support/*/{Cache,GPUCache,Code Cache,CachedData,CachedExtensionVSIXs,Service Worker/CacheStorage,…}` | 整目录删，<10 MB 不入清单 | 否 | app 首次启动重建缓存；不动配置/登录态 |
| `updaters` | `crx_cache`、`auto-updater`、`app-recovery-cache`、`UpdateCache` | 整目录删，<10 MB 不入清单 | 否 | 重新下载更新包 |
| `projects` | `--projects-roots`（默认 `~/Documents`）下的 `node_modules`、`dist`、`build`、`.next`、`.turbo`、`.venv`、`target`、`Pods` 等 | 只处理 ≥ `--projects-age-days`（默认 30 天）未改动的目录，<50 MB 不入清单；mtime 读不到则跳过（不当成 0 天可删） | 否 | 需重新 install/build |
| `dshtmp` | 项目内 `**/.dsh/tmp` 过程产物（只在 `--projects-roots` 下扫） | 只清空内容、**保留 `.dsh/tmp` 目录本身**；`--dshtmp-age-days`（默认 0 天 = 全部可删）；<10 MB 不入清单；`docs/` 不动 | 否 | 过程产物消失，需要时重新生成 |
| `projectcache` | 项目内编译缓存：`.gocache`、`.tmp-gocache`、`.dsh/gocache`、`.pnpm-store`、`.corepack` | 整目录删；`--projectcache-age-days`（默认 3 天）；<50 MB 不入清单 | 否 | 下次构建/install 重跑 |
| `orphans` | 已卸载 App 留在 `~/Library`、`/Library` 的目录（Application Support / Preferences / Containers / Group Containers / HTTPStorages / LaunchAgents 等） | **只报告**：反推已装 App 名单后列出疑似项；删除只认 `--orphans-delete` 点名、且在本次候选里的路径 | 部分（`/Library` 下） | 删的是该 App 的配置/缓存/许可数据，不可恢复 |

#### `tmp` 为什么走 `/private/tmp`

macOS 的 `/tmp` 是软链 → `private/tmp`，而 `find` **对作为起始点的软链默认不跟进**：

```bash
find /tmp  -mindepth 1 -maxdepth 1 | wc -l   # → 0     （旧写法，清理永久空转）
find /tmp/ -mindepth 1 -maxdepth 1 | wc -l   # → 非 0  （尾斜杠才对）
find /private/tmp -mindepth 1 -maxdepth 1 | wc -l   # → 非 0（与 /tmp/ 一致）
```

旧版本用 `find /tmp …` 删了但从没删到东西，还照样打「✅ 已执行」。现在统一用真实路径 `/private/tmp`。
给脚本加新路径时同理：起始点先确认不是软链。

#### 纯缓存整删白名单

判据只有一条：**内容是仍可从服务端重新下载的副本**。目前覆盖
Edge / Chrome / Chromium / Brave / Vivaldi / Opera / Firefox / Safari、任何名字里带 `updater` 的目录、App Store 下载缓存。
这些目录不套 `mtime` 阈值——浏览器会持续 touch 缓存条目，套阈值等于清不动。

Chrome 的缓存在 `~/Library/Caches/Google/Chrome`，不在 `~/Library/Caches` 顶层，所以整删目标是 `Google` 下的
`Chrome` 子目录：**只整删 Chrome 缓存，不整删整个 `Google`**；不存在 `Chrome` 子目录时该条目按普通缓存走 mtime 阈值。
白名单键里保留了 `google`，删除时由 `cache_purge_targets` 展开成子目录。

**新增白名单必须在脚本里加（`is_purge_cache`；需要展开子目录时同步 `cache_purge_targets`），不要在任务里临时 `rm -rf` 不了解的路径。**

#### `toolcache` 白名单

```text
~/.npm/_npx
~/.npm/_cacache
~/.npm/_logs
~/.cache/uv
~/.cache/puppeteer
~/.cache/node
~/.cache/codex-runtimes
~/.cache/opencode
~/.cache/yarn
~/.cache/bun
~/.bun/install/cache
~/.cargo/registry/cache
~/go/pkg/mod/cache/download
~/.m2/repository
~/Library/Caches/go-build
~/Library/Caches/goimports
~/Library/Caches/gopls
~/Library/Caches/golangci-lint
~/Library/Caches/ms-playwright
~/Library/Caches/Cypress
~/Library/Caches/Yarn
~/Library/Caches/pip
~/Library/Caches/node-gyp
~/Library/Caches/electron
~/Library/Caches/Homebrew
~/Library/pnpm/package-manager-store   （pnpm 工具版本仓库，store prune 不管它）
```

新增缓存目录必须改脚本里的 `SAFE_CACHE_DIRS`（`package-manager-store` 由 `PNPM_PMS` 单独处理）；
`--json`/`--list` 之外不要在任务里自行 `rm -rf` 白名单外的路径。

#### `projects`：项目层清理的边界

- 只在 `--projects-roots`（默认 `~/Documents`，可用冒号分隔多个）下扫描，**不进 git 仓库外的任意路径**；
- `-maxdepth 6` + `-prune`，命中 `node_modules` 后不再往里钻；
- 按**构建产物目录自身的 mtime** 判新旧：≥ `--projects-age-days`（默认 30）天未改动才列为可删，近期动过的直接跳过并在报告里标「N 天内有改动」；
- 用户要保住某个项目：`--projects-keep <绝对路径>`（可重复传）；
- 报告要给「路径 + 大小 + 多少天未改动」，用户据此勾选；删除后需要重新 install/build，必须写进回执；
- `dist`/`build` 这类名字在非项目目录也可能出现，所以阈值与根目录限制不能放宽成「全盘扫」。

#### `dshtmp` / `projectcache`：项目内的过程产物与编译缓存

两者与 `projects` 共用扫描根（`--projects-roots`，默认 `~/Documents`，可冒号分隔多个）与排除名单（`--projects-keep`），
都是 `-maxdepth 7` + `-prune`，都只处理可再生数据：

- **`dshtmp`**：只命中 `*/.dsh/tmp`，**只清空内容、保留 `.dsh/tmp` 目录本身**；同级的 `~/Documents/**/.dsh/docs`
  是用户文档，**不动**。删除前先 `chmod -R u+w`（Go 模块缓存等只读条目），删后回读确认目录仍在且为空。
  `<10 MB` 不进清单；`--dshtmp-age-days`（默认 0 天）为 0 表示全部可删，`N>0` 时只删 ≥ N 天未改动的，其余标「N 天内有改动，跳过」。
- **`projectcache`**：命中 `.gocache`、`.tmp-gocache`、`.dsh/gocache`、`.pnpm-store`、`.corepack`，整目录删
  （`node_modules/.pnpm-store` 也会被 `-name .pnpm-store` 命中，属预期）。`<50 MB` 不进清单；
  `--projectcache-age-days`（默认 3 天）才判定年龄，删除同样先 `chmod -R u+w`。
- 删除代价：过程产物消失后需要时重新生成；编译缓存没了下次构建/install 重跑，可再重建，不影响源码。

#### `orphans`：已卸载应用的残留（反推，只报告）

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

#### `--top`：最占空间清单

只读，不进勾选清单，用来回答「看看什么最占地方」：`du -sk $HOME/*` 取目录 Top N，`find $HOME -xdev -type f -size +100M` 取文件 Top N。
它要全量遍历 `$HOME`，实测 160G 的机器约 3 分半——只在用户问「谁最占地方」时用，不要塞进常规测量步骤。
输出给用户后，可再生的大户映射到对应编码（缓存/构建产物），用户数据（聊天记录、虚拟机镜像、设计稿、iCloud）走「只报告不代删」。

### 权限与 sudo 交接

sudo 范围有**三类**：`tmp`、`snapshots`，以及 `--orphans-delete` 命中 `/Library` 下的残留（`is_sudo_path`）。

脚本只在**所选清理项包含 `tmp`/`snapshots`（或 `--orphans-delete` 命中 `/Library` 下路径）且要真实执行**时
才 `sudo -v` 预取权限；失败则打印告警并**跳过**这些步骤，命令原文写进报告，其余步骤照常。

脚本刻意不创建临时文件（`usage`/`list` 用 `printf` 而非 here-doc，循环用进程替换而非 here-string）：
只读沙箱、`TMPDIR` 不可写的环境里也能跑完查询。旧版用 here-doc，实测在只读沙箱里连 `--help` 都会报
`cannot create temp file for here document`。

agent 环境没有 TTY，这一步必然失败——这是设计内的降级，不是 bug。正确做法：

1. 用只读模式出报告；
2. 把需要 sudo 的清理命令原文交给用户，让他在自己的终端跑；
3. 用户跑完再回来复测。

```bash
# 交给用户终端执行（只含 sudo 项）
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only tmp,snapshots

# /Library 下的卸载残留：按用户点名的路径交终端（先 dry-run 核对）
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --dry-run --only orphans \
  --orphans-delete "/Library/Application Support/<Foo>"
```

### 沙箱权限与 sudo 同级

agent 若跑在 `workspace-write` 类沙箱里，**工作区之外的删除会被直接拒绝**（`$HOME` 下不少路径、`/Library`、`/private/tmp`
都不在工作区内），报错通常是 `Operation not permitted` 而不是 `Permission denied`。脚本用「预检 + 沙箱疑似」决定
`Operation not permitted`（EPERM）算不算失败：

- **正常终端**（预检未命中：`$HOME/Library` 与 `$HOME/.Trash` 都可写）：按 mtime 阈值 `find -delete`/整删的项
  （`caches`、`logs`、`varfolders`，以及复用同一 helper 的 `tmp`、`snapshots`）里出现 EPERM 视为 **TCC 已知跳过**，
  不计失败（仍会单独报「N 个受保护子目录未计入」）；其它编码（`trash`、`xcode`、`toolcache`、`appcache`、`updaters`、
  `projects`、`projectcache`、`dshtmp`、`orphans`）的 `rm` 失败**仍计失败** → 该项 `partial`、进程 exit 1（见「退出码」）。
- **沙箱疑似**（预检发现 `$HOME/Library` 或 `$HOME/.Trash` 不可写）：EPERM **不再当 TCC 跳过**，一律计入失败
  → `partial`/`failed` + exit 1，避免「沙箱把删除全拦了还报 done」。
- 两种情形都要：**改用可写沙箱执行**，或把命令原文交给用户在自己的终端跑（和 sudo 的交接方式一样）；
  不要反复重试，也不要把 `sudo` 当成沙箱权限的替代（agent 环境没有 TTY，`sudo -v` 同样会失败）。

脚本在报告开头做这次只写预检（`$HOME/Library`、`$HOME/.Trash`），疑似沙箱时打印告警；预检只影响失败归类，
不单独改变退出码。

### `/var/folders` 为什么不能一把梭

这里混有当前用户与系统/其他用户的沙箱数据。脚本通过 `stat -f '%u'` 找出 **owner uid == 当前登录用户** 的那个容器目录（如 `/var/folders/_w/<hash>`），只清它下面的：

- `T` / `C`：7 天以上的过期缓存（`find -mindepth 1 -mtime +7 -delete`）；
- `X`：顶层 `*code_sign_clone*` 代码签名残留（应用更新会自动重建）与 7 天前的顶层条目，逐个 `rm -rf --`；
- `T/go-build*`：顶层 Go 编译缓存目录（1 天前），同样 `rm -rf --`。

「本次可删」按与删除谓词一致的口径量：`T`/`C` 用 `-type f` 求和，`X` 与 `go-build` 按**顶层条目** `du -sk` 求和，
避免「报的可删量与实际删除对不上」。

系统/他人沙箱（`_zz` 下的 WebKit、ScreenTime 等受 TCC 保护）会被跳过，既不误删，也不刷 `Operation not permitted` 噪音。

### pnpm 走 corepack + 两套 store

裸 `pnpm` 在部分环境里是 Corepack shim，一调用可能因项目声明版本与缓存不一致触发「Corepack is about to download…」交互弹窗。脚本在 `corepack` 存在时用 `COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack pnpm store prune` 复用已有版本；`corepack` 缺失时回落到裸 `pnpm store prune`（并说明走了回落）。只有 `pnpm` 存在时才执行这一步。

pnpm 现在有**两套存储**：`~/Library/pnpm/store`（包内容，`store prune` 回收未引用）与
`~/Library/pnpm/package-manager-store`（pnpm 自己的工具版本，实测可到 GB 级，`store prune` 不管）。
后者由 `toolcache` 整目录删除，删后按需重新下载。

### Docker 的期望管理

`docker system prune -a` 回收的是虚拟磁盘**内部**的空间；Docker Desktop / OrbStack 的稀疏镜像（`Docker.raw` 等）不会因此变小，宿主 `df` 很可能纹丝不动。回执必须说清：

- 容器内空间已回收，但宿主可用空间不变属正常；
- 想真正还盘：OrbStack 用其 `orb` 的清理入口，Docker Desktop 需手动压缩/重置虚拟磁盘；
- 另外：`docker system prune` 默认**不删卷**（`--volumes` 才删，可能有用户数据），本技能刻意不开这个开关。

## 二、本地数据库（`scripts/cleanup-opencode.sh`）

它是**勾选项之一，不是固定步骤**：默认不勾，用户勾了（或明确点名）才做。库小于约 500MB 时在选项里标「收益有限」，不建议为了它关一次 opencode。它在对话里的编码是 `opencode-db`，**不传给 `mac_cleanup.sh`**，由本技能单独执行。

opencode 用事件溯源把会话历史写进 SQLite，随使用膨胀，`event` 表通常占大头。脚本按保留天数删旧会话，清孤儿 snapshot，最后 `VACUUM` 回收物理空间。

### 先确认三件事

1. **库是不是这个路径**：`ls -lh ~/.local/share/opencode/opencode.db`。多实例/自定义安装用 `OC_DATA_DIR` 覆盖。
2. **opencode 是否在跑**：脚本自己会检测并默认拒绝执行；先知道结论可以少一次失败。
3. **有没有等量空闲空间**：备份要一份库大小的空间，`VACUUM` 峰值再要一份。脚本会先查，不够就中止（或跳过 VACUUM）。

### 用法

```bash
bash skills/disk-cleanup/scripts/cleanup-opencode.sh --dry-run   # 只统计将删行数，不动数据
bash skills/disk-cleanup/scripts/cleanup-opencode.sh             # 默认保留最近 7 天（先备份）
bash skills/disk-cleanup/scripts/cleanup-opencode.sh 30          # 保留 30 天
bash skills/disk-cleanup/scripts/cleanup-opencode.sh --kill      # 检测到运行中时，询问后终止再清理
```

| 参数 | 说明 |
|---|---|
| `[天数]` | 保留最近 N 天（非负整数，默认 7） |
| `--dry-run` | 只按阈值 `SELECT count(*)` 统计，不备份、不修改、不 VACUUM；**进程检测照跑**（不带 `--kill` 且检测到 opencode 在跑时仍会 exit 1） |
| `--kill` | 检测到 opencode 运行时，列出并询问后终止相关进程 |
| `--yes` / `-y` | 配合 `--kill`，跳过询问直接终止 |
| `--backup-dir <目录>` | 备份目录（默认 `~/opencode-backup`） |
| `--no-backup` | 跳过备份（**危险**：删除不可逆） |
| `--no-vacuum` | 不 VACUUM（删除已提交，但物理空间不回收） |
| `OC_FORCE=1` | **危险**：跳过进程检测，仅用于对离线副本做验证 |

### 备份默认内建

不指定 `--no-backup` 时，脚本先做 `.backup`（在线备份，对运行中的库也安全），再 `PRAGMA integrity_check`，任一步失败**直接中止**且不改数据。推荐保留这个默认；手动备份等价于：

```bash
mkdir -p ~/opencode-backup && sqlite3 ~/.local/share/opencode/opencode.db \
  ".backup '$HOME/opencode-backup/opencode.db'"
sqlite3 ~/opencode-backup/opencode.db "PRAGMA integrity_check;"   # 应返回 ok
```

整目录 `tar` 只在库很小时采用；12G 级不要 `cp`/`tar`。

### 进程检测

两类进程任一命中都会拦：CLI / serve（命令行匹配 `opencode-ai/bin/opencode`）、桌面版（`OpenCode.app` 及 Helper）。

不带 `--kill`：列出进程并拒绝执行。带 `--kill`：先列出、确认一次，随后对 CLI/serve 与桌面版分别再确认后终止（`--yes` 全程不问），**杀后复检**，仍有残留则中止——避免在活动连接上删库。

> ⚠️ 若脚本由运行中的 opencode 会话触发，`--kill` 会终止其宿主进程，也就是当前会话本身。
> 这种情况把命令交给用户，让他在独立终端里跑。

### 脚本做了什么

1. 校验 `sqlite3` 是否存在、库是否存在（缺一件就直接报错，不装作跑过）；
2. 事务内删除（`BEGIN IMMEDIATE`，失败整体回滚）：先子表后父表——
   `event`、`event_sequence`（按 `aggregate_id` 关联），`part`、`message`、`session_message`、`session_input`、
   `session_share`、`session_context_epoch`、`todo`（按 `session_id` 关联），最后 `session`（按 `time_updated`）；
   **schema 里缺的表自动跳过并在报告里列出**，不会因为版本差异整段失败；
3. 删除孤儿 snapshot 目录（目录名不再对应 `project` 表里的 id）；
4. `VACUUM` 回收物理空间（耗时随库大小增长；空间不足时跳过并给出单独重试的命令）。

删除前后都打印 `session`/`message`/`part`/`event` 四张主表的行数；结尾打印库大小 `之前 → 之后`。**只动会话相关表**，不碰 account / auth / credential 等鉴权数据。

### 效果参考

实测一份 12G 级库（保留 7 天、在副本上实跑；`--dry-run` 只统计、不写库，给不出清理后的行数与体积）：`session` 8361 → ~470，`message` 190994 → ~19940，
`part` 778701 → ~81081，`event` 1467242 → ~304961；库体积约 12G → 4G，`integrity_check: ok`。

数值随使用强度差异很大，只作量级参考，不要当作预期承诺。

## 三、只报告、不代删（手动清单）

判据只有一条：**删掉之后用户能不能自己恢复**。能自动重建的（缓存、构建产物）→ 勾选清单；不可逆或含用户数据的 → 只报告，**并且不进勾选列表**（避免让人误以为勾了就会代删）。

| 类别 | 典型路径 | 交给用户的方式 |
|---|---|---|
| iOS 设备备份 | `~/Library/Application Support/MobileSync/Backup` | Finder / iTunes「设备」里删旧备份 |
| 聊天数据 | `~/Library/Containers/com.tencent.xinWeChat/...`、`com.tencent.WeWorkMac/...` | 应用内「设置 → 存储空间」 |
| 虚拟机/容器镜像 | `~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data` | OrbStack 内删 machine，或 `orb delete <machine>`；**不要**在 Finder 里删目录 |
| 浏览器配置 | `~/Library/Application Support/<Browser>` | 浏览器「清除浏览数据 → 缓存」 |
| 文档类应用 | `~/Library/Application Support/Notion/Partitions` 等 | 退出应用后删缓存分区，或应用内清理 |
| 邮件 / 信息附件 | `~/Library/Mail`、`~/Library/Messages/Attachments` | 应用内删除 |
| 动态壁纸素材 | `~/Library/Application Support/com.apple.wallpaper/aerials` | 系统设置里换壁纸后由系统回收 |
| 崩溃转储 | `/cores` | root 属主；确认后交用户终端：`sudo rm -f /cores/core.*` |
| Apple Intelligence | `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_*`、`/private/var/db/AppleIntelligencePlatform`、`~/Library/Caches/com.apple.intelligence` | 系统托管，**只能看不能删**；入口「系统设置 → 通用 → 储存空间」 |
| 交换/睡眠镜像 | `/private/var/vm` | **不要手删**，系统自行回收 |
| 系统统一日志 | `/private/var/db/diagnostics`、`/private/var/db/uuidtext` | **不要手删**，系统自行轮转 |
| 系统更新暂存 | `/Library/Updates` | **不要动** |
| 应用体积 | `/Applications` | 只报告；卸载不需要的 App 由用户决定 |
| iCloud 本地副本 | `~/Library/Mobile Documents` | 应用内「移除下载」 |

其中 `/cores`、Apple Intelligence、`/private/var/vm`、`/private/var/db/diagnostics`+`uuidtext`、`/Library/Updates`、`/Applications`、iCloud 本地副本
**均由脚本在查询输出里自动报告**（只读段「只报告：系统级大户」；`--json` 里是 `reports[]`，读不到时 `kb=-1` 且 `note` 写「读不到（…）」，
只读、不改变退出码、不计入可删量）；删除/清理入口仍按上表方式由用户操作。

只读探测（先量后说）：

```bash
du -sh ~/Library/Application\ Support/MobileSync/Backup 2>/dev/null
du -sh ~/Library/Containers/com.tencent.xinWeChat/Data/Documents 2>/dev/null
du -sh ~/Library/Group\ Containers/HUAQ24HBR6.dev.orbstack/data 2>/dev/null
du -sh ~/Library/Application\ Support/* 2>/dev/null | sort -hr | head -20
```

路径含空格必须加引号。给出具体数字时注明是**本次实测**——不同机器差异很大，别把某次快照当通用结论。

## 四、验证收益

回执里的「释放量」分两行写，别混：

1. **各清理项实测可删合计（估算）**：只计状态为 `done` 的项（`partial`/`failed` 不计入，实际删除量无法确认；`--json` 的 `disk.estimated_freed_kb`）；
2. **`df` 差值（旁证）**：清理前后各跑一次 `df -h /`，差值含系统自身回收、其它进程写入等噪声（`--json` 的 `disk.df_delta_kb`）；差值 ≤0 时如实说明，**不要归因给「系统延迟」**；
3. 差值不明显时先确认执行清单（脚本末尾分三类列出：实际执行、未勾选、已勾选但未完成），再看是否被沙箱权限或 sudo 拒绝；
4. 建议重启一次再在「关于本机 → 储存空间」复核——该统计本身有延迟，不能用它判断本次清理是否生效。

## 五、已知边界

- 只处理白名单里的目录；新出现的大户先用 `--top` 定位、人工确认可再生后，再考虑加进脚本与编码表（并跑 `node scripts/check-disk-cleanup-codes.mjs` 校验文档与脚本一致）。
- 不在 `--projects-roots` 下的项目不会被 `projects`/`dshtmp`/`projectcache` 扫到；全盘扫 `node_modules`、`.dsh/tmp` 既慢又容易误伤，刻意不做。
- `dshtmp` 只清 `*/.dsh/tmp` 的内容，`.dsh/docs` 等用户文档目录不动；`projectcache` 只认 `.gocache`/`.tmp-gocache`/`.dsh/gocache`/`.pnpm-store`/`.corepack` 这几个名字，其它编译缓存（`node_modules/.cache`、`target` 等）归 `projects` 或不在覆盖范围。
- `orphans` 只看固定扫描根 + 标准安装位置：装在别处的 App 会被误判成「已卸载」，也不会去扫 `~/Downloads` 或第三方目录。
- 不处理系统「可清除空间」、睡眠镜像、APFS 快照策略——由 macOS 自己回收。
- 不处理外接盘、网络卷、云盘同步目录、其它卷的 `.Trashes`。
- `docker system prune` 不删卷；`--volumes` 可能有用户数据，本技能刻意不开。
