# 清理对象与执行契约

`mac_cleanup.sh` 的**唯一事实源是脚本自己**：编码与说明来自 `scripts/data/codes.tsv`，用 `--list --json` 原样输出；参数与退出码来自 `--help` 与实现。本文只做索引、模式语义与数据契约，不重复 SKILL.md 的铁律。

## 模式语义（先看懂再跑）

| 模式 | 行为 | 什么时候用 |
|---|---|---|
| 无参数 | **只查询**：统计并打印各编码占用，不删任何东西 | 第 1 步测量 |
| `--list` | 打印编码、一句话说明、是否需 sudo，末尾附场景组 | 核对勾选与编码 |
| `--groups` | 只列场景组（组名 → 编码） | 用户说「只清 iOS / 只清 docker」时先看成映射 |
| `--list --json` | 同上，机器可读：`{"schema":3,"codes":[{"id","label","desc","sudo"}]}` | 生成勾选项、核对编码是否存在 |
| `--top [N]` | 只读：`$HOME` 下最大的 N 个目录 + >100 MB 文件（默认 10，`-xdev` 全量遍历，慢） | 用户问「什么最占地方」 |
| `--history [--limit N]` | 回放台账，默认最近 50 条；字段见 [safety.md](safety.md) | 用户问「上次删了什么」 |
| `--clean --only <ids>` | 只执行勾选项；其余每步打印 `[跳过]（未勾选）` | 用户勾选后 |
| `--clean --skip <ids>` | 执行「全部减排除项」；必须显式出现，且与 `--only` 同给时先取 `--only` 再减 | 少见的反向选择 |
| `--clean --all` | 全清，必须显式写；**只允许用户在本人终端用** | 用户明确要求且在自己终端跑 |
| `--clean --dry-run --only <ids>` | 走同一代码路径，只打印每步计划与预计可删量，不删；同时产出**候选清单**（逐条路径，见下） | 执行前复核 |
| `--orphans-list` | 只读：列出全部疑似卸载残留（A/B 两档各默认只展示最大的 15 项） | 用户问卸载残留 |
| `--clean --only orphans --orphans-delete <路径>` | 只删点名路径（可重复传），须过路径校验与候选校验 | 用户挑完具体残留 |

**`--dry-run` 必须配 `--clean`**：单独 `--dry-run` 是用法错误，直接 `exit 2`（v1 会静默降级成查询，容易让人误以为「已经预览过」）。

