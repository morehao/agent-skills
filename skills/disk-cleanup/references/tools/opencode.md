# opencode（本地数据库 + 缓存）

> 编码：数据库编码 `opencode-db`（只在对话里用，**不传给 `mac_cleanup.sh`**，由 `cleanup-opencode.sh` 单独执行）；`.cache/opencode` 缓存归 `node`。

## 覆盖对象（分属编码）

| 对象 | 所属编码 / 脚本 |
|---|---|
| `~/.local/share/opencode/opencode.db`（SQLite 会话库） | `opencode-db`（`cleanup-opencode.sh`） |
| `~/.cache/opencode` | `node` |

## 编码归属：现状 → 终局

- **现状**：数据库是独立编码 `opencode-db`（走独立脚本）；缓存 `.cache/opencode` 归 `node` 编码。
- **只想清本工具**：数据库直接跑 `cleanup-opencode.sh`；缓存随 `--only node` 一并清。
- **终局（第 2 期不涉及）**：数据库粒度已对齐，无需拆分。

---

## 本地数据库（`scripts/cleanup-opencode.sh`）

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
