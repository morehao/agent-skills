# 安装与维护

本仓是技能与 opencode 指令的**编辑源**（版本化、可 review）；**运行时真源在技能本源目录** `~/.agents/skills`——本仓内容用 `skills` CLI 发布到那里，再有软链分发给各 agent。dsh 的斜杠命令插件在独立仓 [morehao/dsh-commands](https://github.com/morehao/dsh-commands)，本仓只提供它依赖的技能。

## 技能模型：本源 + 分发软链

```
本仓 skills/<name>
   │ ./scripts/skills-install.sh（skills CLI 安装）
   ▼
~/.agents/skills/<name>            ← 本源：真实内容（第三方技能也装在这）
   ├─软链─> ~/.config/opencode/skills/<name>
   └─软链─> ~/.dsh/skills/<name>          ./scripts/skills-fanout.sh 负责
```

- **改本仓不会自动生效**：先 push 到 `morehao/agent-skills`，再跑 `./scripts/skills-install.sh` 发布到本源。
- 本源里同时存在第三方技能（`skills` CLI 装的，如 `officecli`、`weather-query`），与本仓技能互不干扰。
- 各 agent 目录**只放指向本源的软链**，内容不复制。好处：其它 agent 永远看到已发布的稳定内容，不会被某个工作区的半成品影响。

### 发布（本仓 → 本源）

```bash
./scripts/skills-install.sh              # 用 skills CLI 把 skills/* 全部安装到 ~/.agents/skills
./scripts/skills-install.sh --check      # 只读：比对本源与本仓，缺失/落后 → 退出 1
./scripts/skills-install.sh --dry-run    # 只打印将执行的 skills 命令
./scripts/skills-install.sh --source <owner/repo|url>   # 换来源，默认 morehao/agent-skills
```

安装命令与 dsh-commands 的 `/skill-init` 一致：`npx -y skills add <来源> --skill <名> … -g -a universal -y`（`-a universal` 只写本源，不往各 agent 目录撒链）。脚本发布前会提示「工作区脏 / 本地领先 `origin/main`」——**CLI 装的是远端内容**，没 push 的内容不会被发布。

### 分发（本源 → 各 agent）

```bash
./scripts/skills-fanout.sh                        # 默认 opencode + dsh
./scripts/skills-fanout.sh --agents opencode,dsh,claude
./scripts/skills-fanout.sh --check                # 缺失/指向错误/悬空/被真实目录占位 → 退出 1
./scripts/skills-fanout.sh --dry-run
```

幂等：已指向本源跳过；指向别处（例如以前直接指向本仓的旧链）自动改指向本源；指向本源但技能已不在的悬空链清理；目标已有同名真实目录则跳过、不覆盖。

| 工具 | 技能目录 | 说明 |
|---|---|---|
| opencode | `~/.config/opencode/skills`（`OPENCODE_CONFIG`） | 只认配置目录，必须建链；也可改用 config 的 `skills: ["~/.agents/skills"]`，二选一别同时用 |
| dsh | `~/.dsh/skills`（`DSH_HOME`） | dsh 本身也扫本源；这层链让技能在一处可查、可肉眼核对 |
| claude 等 | `~/.claude/skills`（`CLAUDE_HOME`） | `--agents claude` 时才建 |

## opencode

配置根默认 `~/.config/opencode/`，可用 `OPENCODE_CONFIG` 覆盖。命令清单、参数与「命令 → skill 分支」映射见 [opencode 指令集](../commands-opencode/README.md)。

### 一键接入

```bash
./scripts/skills-install.sh                     # ① 发布技能到本源（首次、以及本仓有更新时）
./scripts/opencode-install.sh                   # ② 技能软链 + 命令软链
./scripts/opencode-install.sh --skills-only     # 只做技能软链（= skills-fanout.sh --agents opencode）
./scripts/opencode-install.sh --commands-only   # 只软链命令
./scripts/opencode-install.sh --check           # 只检查，不修改
./scripts/opencode-install.sh --dry-run         # 只打印将执行的操作
```

脚本行为：

- **技能**：调用 `scripts/skills-fanout.sh --agents opencode`，建 `<config>/skills/<name>` → 本源的软链；
- **命令**：软链 `commands-opencode/git` → `<config>/command/git`，`handoff.md`、`cleanup.md` 同理；
- 清理悬空软链；目标已有同名真实目录/文件时跳过，不覆盖；
- `--check` 只报告问题，问题数 >0 退出 1；本源缺失会直接报错并提示先跑 `skills-install.sh`。

### 手工等价

```bash
# 技能：先发布到本源，再在 opencode 侧建软链
npx -y skills add morehao/agent-skills --skill git-kit --skill handoff --skill disk-cleanup \
  -g -a universal -y
mkdir -p ~/.config/opencode/skills
for name in git-kit handoff disk-cleanup project-insight project-wiki svg-maker tech-design; do
  ln -sfn ~/.agents/skills/"$name" ~/.config/opencode/skills/"$name"
done

# 命令：opencode 配置目录
mkdir -p ~/.config/opencode/command
ln -sfn /path/to/agent-skills/commands-opencode/git ~/.config/opencode/command/git
ln -sfn /path/to/agent-skills/commands-opencode/handoff.md ~/.config/opencode/command/handoff.md
ln -sfn /path/to/agent-skills/commands-opencode/cleanup.md ~/.config/opencode/command/cleanup.md
```

> `mkdir -p` 别省：新机器上 `~/.config/opencode/command/` 通常不存在，直接 `ln` 会失败。

### 约定

- **opencode 配置目录里没有技能内容**：`<config>/skills` 下只有指向本源的软链；技能真内容在 `~/.agents/skills`。
- **`command/` 还是 `commands/`**：opencode v2.x 同时扫描两者（源码 `scan("{command,commands}/**/*.md")`，命令名会剥掉这层前缀），本仓用 `command/`，两种布局都能识别。
- **`skills/` 下只放技能目录**：不放置松散说明文件。脚本只遍历目录，正是为了避免 `skills/*` 通配把松散文件也链过去。
- **卸载**：`rm ~/.config/opencode/skills/git-kit` 只解链；本源内容用 `skills` CLI 卸；命令删 `~/.config/opencode/command/git` 等。

### 为什么是命令文件而不是插件

官方把两者分得很清楚：**命令**是提示词模板（markdown + `description`/`agent`/`model`/`subtask`，支持 `$ARGUMENTS`、`$1..$N`、`!shell`、`@file`），放文件即注册；**插件**是生命周期 hook + 自定义 tool 的 JS/TS 运行时代码。官方**没有**「插件注册斜杠命令」的 API：相关 PR [#10261](https://github.com/anomalyco/opencode/pull/10261) 已关闭，[#24065](https://github.com/anomalyco/opencode/issues/24065) 仍在问 `config` hook 里改 `cfg.command` 算不算官方支持（源码里是 `as any` + `Effect.ignore`，属未文档化副作用）。本仓命令都是 5 行委托壳、零运行期逻辑，命令文件正是精确匹配的 primitive；换成插件只会多出 JS 加载与依赖风险。dsh 侧用插件是**平台约束**（dsh 只能由插件注册斜杠命令），不要反推。

在 opencode v2.1.3 的二进制上复核过（2026-10-23）：命令来源只有 config 文档与 `{command,commands}/**/*.md` 扫描，没有 `ConfigCommandV1`、也没有 `command.execute.before` 这类注册面——所以「把命令做成 opencode 插件」在当前版本**做不到**，不是取舍问题。

另一个官方去重手段是 skill 的 `metadata: opencode/slash: "true"`（把一个 SKILL.md 同时暴露成 `/name`），但两处不适用：本仓 9 条 git 命令共用**一个** `git-kit` skill，slash 只能给出 `/git-kit` 一条，丢意图粒度；且**截至 opencode v2.1.3（2026-10-22）该特性尚未发版**——文档站已写，但二进制里没有这个 key，实测 `opencode api GET /api/command` 返回的命令列表不含带该 metadata 的 skill（skill 本身能被 `GET /api/skill` 发现）。等它落地后可评估去掉 `handoff.md`（一 skill 一意图），git 九条仍须保留。

**与 dsh 的一处差异（留档，现已不是前提）**：dsh 的 `handoff` 命令曾必须用 `readFallback` 兜底，因为 `skills/handoff/SKILL.md` 当时带 `disable-model-invocation: true`，dsh 的 `skill` 工具会直接拒载（`Error: skill "handoff" is not available for model invocation`）。该 frontmatter 已于 2026-10-25 移除，`handoff` 恢复为模型可见、可自行触发；插件侧的 read 兜底可以留着，但不再承担「唯一加载路径」。顺带记住一条 opencode 语义：v2.1.3 里 `disable-model-invocation` 只被转成 `autoinvoke: false`，用于把技能移出模型可见的**技能清单**（guidance），`skill` 工具按 id 直接取用、不做这项过滤（源码核对：`SkillInstructions.load` 过滤 autoinvoke，`opencode.tool.skill` 的 `get(id)` 不过滤）——所以即便以后重新加回该 frontmatter，opencode 上仍能显式加载，dsh 上不能。

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

插件是自包含意图表（命令名 + 对应 skill 分支 key，`skill` 省略时默认 git-kit）；执行时向当前 agent 注入一条「加载对应 skill 并按其分支执行」的指令，与 opencode 入口共用同一 skill。本仓只提供技能：发布到本源后对其生效；改插件本体请到插件仓（改完需重启 dsh）。插件发版流程见其本仓 `PUBLISHING.md`。

### 一键接入

```bash
./scripts/skills-install.sh              # ① 先发布技能到本源
./scripts/dsh-install.sh --skills-only   # ② 只挂技能：零副作用、不需要 dsh CLI
./scripts/dsh-install.sh                 # 全量：技能软链 + 安装 npm 插件（profile 自动解析）
./scripts/dsh-install.sh --profile desktop
./scripts/dsh-install.sh --plugin-link <dsh-commands 仓路径>   # 插件仓开发：改 lib/index.js 即时生效
```

脚本做两件事：

1. 调用 `scripts/skills-fanout.sh --agents dsh`，建 `$DSH_HOME/skills/<name>` → 本源的软链；
2. `dsh plugin --profile <profile> add @morehao/dsh-commands`。

`--skills-only` 只做第 1 步。插件从 npm 安装；技能内容来自本源（dsh 不从 `node_modules` 扫描 skill）。

> **profile 不硬编码**：优先级 `--profile <name>` > `$DSH_PROFILE` > `$DSH_HOME/profiles` 下唯一存在的 profile。多个或零个时报错并列出候选，不会替你新建。查看已有 profile：`ls ~/.dsh/profiles/`（桌面版是 `desktop`）。
>
> **`dsh` CLI 不要求先在 PATH**：找不到时脚本回退到 macOS 桌面版 app 包内的 `runtime/cli/bin/dsh`，并提示先退出客户端再登记插件，避免并发改写 profile；确实找不到才报错，此时第 1 步的技能软链已经完成。

### 手工等价（只挂技能）

```bash
mkdir -p ~/.dsh/skills
for name in git-kit handoff disk-cleanup project-insight project-wiki svg-maker tech-design; do
  ln -sfn ~/.agents/skills/"$name" ~/.dsh/skills/"$name"
done
```

### 技能根与热加载

- **本源 `~/.agents/skills`**：dsh 直接扫描（canonical）
- **`~/.dsh/skills`**：指向本源的软链（由 `skills-fanout.sh --agents dsh` 维护）
- 项目级 `<项目根>/.dsh/skills`、`<项目根>/.agents/skills` 也会被扫描

软链注册的技能带 `linked` 标记、只读（禁止编辑/删除），避免误改本源。技能是热加载的：新增软链后无需重启，新会话与技能面板立即能看到；只有插件 `lib/index.js` 的改动才需要重启 dsh。

### 卸载

```bash
dsh plugin --profile <profile> remove @morehao/dsh-commands
rm ~/.dsh/skills/<name>          # 只解链，本源内容用 skills CLI 卸
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
6. 改了技能内容要**发布**才生效：`git push` → `./scripts/skills-install.sh`（本机各 agent 随即读到新内容）。

## 改脚本注意

- macOS 自带 bash 3.2：不用 `mapfile` / 关联数组 / `${var,,}`；`set -u` 下不要展开空数组。
- 变量后紧跟中文等非 ASCII 字符必须写 `${var}`，否则 bash 3.2 会把该字符并入变量名并报 `unbound variable`。
- 测试安装脚本用临时目录，不要拿真实配置试：

```bash
T=$(mktemp -d)
mkdir -p "$T/hub/git-kit" && printf 'x\n' > "$T/hub/git-kit/SKILL.md"   # 造一个最小本源
AGENTS_SKILLS_DIR="$T/hub" ./scripts/skills-fanout.sh --agents opencode,dsh
AGENTS_SKILLS_DIR="$T/hub" OPENCODE_CONFIG="$T/oc" ./scripts/opencode-install.sh --check
AGENTS_SKILLS_DIR="$T/hub" DSH_HOME="$T/dsh" ./scripts/dsh-install.sh --skills-only
```

`skills-install.sh` 需要 `skills` CLI（默认 `npx -y skills`），测试时可用 `SKILLS_CLI` 指向桩：

```bash
AGENTS_SKILLS_DIR="$T/hub" SKILLS_CLI=/path/to/stub ./scripts/skills-install.sh --dry-run
```

> `--check` 是只读的，可以直接对着真实 `~/.agents/skills` 跑；其余模式务必带临时 `AGENTS_SKILLS_DIR`。
