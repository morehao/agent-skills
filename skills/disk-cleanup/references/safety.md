# 安全边界：漏斗、protect、reason、台账

本文件说清「删除到底被什么挡住」。脚本侧的对应实现在 `scripts/lib/safety.sh`（删除内核）、`scripts/lib/probe.sh`（在用探测）、`scripts/lib/audit.sh`（台账）。

## 删除漏斗是唯一出口

所有删除只经 `lib/safety.sh` 的同一个删除内核，其余都是它的包装：

```
dc_delete_one <路径> [sudo]        ← 单条，返回 0 成功 / 1 跳过（不算失败）/ 2 失败
dc_delete_aged <目录> <天数>        ← 只删过期文件，再清因此变空的目录
dc_delete_whole <路径>              ← 整目录
dc_delete_paths_stdin               ← 从 stdin 读 NUL 分隔路径
        └─ 单条 → dc_funnel_rm <路径> <0|1>        （断言 → 保护 → 在用 → rm）
        └─ 多条 → dc_batch_add ×N + dc_batch_flush（同一套闸，攒批一次 rm）
```

**为什么要批量**：逐条 `rm` 时，每个路径要付 3~4 个进程（`rm` + 看门狗子 shell + `sleep`）。
清 `~/Library/Caches` 这种几千个文件的场景会瞬间堆出几千个进程，顶满 macOS 默认
`kern.maxprocperuid=4000`，脚本自己被 `fork: Resource temporarily unavailable` 打死（表现为
半路退出、`exit 128`、台账只写了一条 `start`）。所以多条删除先逐条过闸攒进 `DC_BATCH_PATHS`，
满 `DC_RM_BATCH_MAX`（默认 256）就一次 `rm -rf -- p1 p2 …` 删掉；整批失败才回退逐条定位原因，
**成功路径不再付进程**。`dc_batch_flush` 是唯一允许出现 `rm` 的第二个函数，
`scripts/check-disk-cleanup-safety.mjs` 只放行这两个名字。

`dc_funnel_rm` 按固定顺序过闸，任何一闸不过就不删：

1. **路径断言**（见下）——不过则记 `io-error` / `protected` / `unverified-owner`，计失败；
2. **保护清单**——命中则记 `protected`（子原因如 `spotlight-index` 记进 `protected[]`），**跳过、不计失败、不绕过**；
3. **在用检测**——目标是被打开的**文件**时查 `lsof`，被占用则记 `in-use` 并跳过（目录不做这项探测）；
4. **执行**——`rm -rf -- <路径>` 或 `sudo -n rm -rf -- <路径>`，统一套 600 秒超时；
5. **失败归类**——对父目录做真实写测试（`mktemp -d` 再 `rmdir`），据此区分 `denied-readonly` / `denied-sandbox` / `not-found` / `io-error`；超时记 `timeout`。

脚本里除 `dc_funnel_rm`（单条）与 `dc_batch_flush`（批量）之外不应出现 `rm`；批量入口的 1~3 道闸逐条在 `dc_batch_add` 里过完才允许入批，闸门条件与单条完全一致。`cleanup-opencode.sh` 删备份/快照目录时也 `source` 同一套 lib、走 `dc_delete_one`，所以「整个技能只有一个删除出口」是事实，不是口号。你在任务里也**不要**绕过它去补刀——那等于绕过下面所有闸门。

## 路径断言与 HOME 断言

**HOME 断言（启动即检查）**：`$HOME` 必须是绝对路径、存在、且不是 `/`，否则 `exit 2`。`HOME` 为空时 `$HOME/Library/...` 会塌缩成系统路径，这一条防的就是整批误删。

**路径断言（每次删除前）**，命中任一条即拒绝：

- 空路径、相对路径；
- `/` 本身、`$HOME` 本身；
- 长度不足 2；
- 含控制字符；
- 含未规范化的 `..` 或 `.` 组件（记 `unverified-owner`）。

**归属判断**按路径边界比较（`/Users/x` 不等于 `/Users/xy`），不做字符串前缀匹配。

## 保护清单

脚本内置 `scripts/data/protect.tsv`，格式是 TSV 三列：

```
pattern	scope	reason
$HOME/Library/Caches/com.apple.spotlight*	hard	spotlight-index
$HOME/Library/Caches/ms-playwright*	soft	playwright-browsers
```

- `pattern`：绝对路径 glob，`*` 匹配任意字符（含 `/`）；写目录路径时同时覆盖其下全部内容；`$HOME` 前缀会在加载时替换成真实路径。
- `scope=hard`：永远生效，**用户不可解除**。这些是删了会破坏 macOS 功能（Spotlight 索引、字体注册、CloudKit 同步、kitty 图形缓存、pypoetry venv、renv 链接库、Finder 元数据）或直接是用户数据（iCloud 文稿、iOS 备份、邮件、信息）。
- `scope=soft`：默认保护，用户可解除。浏览器二进制（playwright/camoufox/Cypress）、JetBrains 配置与缓存、ollama 模型、tealdeer 页缓存、Surge 缓存属这类——删了要重下。
- `reason`：命中后写进 `protected[].reason` 与台账，用户问「为什么没清这个」时照它解释。

**用户文件 `~/.config/disk-cleanup/protect.txt`** 规则：

- 不是 `!` 开头的行**只能追加保护**（scope=user，reason=`user-protect`），一旦加上永远生效；这类行按原样当**绝对路径 glob** 用（不会展开 `~`/`$HOME`，写带波浪号的行等于没写）。
- `!pattern` **只能解除 `scope=soft`**：`pattern` 可写 `$HOME` 字面量、`~/` 开头或绝对路径三种形式；比较时忽略**尾部 `*`**（`!$HOME/Library/Caches/ms-playwright*` 能解除同前缀的 soft 项）。
- `hard` 无论怎么写都解除不了——用户白名单不能把安全项关掉。
- 文件存在但**读不到** → `exit 2`（读不到不等于没有保护），不会「当作空文件继续跑」。
- `#` 开头是注释；改完下次运行生效。

