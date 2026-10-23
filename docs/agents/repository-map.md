# 仓库地图

给编码 agent 的组件地图：每个目录做什么、边界在哪。技能内部的硬规则见 [技能内部规则](skill-internals.md)；给人看的技能定位见 [技能说明](../skills.md)。

## 顶层

| 路径 | 作用 |
|---|---|
| `AGENTS.md` | agent 入口：硬约束 + 文档导航 |
| `commands-opencode/` | opencode 斜杠指令，**委托壳** |
| `skills/` | 技能真源，opencode / dsh 共用 |
| `scripts/` | 接入脚本 + 命令契约校验 |
| `docs/` | 给人看的解释性文档；`docs/agents/` 给 agent 按需加载 |
| `README.md` | 仓库入口（人读） |
| `CHANGELOG.md` | 本仓变更记录（跟随里程碑 tag；npm 发布记录在 dsh-commands 仓） |
| `.github/workflows/` | CI：命令契约校验（含跨仓比对）+ 安装脚本语法 |

## commands-opencode/

- `git/*.md` — git 斜杠指令。每条只加载 `git-kit` skill 并按某个分支意图执行，不含逻辑；改命令类需求应落到 `skills/git-kit/references/<branch>.md`。
- `handoff.md` — `/handoff`，只委托 `handoff` skill 的 `print` 分支。
- `cleanup.md` — `/cleanup`，委托 `disk-cleanup` skill 的 `cleanup` 分支；**不带参数时先给选项、不执行任何脚本**。
- `README.md` — 指令清单与「命令 → 技能分支」联动表；由 `scripts/check-opencode-commands.mjs` 校验。

## scripts/

- `skills-link.sh` — **技能安装位的唯一入口**：把 `skills/*` 软链到 `~/.agents/skills`（`AGENTS_SKILLS_DIR` 或 `--target` 覆盖），幂等。选项：`--check`（只读，缺失/指向错误/悬空/被真实目录占位 → 退出 1）/ `--dry-run` / `--force`（同名真实目录先改名备份再软链）/ `-h`。只遍历目录，避免松散文件被通配链走。
- `opencode-install.sh` — opencode 接入：技能委托 `skills-link.sh`，命令软链到 `<config>/command/`。选项：`--skills-only` / `--commands-only` / `--check` / `--dry-run` / `-h`；`OPENCODE_CONFIG` 覆盖配置根、`AGENTS_SKILLS_DIR` 覆盖技能安装位。会提示旧布局（`<config>/skills` 残留软链）与「opencode 未配置技能根」。
- `dsh-install.sh` — dsh 接入：技能委托 `skills-link.sh`（dsh 默认扫 `~/.agents/skills`），再装 npm 上的 `@morehao/dsh-commands`。选项：`--profile <name>` / `--skills-only`（只软链技能、跳过插件）/ `--plugin-link <插件仓路径>`（插件仓开发调试走 `link:`）/ `-h`；检测到 `$DSH_HOME/skills` 旧布局会给 `rm` 提示。
- `check-opencode-commands.mjs` — 命令契约校验：frontmatter 合法字段、`**<branch> 分支**` 对应 `skills/<skill>/references/<branch>.md`、`$ARGUMENTS` 独立成行、两份 README 表格与命令文件一一对应。可选 `--dsh <插件仓路径>` 比对另一仓 `COMMANDS` 表的 branch/skill（不一致判失败，description 差异只提示）。

## 三个入口，一份实现

`commands-opencode/git/*`、dsh 插件（另一仓 [morehao/dsh-commands](https://github.com/morehao/dsh-commands)）与 `skills/git-kit` **共享同一实现**：opencode 斜杠 / dsh 斜杠 / 自然语言互为入口。改命令类需求只改 skill 分支，命令保留意图声明；「命令 → 技能分支」契约在 opencode 侧由本仓 `scripts/check-opencode-commands.mjs`、dsh 侧由插件仓 `scripts/check-skill-contract.mjs` 机械校验。

## docs/

**给人看的**解释性文档；`skills/*/SKILL.md` 是给模型看的操作指令，两者分工不重叠。

- `installation.md` — opencode / dsh 接入、命令契约校验、新增命令。
- `skills.md` — 技能定位与分工。
- `git-kit.md` — 入口与路由、九个分支、稳定分支唯一定义、提交 → PR → 合并、发版段。刻意保持单篇：它是一条链路读下来的流程文档。
- `agents/` — 本目录，agent 的按需加载细则。
- 图放 `docs/assets/`：分层结构用 SVG，流程/时序/状态用 Mermaid；新画或重排的 SVG 必须跑 `skills/tech-design/scripts/audit-svg-topology.mjs`，Mermaid 必须跑 `skills/tech-design/scripts/check-mermaid.mjs` 且零 warn。

## 其它

- `.gitignore` 忽略 `.opencode/`、`.superpowers/`、`.dsh/`、`docs/superpowers/`、`node_modules/`，细节见 [写作与仓库约定](conventions.md)。
- 发布工具链（npm / pnpm / OIDC / release workflow）已迁出到 dsh-commands 仓，本仓不再是 npm 包，见 [接入与生效语义](deployment.md)。
