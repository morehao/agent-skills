# 清理对象与执行方式

macOS 本机磁盘是主战场：系统缓存、日志、临时文件、Time Machine 快照、开发工具缓存通常就是大头；
本地数据库（如 opencode）属于「个别应用数据膨胀」，在同一套流程里按需处理，不单开一条线。

## 一、macOS 磁盘（`scripts/mac_cleanup.sh`）

### 模式语义（先看懂再跑）

| 模式 | 行为 | 什么时候用 |
|---|---|---|
| 无参数 | **只查询**：统计并打印各目录占用，不删任何东西 | 每次开场都先跑这个 |
| `--clean --dry-run` | 打印将要执行的清理命令，不实际删除 | 用户想看「会删什么」时 |
| `--clean` | 实际执行清理；`/tmp`、`/var/folders`、Time Machine 三步会要 sudo | 用户看完清单并明确同意后 |

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh                    # 只查询
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --dry-run  # 预览
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean            # 执行
```

> `--dry-run` 单独使用**没有意义**（没有 `--clean` 就不会执行任何清理），不要这样调用。

### 清理项与阈值

| 步骤 | 对象 | 策略 |
|---|---|---|
| 1 | `~/Library/Caches` | 只删 `mtime +1`（1 天前未改动），避免误伤正在写入的应用缓存 |
| 2 | `~/Library/Logs` | 只删 7 天前的旧日志文件，保留目录结构 |
| 3 | `/tmp` | 只删 1 天前的陈旧内容（需 sudo） |
| 4 | `/var/folders` | 按当前用户 uid 定向清理，见下文专节 |
| 5 | Time Machine 本地快照 | 存在快照时 `tmutil thinlocalsnapshots`（需 sudo） |
| 6 | `~/.Trash` | 清空 |
| 7 | 开发者缓存 | Xcode DerivedData、npm 缓存；Docker 此处仅提示 |
| 8 | 大体积项目 | iOS 固件、Homebrew、CocoaPods、Gradle、Docker `prune -a`、iOS DeviceSupport、不可用模拟器；**iOS 设备备份只提示** |
| 9 | 工具链/包管理器缓存 | go、uv、puppeteer、codex、opencode、playwright、pip、node-gyp、electron 等；pnpm 走 `store prune` |

第 9 步的目录清单是**白名单数组**：新增缓存目录应改脚本里的 `SAFE_CACHE_DIRS`，不要在任务里临时 `rm -rf` 未知路径。

### 权限与 sudo 交接

脚本在 `--clean` 且非 dry-run 时会先 `sudo -v` 预取权限；失败则打印告警并**跳过** `/tmp`、`/var/folders`、Time Machine 三步，其余步骤照常。

agent 环境没有 TTY，这一步必然失败——这是设计内的降级，不是 bug。正确做法：

1. 用只读模式出报告；
2. 把需要 sudo 的清理命令原文交给用户，让他在自己的终端跑；
3. 用户跑完再回来复测。

### `/var/folders` 为什么不能一把梭

这里混有当前用户与系统/其他用户的沙箱数据。脚本通过 `stat -f '%u'` 找出 **owner uid == 当前登录用户** 的那个容器目录（如 `/var/folders/_w/<hash>`），只清它下面的：

- `T` / `C`：7 天以上的过期缓存；
- `X`：`*code_sign_clone*` 代码签名残留（应用更新会自动重建）与 7 天前旧目录；
- `T/go-build*`：Go 编译缓存（`mtime +1`）。

系统/他人沙箱（`_zz` 下的 WebKit、ScreenTime 等受 TCC 保护）会被跳过，既不误删，也不刷 `Operation not permitted` 噪音。

### pnpm 为什么要走 corepack

裸 `pnpm` 在部分环境里是 Corepack shim，一调用可能因项目声明版本与缓存不一致而触发「Corepack is about to download…」交互弹窗。脚本用 `corepack pnpm store prune` 直接复用已有版本，无感、不弹窗。

## 二、本地数据库（`scripts/cleanup-opencode.sh`）

只在两种情况下处理：用户点名要清，或只读报告里这个库明显偏大（`du -sh ~/.local/share/opencode`）。
它不是磁盘清理的固定步骤，别顺手就跑。

opencode 用事件溯源把会话历史写进 SQLite，随使用膨胀，`event` 表通常占大头。脚本按保留天数删旧会话，
清孤儿 snapshot，最后 `VACUUM` 回收物理空间。

### 先确认三件事

1. **库是不是这个路径**：`ls -lh ~/.local/share/opencode/opencode.db`。多实例/自定义安装用 `OC_DATA_DIR` 覆盖。
2. **opencode 是否在跑**：脚本自己会检测并默认拒绝执行；先知道结论可以少一次失败。
3. **有没有等量空闲空间**：`VACUUM` 需要与库同量级的临时空间，剩余不足时会失败。

### 先备份（不可跳过）

```bash
mkdir -p ~/opencode-backup && sqlite3 ~/.local/share/opencode/opencode.db \
  ".backup '$HOME/opencode-backup/opencode.db'"
