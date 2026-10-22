# 清理对象与执行方式

macOS 本机磁盘是主战场：系统缓存、日志、临时文件、Time Machine 快照、开发工具缓存通常就是大头；
本地数据库（如 opencode）属于「个别应用数据膨胀」，在同一套流程里按对象处理，不单开一条线。

## 一、macOS 磁盘（`scripts/mac_cleanup.sh`）

### 模式语义（先看懂再跑）

| 模式 | 行为 | 什么时候用 |
|---|---|---|
| 无参数 | **只查询**：统计并打印各目录占用，不删任何东西 | 用户选择「只看占用」或「选勾清理」后先跑这个 |
| `--list` | 只打印清理项编码与说明 | 核对勾选结果与编码 |
| `--clean --dry-run [--only ids]` | 打印将要执行的清理命令，不实际删除 | 勾选后、执行前自查 |
| `--clean --only ids` | 只执行勾选的清理项 | 用户勾选完成后 |
| `--clean` | 不带 `--only/--skip` = 执行全部清理项 | 只建议用户本人在终端手动使用 |

```bash
bash skills/disk-cleanup/scripts/mac_cleanup.sh                                  # 1) 清单
bash skills/disk-cleanup/scripts/mac_cleanup.sh --list                           # 2) 编码
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --dry-run --only caches,logs,trash  # 3) 自查
bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only caches,logs,trash            # 4) 执行
```

> `--dry-run` 单独使用**没有意义**；`--only/--skip` 不带 `--clean` 也不生效（脚本会提示仍是只读查询）。
> 编码写错时脚本直接 `exit 1` 并列出可用编码——避免「以为清了其实没清」。

### 选择语义（用户勾选怎么落到命令）

- `--only a,b,c`：**只跑列出的项**，其余每步打印 `[跳过]`，报告里汇总为「未勾选（未执行）」。
- `--skip a,b`：排除指定项；与 `--only` 同给时，先取 `--only` 再减 `--skip`。
- 两个都不给 = 全部（脚本会打警告）。**agent 代跑时必须显式给 `--only`**，这就是「最终清理项由用户决定」的落地方式。
- 编码是**勾选单位，不能拆到编码内部**：例如 `bigbuild` 里 Homebrew 与 Gradle 同进同出。用户只想清其中一项时，只能该项整组不勾、由用户自己在终端跑那条具体命令；**不要**为了满足粒度在任务里临时 `rm -rf`。
- 组合示例：`--clean --skip docker,bigbuild` = 全清但保留 Docker 与构建大件。

### 清理项编码

| 编码 | 覆盖对象 | 策略 / 阈值 | sudo | 删除后代价 |
|---|---|---|---|---|
| `caches` | `~/Library/Caches` | 只删 `mtime +1`（1 天前未改动），避免误伤正在写入的应用缓存 | 否 | 应用首次打开变慢 |
| `logs` | `~/Library/Logs` | 只删 7 天前的旧日志文件，保留目录结构 | 否 | 基本无感 |
| `tmp` | `/tmp` | 只删 1 天前的陈旧内容 | **是** | 运行中程序的临时文件会重建 |
| `varfolders` | 当前用户 `/var/folders` 容器 | `T`/`C` 清 7 天以上；`X` 清 `*code_sign_clone*` 与 7 天前目录；`T/go-build*` 清 `mtime +1` | 否 | 无 |
| `snapshots` | Time Machine 本地快照 | 存在快照时 `tmutil thinlocalsnapshots / 999999999999 4` | **是** | 回滚粒度变粗，系统会重建 |
| `trash` | `~/.Trash` | 清空 | 否 | **不可恢复** |
| `xcode` | Xcode `DerivedData` | 整个删掉 | 否 | 下次构建全量重编 |
| `toolcache` | 语言工具链/包管理器白名单目录 + `pnpm store prune` | 删目录（重建即恢复；pnpm 只回收未引用包） | 否 | 重新下载/编译 |
| `bigbuild` | ipsw、Homebrew、CocoaPods、Gradle、iOS DeviceSupport、不可用模拟器 | ipsw / CocoaPods / Gradle / DeviceSupport 删目录；`brew cleanup --prune=all`；`xcrun simctl delete unavailable` | 否 | 重新下载/构建；Homebrew 旧版本删了不能直接回滚 |
| `docker` | 未使用镜像、停止的容器、构建缓存、未用网络 | `docker system prune -a --force` | 否 | 镜像要重新 pull |

`toolcache` 的白名单（**新增缓存目录必须改脚本里的 `SAFE_CACHE_DIRS`，不要在任务里临时 `rm -rf` 未知路径**）：

```text
~/.npm/_npx  ~/.npm/_cacache  ~/.cache/uv  ~/.cache/puppeteer  ~/.cache/node
~/.cache/codex-runtimes  ~/.cache/opencode
~/Library/Caches/go-build  goimports  gopls  golangci-lint
~/Library/Caches/ms-playwright  pip  node-gyp  electron
```

第 8 步里 iOS 设备备份**不属于 `bigbuild`**：它含用户数据，只报告大小与路径，不代删。

### 权限与 sudo 交接

脚本只在**所选清理项包含 `tmp`/`snapshots` 且要真实执行**时才 `sudo -v` 预取权限；失败则打印告警并**跳过**这两步，命令原文写进报告，其余步骤照常。

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

### pnpm 为什么要走 corepack

裸 `pnpm` 在部分环境里是 Corepack shim，一调用可能因项目声明版本与缓存不一致而触发「Corepack is about to download…」交互弹窗。脚本用 `corepack pnpm store prune` 直接复用已有版本，无感、不弹窗。

## 二、本地数据库（`scripts/cleanup-opencode.sh`）

它是**勾选项之一，不是固定步骤**：默认不勾，用户勾了（或明确点名）才做。库小于约 500MB 时在选项里标「收益有限」，不建议为了它关一次 opencode。它在对话里的编码是 `opencode-db`，**不传给 `mac_cleanup.sh`**，由本技能单独执行。

opencode 用事件溯源把会话历史写进 SQLite，随使用膨胀，`event` 表通常占大头。脚本按保留天数删旧会话，清孤儿 snapshot，最后 `VACUUM` 回收物理空间。

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

判据只有一条：**删掉之后用户能不能自己恢复**。能自动重建的（缓存、构建产物）→ 勾选清单；不可逆或含用户数据的 → 只报告，**并且不进勾选列表**（避免让人误以为勾了就会代删）。

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
2. 差值不明显时先确认执行清单（脚本末尾会分三类列出：实际执行、未勾选、已勾选但未完成），再考虑系统记账延迟；
3. 建议重启一次再在「关于本机 → 储存空间」复核——该统计本身有延迟，不能用它判断本次清理是否生效。

## 已知边界

- 只处理白名单里的目录；新出现的大户需先人工确认可再生成，再考虑加进脚本与编码表。
- 不处理系统「可清除空间」、睡眠镜像、APFS 快照策略——由 macOS 自己回收。
- 不处理外接盘、网络卷、云盘同步目录。