**`--only/--skip/--group` 在查询、预览、执行三种模式下都生效**：加了范围就只测、只报、只动范围内的编码（范围外的编码在查询模式不出现，在执行模式记 `skipped-unselected`）。这是「只聚焦 docker」的正确用法——不带 `--clean` 也能用，且会更快。

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh                        # 查询
bash skills/disk-cleanup/scripts/mac_cleanup.sh --top 10               # 谁最占地方
bash skills/disk-cleanup/scripts/mac_cleanup.sh --list --json          # 编码
bash skills/disk-cleanup/scripts/mac_cleanup.sh --groups               # 场景组
bash skills/disk-cleanup/scripts/mac_cleanup.sh --only docker          # 只测 docker
bash skills/disk-cleanup/scripts/mac_cleanup.sh --group ios            # 只测 iOS 那组
bash skills/disk-cleanup/scripts/mac_cleanup.sh --json                 # 结构化查询
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --dry-run --only caches,logs
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only caches,logs
bash skills/disk-cleanup/scripts/mac_cleanup.sh --history --limit 20
```

## 参数与默认值

| 参数 | 说明 |
|---|---|
| `--only <ids>` / `--skip <ids>` | 英文逗号分隔编码，可重复传（合并）；`--only=caches` 等号形式同样可用 |
| `--dry-run` | 与 `--clean` 同用才有意义，单独使用 `exit 2` |
| `--all` | 显式全清；`--clean` 既无 `--only/--skip` 又无 `--all` 时 `exit 2` |
| `--json` | stdout 只输出一个 JSON，进度与外部命令输出走 stderr |
| `--manifest <路径>` | 预览时把候选清单写到这里（默认跟台账同目录）；**只在 `--clean --dry-run` 下有效**，单独用或配 `--clean` 不带 `--dry-run` 都 `exit 2` |
| `--limit <N>` | `--history` 条数，默认 50；须非负整数，否则 `exit 2` |
| `--top [N]` / `--top=N` | 默认 10 |
| `--orphans-list` | 列出全部残留候选（不加时为每档只展示 15 项） |
| `--orphans-delete <路径>` / `--orphans-delete=<路径>` | 点名删除，可重复传 |
| `--orphans-age-days <N>` | 残留「多少天无改动」判定，默认 30 |
| `--cache-age-days <N>` | `caches` 的 mtime 阈值，默认 1 天 |
| `--log-age-days <N>` | `logs` 的 mtime 阈值，默认 7 天 |
| `--projects-roots <路径>` | `projects`/`dshtmp`/`projectcache` 扫描根，默认 `$HOME/Documents`（可用 `PROJECT_ROOTS` 环境变量预置） |
| `--projects-keep <路径>` | 保留某个项目路径，可重复传，三个项目类编码都生效 |
| `--projects-age-days <N>` | `projects` 年龄阈值，默认 30 |
| `--dshtmp-age-days <N>` | `dshtmp` 年龄阈值，默认 0（= 全部可删） |
| `--projectcache-age-days <N>` | `projectcache` 年龄阈值，默认 3 |
| `-h` / `--help` | 打印用法 |

六个 `*-age-days` 参数都支持 `--flag=value`；值必须是非负整数，否则 `exit 2`。

## 编码表

编码是**勾选单位，不能拆到编码内部**（`node` 里 npm/yarn/pnpm 同进同出）。下表只给「覆盖对象」与细则去处；阈值、命令、代价以 `--list --json` 的 `desc` 为准——那是本表的来源。

### 清理项编码

| 编码 | 覆盖对象（一句话） | 详见 |
|---|---|---|
| `caches` | 用户缓存 `~/Library/Caches`：纯缓存目录整删，其余只删 1 天前未改动内容 | [macos-system.md](macos-system.md) |
| `logs` | `~/Library/Logs`：7 天前的旧日志文件与因此变空的旧目录 | [macos-system.md](macos-system.md) |
| `tmp` | `/private/tmp`：1 天前的陈旧内容（sudo） | [macos-system.md](macos-system.md) |
| `varfolders` | `/var/folders` 当前用户容器残留 | [macos-system.md](macos-system.md) |
| `snapshots` | Time Machine 本地快照（sudo） | [macos-system.md](macos-system.md) |
| `trash` | 废纸篓，清后不可恢复 | [macos-system.md](macos-system.md) |
| `systemlogs` | `/Library/Logs/DiagnosticReports` 与 `/private/var/log`，7 天前、单批 ≤5 条（sudo） | [macos-system.md](macos-system.md) |
| `appcache` | Electron/Chromium 型 App 的 `Cache`/`GPUCache`/`Code Cache` 等 | [macos-system.md](macos-system.md) |
| `updaters` | 自动更新下载残留（`crx_cache`、`auto-updater` 等） | [macos-system.md](macos-system.md) |
| `browserold` | Chrome/Edge/Brave 旧版本目录，保留最新与正在运行的版本 | —（细则见 `--list`） |
| `groupcontainers` | `~/Library/Group Containers/*/Library/Caches`，仅容器 App 未运行时 | —（细则见 `--list`） |
| `halfdownloads` | `~/Downloads` 下未完成的下载（`*.download`/`*.crdownload`/`*.part`） | —（细则见 `--list`） |
| `installers` | `~/Downloads`、`~/Desktop` 下 >100 MB 且 30 天未动的 `.dmg/.pkg/.iso/.xip/.zip` | —（细则见 `--list`） |
| `jetbrains` | Toolbox 旧版本（保留最新一份）与 IDE 旧日志 | —（细则见 `--list`） |
| `agentversions` | Claude Code / Cursor Agent / Copilot 的旧版本堆叠 | —（细则见 `--list`） |
| `xcode` | Xcode DerivedData 整目录 | [tools/xcode-ios.md](tools/xcode-ios.md) |
| `xcode-ios` | ipsw / iOS DeviceSupport / CoreSimulator / 不可用模拟器 | [tools/xcode-ios.md](tools/xcode-ios.md) |
| `node` | npm/yarn/bun/pnpm 缓存与无头运行时缓存 + `pnpm store prune` | [tools/node.md](tools/node.md) |
| `go` | go-build / go/pkg/mod / goimports / gopls / golangci-lint | [tools/go.md](tools/go.md) |
| `python` | uv / pip 缓存 | [tools/python.md](tools/python.md) |
| `rust` | cargo registry 缓存 | [tools/rust.md](tools/rust.md) |
| `jvm` | Maven `~/.m2/repository` + Gradle `~/.gradle/caches` | [tools/jvm.md](tools/jvm.md) |
| `homebrew` | `brew cleanup --prune=all` + `autoremove` | [tools/homebrew-cocoapods.md](tools/homebrew-cocoapods.md) |
| `cocoapods` | CocoaPods 缓存 | [tools/homebrew-cocoapods.md](tools/homebrew-cocoapods.md) |
| `docker` | `docker system prune -a`（不缩小 Docker.raw） | [tools/docker.md](tools/docker.md) |
| `projects` | 项目构建产物（`node_modules`/`dist`/`build` 等，默认 30 天） | [project-artifacts.md](project-artifacts.md) |
| `dshtmp` | 项目内 `*/.dsh/tmp` 的内容（保留目录本身） | [project-artifacts.md](project-artifacts.md) |
| `projectcache` | 项目内编译缓存（`.gocache`/`.pnpm-store` 等，默认 3 天） | [project-artifacts.md](project-artifacts.md) |
| `orphans` | 已卸载 App 残留（**只报告**，删除认 `--orphans-delete`） | [orphans.md](orphans.md) |

> 「—」表示该编码目前只有 `codes.tsv` 的一句话说明，没有单独分篇；`--list` 原样输出那句话。
> opencode 库不在上面的编码里，走 `scripts/cleanup-opencode.sh`（见 [tools/opencode.md](tools/opencode.md)）。

## 选择语义

- `--only a,b,c`：只跑列出的项。重复传会合并；编码写错时脚本 `exit 2` 并列出可用编码。
- `--skip a,b`：排除；与 `--only` 同给时先取 `--only` 再减 `--skip`。
- 两个都不给 → 必须 `--all`，否则 `exit 2`。agent 代跑时必须显式 `--only`，这就是「最终清理项由用户决定」的落地方式。
- `--group <名>`：场景组，等价于把组内编码一起交给 `--only`；组名不得与编码重名（编码优先）。`--only` 里也可以直接写组名。
- **聚焦一个场景**（用户说「我只想清 docker / 只清 iOS」）：直接把范围交下去，不要先全量扫描再筛——`--only docker` 就只测 docker。

### 场景组（`--groups` / `--group`）

| 组名 | 展开为 | 什么时候用 |
|---|---|---|
| `system` | `caches,logs,tmp,varfolders,snapshots,trash,systemlogs` | 「清系统缓存/日志/废纸篓」 |
| `devcaches` | `xcode,node,go,python,rust,jvm,homebrew,cocoapods,xcode-ios,jetbrains,agentversions,docker` | 「开发工具缓存都清一下」（不含项目内产物） |
| `ios` | `xcode,xcode-ios,cocoapods` | 「只清 iOS/macOS 开发的东西」 |
| `nodejs` | `node,projectcache` | 「Node 生态的缓存」 |
| `project-artifacts` | `projects,dshtmp,projectcache` | 「清项目里的构建产物」 |
| `ai-agents` | `agentversions` | 「agent 旧版本堆太多了」 |
| `containers` | `docker` | 「只清 docker」 |

组名与展开值以 `scripts/data/groups.tsv` 为单一事实源；`check-disk-cleanup-codes.mjs` 会校验组名不与编码重名、且只引用已声明编码。

- 想只清某个编码内部的一部分（如只清 npm 不清 pnpm）：脚本不支持拆分，只能整组不勾、把那条具体命令交用户终端。**不要**为了粒度在任务里临时 `rm -rf`。

## 退出码

| 码 | 含义 |
|---|---|
| `0` | 正常；含「未勾选任何项」「已勾选的 sudo 项被跳过」（后者在 `items[].status=skipped-sudo`，不影响退出码） |
| `1` | 有 `partial`/`failed` 项；或 `--orphans-delete` 的路径没过预校验（不带尾斜杠、不含 `..`/`.`、存在、父目录是扫描根、不是扫描根本身、在本次候选里） |
| `2` | 用法或校验错误：`--dry-run` 单独用、`--clean` 缺 `--only/--skip/--all`、**未知编码**、未知参数、`--limit` 或 `*-age-days` 非非负整数、`--only`/`--skip`/`--orphans-delete` 缺值、`--manifest` 没配 `--clean --dry-run`、HOME 断言失败、编码表不可读、用户 protect 文件存在但读不到。此时**没有 JSON** |

## JSON 契约（schema 3）

stdout 是**单个** JSON 对象；`--json` 下所有进度与外部命令输出走 stderr，可直接 parse。

```json
{
  "schema": 3,
  "mode": "query | clean | dry-run",
  "exit_code": 0,
  "failed_count": 0,
  "disk": {"free_before_kb": 0, "free_after_kb": 0, "freed_kb": 0,
           "estimated_freed_kb": 0, "df_delta_kb": 0},
  "scope": {"active": true, "only": "caches", "skip": ""},
  "manifest": {"path": "/Users/x/Library/Logs/disk-cleanup/manifests/plan-….tsv",
               "count": 1569, "truncated": false, "write_failed": false,
               "by_decision": {"delete": 1194, "protected": 375, "unverified": 0},
               "by_kind": {"dir": 8, "file": 1561, "command": 0}},
  "codes": [{"id": "caches", "label": "…", "status": "done",
             "total_kb": 0, "deletable_kb": 0, "items": 2}],
  "reports": [{"id": "cores", "label": "…", "kb": -1, "note": "读不到"}],
  "protected": [{"path": "…", "reason": "spotlight-index"}],
  "items": [{"id": "caches", "label": "…", "status": "dry-run", "reason": "ok",
             "total_kb": 0, "deletable_kb": 0,
             "sample_paths": ["…"], "path": "…", "note": "清单 1569 项（保护 375）"},
            {"id": "orphans", "status": "reported", "reason": "ok", "total_kb": 0,
             "deletable_kb": 0, "confidence": "high", "a_count": 2, "b_count": 210,
             "b_total_kb": 98132, "unknown_size": 79, "age_days": 30,
             "candidates": [{"path": "…", "kb": 0, "age_days": 3, "tier": "a",
                             "confidence": "high", "sudo": false, "size_unknown": false}]}],
  "audit": {"run_id": "20261112T170000-12345",
            "log": "/Users/x/Library/Logs/disk-cleanup/operations.log"}
}
```

- `mode`：只有 `--clean` 才出现 `clean`；`dry-run` 只在 `--clean --dry-run` 时出现。
- `disk.freed_kb`：仅 `clean` 且非 dry-run 时等于 `estimated_freed_kb`，其余恒为 `0`。
- `disk.estimated_freed_kb`：`status=done` 的项 `deletable_kb` 之和；`partial`/`failed` 不计（实际删了多少无法确认）。
- `disk.df_delta_kb`：前后 `df` 差值，**始终**给出，只是旁证（含系统自身回收、其它进程写入等噪声）。
- `scope`：本次范围（`active` / `only` / `skip`），`--only` 与 `--skip` 均为归一化后的逗号串。
- **`manifest`：只有 `--clean --dry-run` 有值，其余为 `null`。** `path` 是 TSV 清单路径（`""` 表示目录不可写、清单没落盘，此时只有计数可看），`count` 是数据行数，`by_decision`/`by_kind` 是同一份数据的聚合；`truncated=true` 表示候选超过上限（`DC_PLAN_MAX`，默认 10 万条）已截断，`write_failed=true` 表示写到一半失败。
- 清单列固定为 `code  decision  kind  path  reason  size_kb  sudo`，表头以 `#` 开头（解析方跳过）。`decision` ∈ `delete`（计划删）/`protected`（保护清单拦下）/`unverified`（路径断言不过）；`kind` ∈ `dir`/`file`/`command`——`command` 表示该编码由外部命令执行（`brew cleanup`、`docker system prune`、`tmutil`、`simctl`、`pnpm store prune`），此时 `path` 列放命令本身。
- 清单来自**同一条删除漏斗**：预览时漏斗只记录不删，所以「清单里的路径」就是「真跑时会交给漏斗的路径」，不会漂移。`size_kb` 固定 `-1`（不重复测量，大小看 `codes[].deletable_kb`）。删空后清掉的空目录由删除结果决定，**不在清单里**。
- 预览会把候选完整枚举一遍，因此比查询慢：`caches` 约 4s，候选上万条的编码（如 `/var/folders`）可到几十秒。这是「可逐条核对」的代价，不是卡死；不想等就先用 `--only` 缩小范围。
- `codes[]`：按编码聚合，同一编码多步时 `total_kb`/`deletable_kb` 求和、`items` 为出现次数、`status` 取最严重（`failed` > `partial` > `done` > `dry-run` > `reported` > `queried` > `skipped-sudo` > `skipped-unselected`）。
- `items[]`：每步一条，`status` ∈ 上述枚举；`reason` 见 [safety.md](safety.md)；`total_kb`/`deletable_kb` 是 KB 整数。
- `items[].sample_paths`：该步的样例路径（≤5 条），只用来快速感知，**不是完整清单**——要逐条核对读 `manifest.path`。
- `items[].path` / `items[].note`：可选，出现时是本次动作的路径与补充说明（如「清单 1569 项（保护 375）」）。
- `protected[]`：本次命中保护清单的路径（`{path, reason}`）；没有命中时是空数组。预览时也会列（预览记录的是「会被拦下」）。命中不进失败计数、不影响退出码。
- `reports[]`：只报告段的机器可读视图（`cores`、`apple_intelligence`、`vm`、`diagnostics`、`uuidtext`、`updates`、`applications`、`icloud`、`thirdparty_snapshots`、`node` 的 pnpm store、`docker` 可回收空间），**`kb=-1` 表示读不到，不是 0**；不计入可删量、不影响退出码。
- `items[]` 的 `orphans` 条目另有：`confidence`（`high`/`low`）、`a_count`/`b_count`、`b_total_kb`、`unknown_size`、`age_days`，以及 `candidates[]`——每条 `{path, kb, age_days, tier: a|b, confidence, sudo, size_unknown}`（`size_unknown=true` 表示 `kb` 读不到，别当 0）。`total_kb`/`deletable_kb` 只算 A 档。
- `exit_code` 与进程退出码一致；`failed_count` 是 `partial`+`failed` 项数，`exit_code=1` 时至少为 1。
- `audit.log` 为台账路径；日志目录不可写时为空字符串（台账缺省不影响本次执行）。

