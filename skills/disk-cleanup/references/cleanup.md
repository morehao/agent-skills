# 清理对象与执行方式（入口）

macOS 本机磁盘是主战场：系统缓存、日志、临时文件、Time Machine 快照、开发工具缓存通常就是大头；
**项目层**（node_modules、构建产物、`.dsh/tmp` 过程产物、Go/pnpm 编译缓存）与**应用内缓存**（Electron 壳 app 自己的 Cache）往往比系统缓存更大；
本地数据库（如 opencode）属于「个别应用数据膨胀」，在同一套流程里按对象处理，不单开一条线。

本文件只讲**通用规则**（模式、勾选、参数、`--json`、双口径、sudo/沙箱、验证收益、已知边界）与**编码索引**。
按清理对象组织的细节在下列分篇，按需 `read`：

| 你关心什么 | 读这篇 |
|---|---|
| 按开发工具看缓存（docker / node / go / python / rust / jvm / xcode / homebrew / opencode） | `tools/<tool>.md` |
| 系统级清理（缓存/日志/临时文件/快照/废纸篓/应用缓存/更新残留） | [macos-system.md](macos-system.md) |
| 项目内构建产物、过程产物、编译缓存 | [project-artifacts.md](project-artifacts.md) |
| 已卸载 App 的残留 | [orphans.md](orphans.md) |

### 清理项编码

`--only` 的勾选单位是**编码**，下表是全部 16 个编码的一句话说明与详细去处（完整策略/阈值/代价见对应分篇；单一事实源是 `mac_cleanup.sh --list --json`）。

| 编码 | 覆盖对象（一句话） | 详见 |
|---|---|---|
| `caches` | `~/Library/Caches`；纯缓存整删，其余 1 天前 | [macos-system.md](macos-system.md) |
| `logs` | `~/Library/Logs`；7 天前文件 | [macos-system.md](macos-system.md) |
| `tmp` | `/private/tmp`；1 天前（sudo） | [macos-system.md](macos-system.md) |
| `varfolders` | 当前用户 `/var/folders` 容器 | [macos-system.md](macos-system.md) |
| `snapshots` | Time Machine 本地快照（sudo） | [macos-system.md](macos-system.md) |
| `trash` | `~/.Trash` 清空 | [macos-system.md](macos-system.md) |
| `appcache` | Electron/Chromium 型 app 的 Cache | [macos-system.md](macos-system.md) |
| `updaters` | 应用更新残留 | [macos-system.md](macos-system.md) |
| `xcode` | Xcode DerivedData | [tools/xcode-ios.md](tools/xcode-ios.md) |
| `toolcache` | 语言工具链/包管理器白名单 + pnpm store prune | [tools/node.md](tools/node.md)、[go.md](tools/go.md)、[python.md](tools/python.md)、[rust.md](tools/rust.md) |
| `bigbuild` | ipsw、Homebrew、CocoaPods、Gradle、iOS DeviceSupport、模拟器 | [tools/homebrew-cocoapods.md](tools/homebrew-cocoapods.md)、[xcode-ios.md](tools/xcode-ios.md)、[jvm.md](tools/jvm.md) |
| `docker` | 未使用镜像/容器/构建缓存/网络 | [tools/docker.md](tools/docker.md) |
| `projects` | 项目内 `node_modules`/`dist`/`build`/`target` 等 | [project-artifacts.md](project-artifacts.md) |
| `dshtmp` | 项目内 `**/.dsh/tmp` 过程产物 | [project-artifacts.md](project-artifacts.md) |
| `projectcache` | 项目内 `.gocache`/`.pnpm-store` 等编译缓存 | [project-artifacts.md](project-artifacts.md) |
| `orphans` | 已卸载 App 残留（**只报告**，删除认 `--orphans-delete`） | [orphans.md](orphans.md) |

> opencode 数据库编码 `opencode-db` 不在 `mac_cleanup.sh` 里，由 `cleanup-opencode.sh` 单独执行，见 [tools/opencode.md](tools/opencode.md)。

---

## 模式语义（先看懂再跑）

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

## 选择语义（用户勾选怎么落到命令）

- `--only a,b,c`：**只跑列出的项**，其余每步打印 `[跳过]`，报告里汇总为「未勾选（未执行）」。重复传 `--only` 会合并，不会互相覆盖。
- `--skip a,b`：排除指定项；与 `--only` 同给时，先取 `--only` 再减 `--skip`。同样支持重复传。
- 两个都不给 = 必须配 `--all`。**agent 代跑时必须显式给 `--only`**，这就是「最终清理项由用户决定」的落地方式。
- 编码是**勾选单位，不能拆到编码内部**：例如 `bigbuild` 里 Homebrew 与 Gradle 同进同出。用户只想清其中一项时，只能该项整组不勾、由用户自己在终端跑那条具体命令；**不要**为了满足粒度在任务里临时 `rm -rf`。
- 组合示例：`--clean --skip docker,bigbuild --only caches,logs`。

## 参数与默认值

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

## `--json` 输出结构

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

## 两个口径：目录总量 ≠ 本次可删量

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

## 权限与 sudo 交接

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

## 沙箱权限与 sudo 同级

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

## 验证收益

回执里的「释放量」分两行写，别混：

1. **各清理项实测可删合计（估算）**：只计状态为 `done` 的项（`partial`/`failed` 不计入，实际删除量无法确认；`--json` 的 `disk.estimated_freed_kb`）；
2. **`df` 差值（旁证）**：清理前后各跑一次 `df -h /`，差值含系统自身回收、其它进程写入等噪声（`--json` 的 `disk.df_delta_kb`）；差值 ≤0 时如实说明，**不要归因给「系统延迟」**；
3. 差值不明显时先确认执行清单（脚本末尾分三类列出：实际执行、未勾选、已勾选但未完成），再看是否被沙箱权限或 sudo 拒绝；
4. 建议重启一次再在「关于本机 → 储存空间」复核——该统计本身有延迟，不能用它判断本次清理是否生效。

## 已知边界

- 只处理白名单里的目录；新出现的大户先用 `--top` 定位、人工确认可再生后，再考虑加进脚本与编码表（并跑 `node scripts/check-disk-cleanup-codes.mjs` 校验文档与脚本一致）。
- 不在 `--projects-roots` 下的项目不会被 `projects`/`dshtmp`/`projectcache` 扫到；全盘扫 `node_modules`、`.dsh/tmp` 既慢又容易误伤，刻意不做。
- `dshtmp` 只清 `*/.dsh/tmp` 的内容，`.dsh/docs` 等用户文档目录不动；`projectcache` 只认 `.gocache`/`.tmp-gocache`/`.dsh/gocache`/`.pnpm-store`/`.corepack` 这几个名字，其它编译缓存（`node_modules/.cache`、`target` 等）归 `projects` 或不在覆盖范围。
- `orphans` 只看固定扫描根 + 标准安装位置：装在别处的 App 会被误判成「已卸载」，也不会去扫 `~/Downloads` 或第三方目录。
- 不处理系统「可清除空间」、睡眠镜像、APFS 快照策略——由 macOS 自己回收。
- 不处理外接盘、网络卷、云盘同步目录、其它卷的 `.Trashes`。