sqlite3 ~/opencode-backup/opencode.db "PRAGMA integrity_check;"   # 应返回 ok
```

推荐 `.backup`（在线备份，对运行中的库也安全）；整目录 `tar` 只在库很小时采用。

### 用法

```bash
bash skills/disk-cleanup/scripts/cleanup-opencode.sh          # 默认保留最近 7 天
bash skills/disk-cleanup/scripts/cleanup-opencode.sh 30       # 保留 30 天
bash skills/disk-cleanup/scripts/cleanup-opencode.sh --kill   # 检测到运行中时，询问后终止再清理
```

| 参数 | 说明 |
|---|---|
| `[天数]` | 保留最近 N 天（非负整数，默认 7） |
| `--kill` | 检测到 opencode 运行时，列出并询问后终止相关进程 |
| `--yes` / `-y` | 配合 `--kill`，跳过询问直接终止 |
| `OC_FORCE=1` | **危险**：跳过进程检测，仅用于对离线副本做干跑验证 |

### 进程检测

两类进程任一命中都会拦：CLI / serve（命令行匹配 `opencode-ai/bin/opencode`）、桌面版（`OpenCode.app` 及 Helper）。

不带 `--kill`：列出进程并拒绝执行。带 `--kill`：先列出、问一次、终止、**杀后复检**，仍有残留则中止——避免在活动连接上删库。

> ⚠️ 若脚本由运行中的 opencode 会话触发，`--kill` 会终止其宿主进程，也就是当前会话本身。
> 这种情况把命令交给用户，让他在独立终端里跑。

### 脚本做了什么

1. 事务内删除（`BEGIN IMMEDIATE`，失败整体回滚）：`event`、`event_sequence`、`part`、`message`、`session_message`、`session_input`、`session_share`、`session_context_epoch`、`todo`，最后 `session`；
2. 删除孤儿 snapshot 目录（目录名不再对应 `project` 表里的 id）；
3. `VACUUM` 回收物理空间（耗时随库大小增长）。

删除前后都打印各表行数，用于核对。**只动会话相关表**，不碰 account / auth / credential 等鉴权数据。

### 效果参考

实测一份 12G 级库（保留 7 天、对副本干跑）：`session` 8361 → ~470，`message` 190994 → ~19940，
`part` 778701 → ~81081，`event` 1467242 → ~304961；库体积约 12G → 4G，`integrity_check: ok`。

数值随使用强度差异很大，只作量级参考，不要当作预期承诺。

## 三、只报告、不代删（手动清单）

判据只有一条：**删掉之后用户能不能自己恢复**。能自动重建的（缓存、构建产物）→ 脚本；不可逆或含用户数据的 → 只报告。

| 类别 | 典型路径 | 交给用户的方式 |
|---|---|---|
| iOS 设备备份 | `~/Library/Application Support/MobileSync/Backup` | Finder / iTunes「设备」里删旧备份 |
| 聊天数据 | `~/Library/Containers/com.tencent.xinWeChat/...`、`com.tencent.WeWorkMac/...` | 应用内「设置 → 存储空间」 |
| 虚拟机/容器镜像 | `~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data` | OrbStack 内删 machine，或 `orb delete <machine>`；**不要**在 Finder 里删目录 |
| 浏览器配置 | `~/Library/Application Support/<Browser>` | 浏览器「清除浏览数据 → 缓存」 |
| 文档类应用 | `~/Library/Application Support/Notion/Partitions` 等 | 退出应用后删缓存分区，或应用内清理 |
| 邮件 / 信息附件 | `~/Library/Mail`、`~/Library/Messages/Attachments` | 应用内删除 |

只读探测（先量后说）：

```bash
du -sh ~/Library/Application\ Support/MobileSync/Backup 2>/dev/null
du -sh ~/Library/Containers/com.tencent.xinWeChat/Data/Documents 2>/dev/null
du -sh ~/Library/Group\ Containers/HUAQ24HBR6.dev.orbstack/data 2>/dev/null
du -sh ~/Library/Application\ Support/* 2>/dev/null | sort -hr | head -20
```

路径含空格必须加引号。给出具体数字时注明是**本次实测**——不同机器差异很大，别把某次快照当通用结论。

## 验证收益

1. 清理前后各跑一次 `df -h /`，差值才是真实释放量；
2. 差值不明显时先确认执行清单（脚本末尾会逐条列出「实际执行并已确认的清理项」），再考虑系统记账延迟；
3. 建议重启一次再在「关于本机 → 储存空间」复核——该统计本身有延迟，不能用它判断本次清理是否生效。

## 已知边界

- 只处理白名单里的目录；新出现的大户需先人工确认可再生成，再考虑加进脚本。
- 不处理系统「可清除空间」、睡眠镜像、APFS 快照策略——由 macOS 自己回收。
- 不处理外接盘、网络卷、云盘同步目录。
