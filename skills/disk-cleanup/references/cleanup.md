# 清理对象与执行方式

macOS 本机磁盘是主战场：系统缓存、日志、临时文件、Time Machine 快照、开发工具缓存通常就是大头；
**项目层**（node_modules、构建产物）与**应用内缓存**（Electron 壳 app 自己的 Cache）往往比系统缓存更大；
本地数据库（如 opencode）属于「个别应用数据膨胀」，在同一套流程里按对象处理，不单开一条线。

## 一、macOS 磁盘（`scripts/mac_cleanup.sh`）

### 模式语义（先看懂再跑）

| 模式 | 行为 | 什么时候用 |
|---|---|---|
| 无参数 | **只查询**：统计并打印各目录占用，不删任何东西 | 用户选择「只看占用」或「选勾清理」后先跑这个 |
| `--list` | 只打印清理项编码与说明（`--list --json` 为机器可读版） | 核对勾选结果与编码 |
| `--top [N]` | 只读：列出 `$HOME` 下最大的 N 个目录与 >100MB 文件 | 用户问「什么最占地方」 |
| `--clean --dry-run [--only ids]` | 打印每项的计划命令与预计可删量，不实际删除 | 勾选后、执行前自查 |
| `--clean --only ids` | 只执行勾选的清理项 | 用户勾选完成后 |
| `--clean --all` | 执行全部清理项 | **只允许用户本人在终端手动使用** |
| `--orphans-list` | 只读：显示**全部**疑似卸载残留（默认只显示最大的 15 项） | 用户问「哪个 App 卸了还留着东西」 |
| `--clean --only orphans --orphans-delete <路径>` | 只删点名的路径（可重复传），路径必须在扫描根下 | 用户挑完具体残留后 |
| `--json` | stdout 只输出 JSON（进度信息走 stderr） | agent 需要结构化结果时 |

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
```

> `--dry-run` 单独使用**没有意义**；`--only/--skip` 不带 `--clean` 也不生效（脚本会提示仍是只读查询）。
> 编码写错时脚本直接 `exit 1` 并列出可用编码——避免「以为清了其实没清」。
> `--clean` 不带 `--only/--skip` 时不加 `--all` 会 **exit 2**，这是防盗清全部的手刹。

### 选择语义（用户勾选怎么落到命令）

- `--only a,b,c`：**只跑列出的项**，其余每步打印 `[跳过]`，报告里汇总为「未勾选（未执行）」。重复传 `--only` 会合并，不会互相覆盖。
- `--skip a,b`：排除指定项；与 `--only` 同给时，先取 `--only` 再减 `--skip`。同样支持重复传。
- 两个都不给 = 必须配 `--all`。**agent 代跑时必须显式给 `--only`**，这就是「最终清理项由用户决定」的落地方式。
- 编码是**勾选单位，不能拆到编码内部**：例如 `bigbuild` 里 Homebrew 与 Gradle 同进同出。用户只想清其中一项时，只能该项整组不勾、由用户自己在终端跑那条具体命令；**不要**为了满足粒度在任务里临时 `rm -rf`。
- 组合示例：`--clean --skip docker,bigbuild --only caches,logs`。

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
- 遍历被 TCC/权限拒绝的条目（Safari、CloudKit、HomeKit 等）单独计数，报告里写「N 个受保护子目录未计入」，**不当成 0**。

### 清理项编码

| 编码 | 覆盖对象 | 策略 / 阈值 | sudo | 删除后代价 |
|---|---|---|---|---|
| `caches` | `~/Library/Caches` | 纯缓存目录（浏览器/更新器/App Store）整删；其余只删 `mtime +1` | 否 | 应用首次打开变慢 |
| `logs` | `~/Library/Logs` | 只删 7 天前的旧日志文件，保留目录结构 | 否 | 基本无感 |
| `tmp` | `/private/tmp` | 只删 1 天前的陈旧内容 | **是** | 运行中程序的临时文件会重建 |
| `varfolders` | 当前用户 `/var/folders` 容器 | `T`/`C` 清 7 天以上；`X` 清 `*code_sign_clone*` 与 7 天前目录；`T/go-build*` 清 `mtime +1` | 否 | 无 |
| `snapshots` | Time Machine 本地快照 | 存在快照时 `tmutil thinlocalsnapshots / 999999999999 4` | **是** | 回滚粒度变粗，系统会重建 |
| `trash` | `~/.Trash` | 清空 | 否 | **不可恢复** |
| `xcode` | Xcode `DerivedData` | 整个删掉 | 否 | 下次构建全量重编 |
| `toolcache` | 语言工具链/包管理器白名单 + `pnpm store prune` | 删目录（重建即恢复）；pnpm 只回收未引用包 | 否 | 重新下载/编译 |
| `bigbuild` | ipsw、Homebrew、CocoaPods、Gradle、iOS DeviceSupport、CoreSimulator/Caches、不可用模拟器 | 删目录；`brew cleanup --prune=all` + `autoremove`；`xcrun simctl delete unavailable` | 否 | 重新下载/构建；Homebrew 旧版本不能回滚 |
| `docker` | 未使用镜像、停止的容器、构建缓存、未用网络 | `docker system prune -a --force` | 否 | 镜像要重新 pull；**Docker.raw 不缩小** |
| `appcache` | `~/Library/Application Support/*/{Cache,GPUCache,Code Cache,CachedData,CachedExtensionVSIXs,CacheStorage,…}` | 整目录删，<10MB 不入清单 | 否 | app 首次启动重建缓存；不动配置/登录态 |
| `updaters` | `crx_cache`、`auto-updater`、`app-recovery-cache`、`UpdateCache` | 整目录删 | 否 | 重新下载更新包 |
| `projects` | `--projects-roots`（默认 `~/Documents`）下的 `node_modules`、`dist`、`build`、`.next`、`.turbo`、`.venv`、`target`、`Pods` 等 | 只处理 ≥ `--projects-age-days`（默认 30）天未修改的目录，<50MB 不入清单 | 否 | 需重新 install/build |
| `orphans` | 已卸载 App 留在 `~/Library`、`/Library` 的目录（Application Support / Preferences / Containers / Group Containers / HTTPStorages / LaunchAgents 等） | **只报告**：反推已装 App 名单后列出疑似项；删除只认 `--orphans-delete` 点名的路径 | 部分（`/Library` 下） | 删的是该 App 的配置/缓存/许可数据，不可恢复 |

#### `tmp` 为什么走 `/private/tmp`

macOS 的 `/tmp` 是软链 → `private/tmp`，而 `find` **对作为起始点的软链默认不跟进**：

```bash
find /tmp  -mindepth 1 -maxdepth 1 | wc -l   # → 0   （旧写法，清理永久空转）
find /tmp/ -mindepth 1 -maxdepth 1 | wc -l   # → 26  （尾斜杠才对）
find /private/tmp -mindepth 1 -maxdepth 1 | wc -l   # → 26
```

旧版本用 `find /tmp …` 删了但从没删到东西，还照样打「✅ 已执行」。现在统一用真实路径 `/private/tmp`。
给脚本加新路径时同理：起始点先确认不是软链。

#### 纯缓存整删白名单

`is_purge_cache` 判据只有一条：**内容是仍可从服务端重新下载的副本**。目前覆盖
Edge / Chrome / Chromium / Brave / Vivaldi / Opera / Firefox / Safari、任何名字里带 `updater` 的目录、App Store 下载缓存。
这些目录不套 `mtime` 阈值——浏览器会持续 touch 缓存条目，套阈值等于清不动。
**新增白名单必须在脚本里加，不要在任务里临时 `rm -rf` 不了解的路径。**

#### `toolcache` 白名单

```text
~/.npm/_npx  _cacache  _logs
~/.cache/uv  puppeteer  node  codex-runtimes  opencode  yarn  bun
~/.bun/install/cache   ~/.cargo/registry/cache   ~/go/pkg/mod/cache/download   ~/.m2/repository
~/Library/Caches/go-build  goimports  gopls  golangci-lint  ms-playwright  Cypress  Yarn
~/Library/Caches/pip  node-gyp  electron  Homebrew
~/Library/pnpm/package-manager-store   （pnpm 工具版本仓库，store prune 不管它）
```

新增缓存目录必须改脚本里的 `SAFE_CACHE_DIRS`。

#### `projects`：项目层清理的边界

- 只在 `--projects-roots`（默认 `~/Documents`，可用冒号分隔多个）下扫描，**不进 git 仓库外的任意路径**；
- `-maxdepth 6` + `-prune`，命中 `node_modules` 后不再往里钻；
- 按**构建产物目录自身的 mtime** 判新旧：≥ `--projects-age-days`（默认 30）天未改动才列为可删，近期动过的直接跳过并在报告里标「N 天内有改动」；
- 用户要保住某个项目：`--projects-keep <绝对路径>`（可重复传）；
- 报告要给「路径 + 大小 + 多少天未改动」，用户据此勾选；删除后需要重新 install/build，必须写进回执；
- `dist`/`build` 这类名字在非项目目录也可能出现，所以阈值与根目录限制不能放宽成「全盘扫」。

#### `orphans`：已卸载应用的残留（反推，只报告）

macOS 没有「谁装过什么」的台账，只能反推：

- **已装名单**：`/Applications`、`/System/Applications`、`~/Applications`、`/Library/Input Methods` 下所有 `.app` 的 bundle id + 名称（`plutil` 读 `Info.plist`，不依赖 Spotlight 索引，关掉索引也能用）；
- **候选**：`ORPHAN_ROOTS` 里的**顶层**条目（不递归）——
  `~/Library/{Application Support,Caches,Preferences,Containers,Group Containers,HTTPStorages,Logs,LaunchAgents}`、
  `/Library/{Application Support,Preferences,Caches,LaunchAgents,LaunchDaemons,PrivilegedHelperTools}`；
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

脚本只在**所选清理项包含 `tmp`/`snapshots` 且要真实执行**时才 `sudo -v` 预取权限；失败则打印告警并**跳过**这两步，命令原文写进报告，其余步骤照常。

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
```

### `/var/folders` 为什么不能一把梭

这里混有当前用户与系统/其他用户的沙箱数据。脚本通过 `stat -f '%u'` 找出 **owner uid == 当前登录用户** 的那个容器目录（如 `/var/folders/_w/<hash>`），只清它下面的：

- `T` / `C`：7 天以上的过期缓存；
- `X`：`*code_sign_clone*` 代码签名残留（应用更新会自动重建）与 7 天前旧目录；
- `T/go-build*`：Go 编译缓存（`mtime +1`）。

系统/他人沙箱（`_zz` 下的 WebKit、ScreenTime 等受 TCC 保护）会被跳过，既不误删，也不刷 `Operation not permitted` 噪音。

### pnpm 走 corepack + 两套 store

裸 `pnpm` 在部分环境里是 Corepack shim，一调用可能因项目声明版本与缓存不一致触发「Corepack is about to download…」交互弹窗。脚本用 `corepack pnpm store prune` 复用已有版本。

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
| `--dry-run` | 只按阈值 `SELECT count(*)` 统计，不备份、不修改、不 VACUUM |
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

不带 `--kill`：列出进程并拒绝执行。带 `--kill`：先列出、问一次、终止、**杀后复检**，仍有残留则中止——避免在活动连接上删库。

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

删除前后都打印各表行数；结尾打印库大小 `之前 → 之后`。**只动会话相关表**，不碰 account / auth / credential 等鉴权数据。

### 效果参考

实测一份 12G 级库（保留 7 天、对副本干跑）：`session` 8361 → ~470，`message` 190994 → ~19940，
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

只读探测（先量后说）：

```bash
du -sh ~/Library/Application\ Support/MobileSync/Backup 2>/dev/null
du -sh ~/Library/Containers/com.tencent.xinWeChat/Data/Documents 2>/dev/null
du -sh ~/Library/Group\ Containers/HUAQ24HBR6.dev.orbstack/data 2>/dev/null
du -sh ~/Library/Application\ Support/* 2>/dev/null | sort -hr | head -20
```

路径含空格必须加引号。给出具体数字时注明是**本次实测**——不同机器差异很大，别把某次快照当通用结论。

## 四、验证收益

1. 清理前后各跑一次 `df -h /`，差值才是真实释放量；
2. 差值不明显时先确认执行清单（脚本末尾分三类列出：实际执行、未勾选、已勾选但未完成），再考虑系统记账延迟；
3. 建议重启一次再在「关于本机 → 储存空间」复核——该统计本身有延迟，不能用它判断本次清理是否生效。

## 五、已知边界

- 只处理白名单里的目录；新出现的大户先用 `--top` 定位、人工确认可再生后，再考虑加进脚本与编码表（并跑 `node scripts/check-disk-cleanup-codes.mjs` 校验文档与脚本一致）。
- 不在 `--projects-roots` 下的项目不会被 `projects` 扫到；全盘扫 `node_modules` 既慢又容易误伤，刻意不做。
- `orphans` 只看固定扫描根 + 标准安装位置：装在别处的 App 会被误判成「已卸载」，也不会去扫 `~/Downloads` 或第三方目录。
- 不处理系统「可清除空间」、睡眠镜像、APFS 快照策略——由 macOS 自己回收。
- 不处理外接盘、网络卷、云盘同步目录、其它卷的 `.Trashes`。
- `docker system prune` 不删卷；`--volumes` 可能有用户数据，本技能刻意不开。