命中后的正确做法只有一个：把路径与原因告诉用户，由用户决定是否改 protect 文件（且只能改 soft）。**不要**用 `rm`、`find -delete`、换等价路径、改 `--projects-roots` 等方式继续删。

## reason 枚举与应对

`items[].reason` 是一个编码「为什么是这个结果」的短标签。全表如下：

| reason | 含义 | agent 该怎么应对 |
|---|---|---|
| `ok` | 正常：已删、已预览，或查询完成 | 无 |
| `protected` | 命中保护清单（hard/soft/user） | **别绕着删**；向用户说明命中的 pattern 与原因，soft 项告诉用户可自行在 protect.txt 里解除 |
| `in-use` | 文件正被进程打开 | 提示用户关掉对应应用后重测；不要强删，不要「先 kill 再删」 |
| `denied-sandbox` | 沙箱拒绝写（`Operation not permitted`，父目录写测试不过） | 不是已清理；换可写沙箱或把命令交用户终端（见 SKILL.md「沙箱三步」） |
| `denied-readonly` | 目标在只读卷/只读挂载上 | 跳过即可，重试无用；告诉用户该位置本来不可写 |
| `not-found` | 路径在执行时已不存在（父目录也没了） | 不必重跑；如果用户坚持，重新查询一次再说 |
| `io-error` | 其它删除错误（权限、目录非空、路径异常等） | 把错误原文与路径交给用户，不要反复重试 |
| `timeout` | 命令超时被终止，文件保留 | 保留即未删；不要当成成功。**当前实现会让该步变 `partial`、退出码 1**，回执要写明 |
| `unverified-owner` | 路径含 `..`/`.` 组件，或归属未能证明 | 不改名、不拼路径绕；只能放弃这一条 |
| `sudo-required` | 该编码需要 sudo，当前环境拿不到 | 把脚本打印的完整命令交用户终端执行 |
| `unselected` | 用户没勾选这一项 | 保持不动；不要自行补跑 |
| `denied-tcc` | 系统隐私保护（TCC）拒绝，如 Safari/CloudKit 缓存 | 记为「受保护未计入」，**不当成 0**；不绕过 |
| `stale-guard` | 目录在扫描后发生变化，守卫主动放弃 | 重新查询一次，让用户看新数字 |
| `user-kept` | 用户保留项（`--projects-keep`）或项目层守卫判为「应留」：树内仍活跃、含被 git 跟踪的文件、目录本身是独立仓库 | 不要重试；按报告里的注明解释（是「有近期改动」还是「git 跟踪」） |
| `unknown` | 未能判定（如 `lsof` 不可用） | 按保守方向处理：不删、如实写「未判定」 |

`denied-tcc`、`stale-guard`、`unknown` 三个值属枚举预留（分别对应 TCC 拒绝、守卫放弃、探测不可用）；遇到时按上表应对，不要自己发明新的 reason 文案。另外 `not-found` 目前由项目层（路径已不存在）产出。

配套的 `items[].status` 取值是 `queried` / `dry-run` / `skipped-unselected` / `skipped-sudo` / `done` / `partial` / `failed` / `reported`（`reported` 用于只报告项，如 `orphans`）；聚合规则见 [cleanup.md](cleanup.md)。

## 台账与 `--history`

每个动作追加一行到 `~/Library/Logs/disk-cleanup/operations.log`（TSV，append-only，超过 5 MB 轮转为 `.1`）。写失败只警告一次，不中断清理——但回执里要说明「本次无法复盘」。若 `$HOME` 下不可写（常见于 workspace-write 沙箱），会自动退到 `${TMPDIR}/disk-cleanup-<uid>/operations.log` 并在 stderr 提示；`--history` 读的是同一位置的台账。

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh --history            # 最近 50 条
bash skills/disk-cleanup/scripts/mac_cleanup.sh --history --limit 20
bash skills/disk-cleanup/scripts/mac_cleanup.sh --history --json
```

文本每行：`时间 编码 动作 kb数 原因 [路径]`。`--history --json` 的结构：

```json
{"schema": 2, "mode": "history", "entries": [
  {"ts": "2026-11-12T17:00:01+08:00", "run_id": "20261112T170001-12345",
   "id": "caches", "action": "removed", "path": "", "size_kb": 123456, "reason": "ok"}
]}
```

- `action`：`removed`（已删）/ `skipped`（被跳过）/ `failed`（失败）/ `plan`（预览时的计划）；每次运行还会先写一行 `start`（`id` 为 `_run`）——所以 `--history` 的第一条常常就是**本次**运行的开始行，别把它当成上次的清理记录。
- `path`：整目录删除、预览计划、大件，以及**每一条失败或跳过的路径**都有值；JSON 里缺省是空字符串（台账里写 `-`）。
- `action`：`removed`（成功）/ `failed`（失败，逐条一条）/ `skipped-empty`（空目录删不动，不算失败）/ `plan`（预览）/ `start`（每次运行一行）。批量删除整批失败会回退逐条，失败的每一条都单独落行——否则事后查不到是哪几个路径。
- `size_kb`：整数 KB；取不到时台账写 `unknown`，JSON 里转为 **`-1`**（不是 0）。
- `reason`：同上面的枚举。
- `--limit` 默认 50；只读台账尾部，不整读入内存。

查询模式本身也会写一行 `start` 台账（用于复盘「什么时候查过」），这不代表发生了删除。
