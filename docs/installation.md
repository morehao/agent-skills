# 安装与维护

本仓是技能与 opencode 指令的唯一真源：通过软链接接入本机，`git pull` 后无需重新复制。dsh 的斜杠命令插件在独立仓 [morehao/dsh-commands](https://github.com/morehao/dsh-commands)，本仓只提供它依赖的技能。

## 技能安装位（统一）

本机**只有一个**技能安装位：`~/.agents/skills`（可用 `AGENTS_SKILLS_DIR` 覆盖）。

- **为什么是它**：这是 `skills` CLI（`-g -a universal`）的全局目录，也是 dsh 默认扫描的技能根；其它工具只要指过来，看到的都是同一份。
- **里面放什么**：本仓 `skills/*` 的**软链**（本仓仍是唯一真源，改即生效），加上第三方技能（`skills` CLI 装成的真实目录，如 `officecli`、`weather-query`），两者互不干扰。
- **怎么装 / 校验**：

```bash
./scripts/skills-link.sh             # 软链 skills/* -> ~/.agents/skills/*（幂等）
./scripts/skills-link.sh --check     # 只检查：缺失/指向错误/悬空/被真实目录占位 → 退出 1
./scripts/skills-link.sh --force     # 同名真实目录先备份成 <name>.bak-<时间戳> 再软链（不删数据）
```

> `--force` 用在「之前用 `skills` CLI 装过同名技能」的机器上：那些是真实目录快照，脚本默认不覆盖，`--force` 只改名备份。

各工具只需要「看得见这个目录」：

| 工具 | 怎么看见 | 要做什么 |
|---|---|---|
| opencode | 配置文件里的 `skills` 数组 | 加 `"skills": ["~/.agents/skills"]`（或等价 `"compatibility": { "agents": ["~/.agents"] }`）；**不加就看不到** |
| dsh | 默认扫描 `~/.agents/skills` | 无需配置；插件侧 `/skill-init` 也不必再往 `$DSH_HOME/skills` 建第二份软链 |
| 其它（Claude Code 等） | 视工具而定 | 指向同一目录即可 |

opencode 的**命令**没法来自 `~/.agents`——它只认配置目录下的 `command/`，所以命令仍由 `opencode-install.sh` 软链。

## opencode

配置根默认 `~/.config/opencode/`，可用 `OPENCODE_CONFIG` 覆盖。命令清单、参数与「命令 → skill 分支」映射见 [opencode 指令集](../commands-opencode/README.md)。

### 一键接入

```bash
./scripts/opencode-install.sh                  # 技能 + 命令
./scripts/opencode-install.sh --skills-only     # 只挂技能（等价 skills-link.sh）
./scripts/opencode-install.sh --commands-only   # 只挂命令
./scripts/opencode-install.sh --check           # 只检查，不修改
./scripts/opencode-install.sh --dry-run         # 只打印将执行的操作
```

脚本行为：

- **技能**：调用 `scripts/skills-link.sh`，链到统一安装位 `~/.agents/skills`（不再建 `<config>/skills`）；
- **命令**：软链 `commands-opencode/git` → `<config>/command/git`，`handoff.md`、`cleanup.md` 同理；
- 清理指向本仓但目标已不存在的悬空软链；目标已有同名真实目录/文件时跳过，不覆盖；
- 检测到旧布局（`<config>/skills` 下还有技能软链）或 opencode 未配置技能根时，打印处理提示（不影响退出码）；
- `--check` 只报告问题，问题数 >0 退出 1。

### 手工等价

```bash
# 技能：软链到统一安装位
mkdir -p ~/.agents/skills
for name in git-kit handoff disk-cleanup project-insight project-wiki svg-maker tech-design; do
  ln -sfn /path/to/agent-skills/skills/"$name" ~/.agents/skills/"$name"
done

# 命令：opencode 配置目录
mkdir -p ~/.config/opencode/command
ln -sfn /path/to/agent-skills/commands-opencode/git ~/.config/opencode/command/git
ln -sfn /path/to/agent-skills/commands-opencode/handoff.md ~/.config/opencode/command/handoff.md
ln -sfn /path/to/agent-skills/commands-opencode/cleanup.md ~/.config/opencode/command/cleanup.md
```

> `mkdir -p` 别省：新机器上 `~/.agents/skills/` 与 `~/.config/opencode/command/` 通常都不存在，直接 `ln` 会失败。

### 约定

- **技能不落在 opencode 配置目录**：`<config>/skills` 已不再是本仓的落点；残留的旧软链会让同一技能被登记两次，`opencode-install.sh --check` 会提示删除。
- **`command/` 还是 `commands/`**：opencode v2.x 同时扫描两者（源码 `scan("{command,commands}/**/*.md")`，命令名会剥掉这层前缀），本仓用 `command/`，两种布局都能识别。
- **`skills/` 下只放技能目录**：不放置松散说明文件。脚本只遍历目录，正是为了避免 `skills/*` 通配把松散文件也链过去。
- **软链 vs 复制**：软链跟随本仓更新；不想跟随时可 `cp -r`，之后需手动同步。
- **卸载**：`rm ~/.agents/skills/git-kit`、`rm ~/.config/opencode/command/git` 等，删掉对应软链即可。

### 为什么是命令文件而不是插件

官方把两者分得很清楚：**命令**是提示词模板（markdown + `description`/`agent`/`model`/`subtask`，支持 `$ARGUMENTS`、`$1..$N`、`!shell`、`@file`），放文件即注册；**插件**是生命周期 hook + 自定义 tool 的 JS/TS 运行时代码。官方**没有**「插件注册斜杠命令」的 API：相关 PR [#10261](https://github.com/anomalyco/opencode/pull/10261) 已关闭，[#24065](https://github.com/anomalyco/opencode/issues/24065) 仍在问 `config` hook 里改 `cfg.command` 算不算官方支持（源码里是 `as any` + `Effect.ignore`，属未文档化副作用）。本仓命令都是 5 行委托壳、零运行期逻辑，命令文件正是精确匹配的 primitive；换成插件只会多出 JS 加载与依赖风险。dsh 侧用插件是**平台约束**（dsh 只能由插件注册斜杠命令），不要反推。

在 opencode v2.1.3 的二进制上复核过（2026-10-23）：命令来源只有 config 文档与 `{command,commands}/**/*.md` 扫描，没有 `ConfigCommandV1`、也没有 `command.execute.before` 这类注册面——所以「把命令做成 opencode 插件」在当前版本**做不到**，不是取舍问题。

另一个官方去重手段是 skill 的 `metadata: opencode/slash: "true"`（把一个 SKILL.md 同时暴露成 `/name`），但两处不适用：本仓 9 条 git 命令共用**一个** `git-kit` skill，slash 只能给出 `/git-kit` 一条，丢意图粒度；且**截至 opencode v2.1.3（2026-10-22）该特性尚未发版**——文档站已写，但二进制里没有这个 key，实测 `opencode api GET /api/command` 返回的命令列表不含带该 metadata 的 skill（skill 本身能被 `GET /api/skill` 发现）。等它落地后可评估去掉 `handoff.md`（一 skill 一意图），git 九条仍须保留。

**与 dsh 的一处刻意差异（别照抄）**：dsh 的 `handoff` 命令需要 `readFallback` 兜底，因为 dsh 的 `skill` 工具会拒载带 `disable-model-invocation: true` 的技能。opencode 不会：v2.1.3 里该 frontmatter 只被转成 `autoinvoke: false` 用于把技能移出模型可见的**技能清单**（guidance），`skill` 工具按 id 直接取用、不做这项过滤（源码核对：`SkillInstructions.load` 过滤 autoinvoke，`opencode.tool.skill` 的 `get(id)` 不过滤）。所以 `/handoff` 在 opencode 上按「用 `skill` 工具加载 `handoff`」写即可，**不要**照搬 `readFallback`。

复查（用一次性 HOME，不碰真实配置）：

```bash
BIN=~/.opencode/bin/opencode   # 或 PATH 里的 opencode
export HOME=/tmp/octcheck
mkdir -p "$HOME/.config/opencode/skills/probe"
printf -- '---\nname: probe\ndescription: probe\nmetadata:\n  opencode/slash: "true"\n---\nprobe\n' \
  > "$HOME/.config/opencode/skills/probe/SKILL.md"
$BIN service set port 49399 && $BIN service start
$BIN api GET /api/command | grep -o '"name":"[^"]*"'   # 出现 probe 才说明已支持
$BIN service stop && rm -rf /tmp/octcheck
```

只有出现「命令模板表达不了的需求」（要挂事件 hook、要把 `release-preflight.sh` 包成自定义 tool、要按仓库状态动态生成命令）才考虑插件，且形态是**插件 + 命令文件共存**，命令仍是入口。

## dsh（可选）

dsh 的斜杠命令由独立插件提供：源码在 [morehao/dsh-commands](https://github.com/morehao/dsh-commands)，npm 包为 `@morehao/dsh-commands`。命令包括 `/git-message`、`/git-commit-push`、`/git-branch`、`/git-pr-create`、`/git-pr-merge`、`/git-release`、`/git-tag`、`/git-slim`、`/git-star-classify`、`/handoff`（完整列表以插件仓为准）。

插件是自包含意图表（命令名 + 对应 skill 分支 key，`skill` 省略时默认 git-kit）；执行时向当前 agent 注入一条「加载对应 skill 并按其分支执行」的指令，与 opencode 入口共用同一 skill。本仓只提供技能：改 `skills/git-kit/` 或 `skills/handoff/` 立即对其生效；改插件本体请到插件仓（改完需重启 dsh）。插件发版流程见其本仓 `PUBLISHING.md`。

### 一键接入

```bash
./scripts/dsh-install.sh --skills-only   # 只挂技能：零副作用、不需要 dsh CLI
./scripts/dsh-install.sh                 # 全量：技能 + 安装 npm 插件（profile 自动解析）
./scripts/dsh-install.sh --profile desktop
./scripts/dsh-install.sh --plugin-link <dsh-commands 仓路径>   # 插件仓开发：改 lib/index.js 即时生效
```

脚本做两件事：

1. 调用 `scripts/skills-link.sh` 把 `skills/<name>` 软链到统一安装位 `~/.agents/skills`（dsh 默认扫描）；
2. `dsh plugin --profile <profile> add @morehao/dsh-commands`。

`--skills-only` 只做第 1 步。插件从 npm 安装，技能仍须由本仓软链提供（dsh 不从 `node_modules` 扫描 skill）。以前版本的脚本会往 `$DSH_HOME/skills` 建第二份软链；现在默认不建，检测到残留会给出 `rm` 提示（同一技能登记两次没有好处）。

> **profile 不硬编码**：优先级 `--profile <name>` > `$DSH_PROFILE` > `$DSH_HOME/profiles` 下唯一存在的 profile。多个或零个时报错并列出候选，不会替你新建。查看已有 profile：`ls ~/.dsh/profiles/`（桌面版是 `desktop`）。
>
> **`dsh` CLI 不要求先在 PATH**：找不到时脚本回退到 macOS 桌面版 app 包内的 `runtime/cli/bin/dsh`，并提示先退出客户端再登记插件，避免并发改写 profile；确实找不到才报错，此时第 1 步的技能软链已经完成。

### 手工等价（只挂技能）

```bash
mkdir -p ~/.agents/skills
for name in git-kit handoff disk-cleanup project-insight project-wiki svg-maker tech-design; do
  ln -sfn /path/to/agent-skills/skills/"$name" ~/.agents/skills/"$name"
done
```

### 技能根与热加载

- **统一安装位 `~/.agents/skills`**（本仓技能的落点，也是 canonical 目录）
- `~/.dsh/skills`（用户级）、`<项目根>/.dsh/skills`（项目级）仍会被扫描，但不再作为本仓技能的落点
- `<项目根>/.agents/skills` 也会被扫描（项目级第三方技能）

软链注册的技能带 `linked` 标记、只读（禁止编辑/删除），避免误改真源。技能是热加载的：新增软链后无需重启，新会话与技能面板立即能看到；只有插件 `lib/index.js` 的改动才需要重启 dsh。

### 卸载

```bash
dsh plugin --profile <profile> remove @morehao/dsh-commands
rm ~/.agents/skills/<name>
```

旧版曾以 `dsh-git-commands` / `@morehao/dsh-git-commands` 安装：对应 `dsh plugin --profile <profile> remove dsh-git-commands` / `remove @morehao/dsh-git-commands`。脚本在重装时会自动移除旧名，避免新旧 bundle 并存。

## 命令契约校验

命令是**委托壳**，branch 只写在正文的自然语言里。技能改了分支名、README 加删命令而壳没跟，命令照样能点、结果不对。在仓库根目录跑：

```bash
node scripts/check-opencode-commands.mjs
node scripts/check-opencode-commands.mjs --dsh ../dsh-commands   # 顺带比对另一仓
```

校验项：

- frontmatter 只允许官方字段，`description` 非空、单行；
- 正文 `**<branch> 分支**` 对应 `skills/<skill>/references/<branch>.md` 存在（单文件技能只查 `SKILL.md`）；
- `$ARGUMENTS` 独立成行；无参数命令必须显式写「本命令无参数」；
- 两份 README 的表格与命令文件**双向**一一对应；
- 「指令 → skill 分支」联动表的 branch/skill 与正文声明一致；
- `--dsh`：branch/skill 不一致判失败，description 差异只提示；并检查 dsh 有、opencode 没有的委托命令。

退出码：`0` 通过（可带提示）/ `1` 有错误 / `2` 用法错误。

CI（[`.github/workflows/commands.yml`](../.github/workflows/commands.yml)）在 push 到 `main` 和所有 PR 上跑同一脚本，并把 `morehao/dsh-commands` checkout 到 `.ci/dsh-commands` 做跨仓比对；本地等价命令就是上面第二条。

## 新增或修改命令

1. 逻辑写进 `skills/git-kit/references/<branch>.md`（必要时补 `scripts/`）。
2. 在 `commands-opencode/git/` 新增 `<name>.md`：frontmatter 只写官方字段，正文声明 `**<branch> 分支**`、用 `skill` 工具加载 `git-kit`、按需写 `$ARGUMENTS`。
3. 更新 `commands-opencode/README.md` 的两张表（指令清单 + 联动表）和根 `README.md` 的命令表。
4. 跑 `node scripts/check-opencode-commands.mjs`。
5. 同步 dsh 入口：到 dsh-commands 仓的 `COMMANDS` 表加一行，并跑它的 `check-skill-contract.mjs`。

## 改脚本注意

- macOS 自带 bash 3.2：不用 `mapfile` / 关联数组 / `${var,,}`；`set -u` 下不要展开空数组。
- 变量后紧跟中文等非 ASCII 字符必须写 `${var}`，否则 bash 3.2 会把该字符并入变量名并报 `unbound variable`。
- 测试安装脚本用临时配置根，不要拿真实配置试：

```bash
OPENCODE_CONFIG="$(mktemp -d)" AGENTS_SKILLS_DIR="$(mktemp -d)" ./scripts/opencode-install.sh
AGENTS_SKILLS_DIR="$(mktemp -d)/skills" ./scripts/skills-link.sh
DSH_HOME="$(mktemp -d)" AGENTS_SKILLS_DIR="$(mktemp -d)/skills" ./scripts/dsh-install.sh --skills-only
```

> 只有 `--check` 是只读的，可以直接对着真实 `~/.agents/skills` 跑；其余模式务必带临时 `AGENTS_SKILLS_DIR`。