`schema 3` 相对 2 的变化：新增 `manifest`；`--list --json` 与 `--history --json` 结构未变，但版本号统一到 3（`DC_SCHEMA_VERSION` 一处定义）。

`--history --json` 是另一套结构（`entries[]`），字段见 [safety.md](safety.md)。

## 双列表：无终端环境能不能跑，真事谁跑

「无终端」指 agent 环境：没有 TTY、`sudo` 不可用、多数情况下被沙箱限制在工作区内。

| 命令 | 无终端时能不能跑 | 真事谁跑 |
|---|---|---|
| `--list` / `--help` | 能，纯读编码表 | agent |
| 无参数查询 / `--json` 查询 | 能，只读；但要 `du` 多个目录，慢 | agent |
| `--top N` | 能，`-xdev` 全量遍历 `$HOME`，100 GB+ 要几分钟；N 放小 | agent |
| `--history` / `--history --json` | 能，只读台账 | agent |
| `--orphans-list` | 能，只读扫描 | agent |
| `--clean --dry-run --only …` | 能，只打印计划、不删；产出候选清单时会完整枚举，比查询慢（`caches` 秒级到十秒级） | agent |
| `--clean --dry-run … --manifest <路径>` | 能；清单默认写台账目录，只读沙箱里自动退到 `$TMPDIR/disk-cleanup-<uid>/manifests/`，也可显式指到工作区内 | agent |
| `--clean --only <非 sudo 编码>` | **取决于沙箱**：目标在可写范围内能跑；`workspace-write` 沙箱里 `~/Library`、`/private/var` 通常被拒（`reason=denied-sandbox`） | 可写沙箱内 agent；否则用户终端 |
| `--clean --only tmp,snapshots,systemlogs`（含 sudo 编码） | 不能：无 TTY，`sudo -v` 必失败，脚本会跳过这些步并打印命令 | 用户终端 |
| `--clean --only orphans --orphans-delete <路径>` | `$HOME` 下的同「非 sudo 编码」；`/Library` 下的需 sudo | `$HOME` 下 agent（可写时）；`/Library` 下用户终端 |
| `--clean --all` | 不该跑：本技能禁止 agent 全清 | 用户终端 |
| `cleanup-opencode.sh` | 能跑（纯 `sqlite3`），但会闭库、`--kill` 可能结束当前会话 | 问过用户后 agent |

## 已知边界

- 只处理白名单里的路径。新出现的大户先用 `--top` 定位、确认可再生，再谈加编码；不要在任务里临时 `rm -rf`。
- 不在 `--projects-roots` 下的项目不会被扫到；全盘扫 `node_modules`、`.dsh/tmp` 既慢又容易误伤，刻意不做。
- 不处理「可清除空间」、睡眠镜像、APFS 快照策略、云盘与外接盘的 `.Trashes`。
- 口径细节（只统计文件、硬链接各计一次、TCC 拒绝条目单独计数）见 [macos-system.md](macos-system.md)。
