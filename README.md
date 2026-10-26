# agent-skills

个人 AI 编码工具扩展：`commands-opencode/`（opencode 斜杠指令）+ `skills/`（技能，opencode / dsh 共用）。命令只是委托壳，逻辑唯一真源在 `skills/`；dsh 的斜杠入口在独立仓 [morehao/dsh-commands](https://github.com/morehao/dsh-commands)，本仓只提供它依赖的技能。

同一套实现有三个入口：opencode `/git/*`、dsh `/git-*`、自然语言。

## 快速开始

**技能本源是 `~/.agents/skills`**：本仓是编辑源，用 `skills` CLI 发布到本源，再由软链分发给各 agent。

```bash
git clone git@github.com:morehao/agent-skills.git && cd agent-skills

# ① 发布技能到本源（改完本仓、push 之后都要跑）
./scripts/skills-install.sh
./scripts/skills-install.sh --check        # 只读：本源与本仓是否一致

# ② 分发软链：本源 -> opencode / dsh 的技能目录
./scripts/skills-fanout.sh
./scripts/skills-fanout.sh --check

# ③ opencode：命令软链（技能已由 fanout 就位）
./scripts/opencode-install.sh --commands-only
./scripts/opencode-install.sh --check

# dsh（可选）：技能软链 + npm 插件
./scripts/dsh-install.sh --skills-only

# 改完命令/README 后校验契约
node scripts/check-opencode-commands.mjs
```

发布链路、`--source` 覆盖、手工等价命令、profile 解析与卸载，见 [安装与维护](docs/installation.md)。

## 目录

- `commands-opencode/` — opencode 斜杠指令（`git/*.md` + `handoff.md` + `cleanup.md`）
- `skills/` — 技能：git-kit、handoff、project-insight、project-wiki、tech-design、svg-maker、disk-cleanup
- `docs/` — 安装、技能、git-kit 工作流
- `scripts/` — 发布（`skills-install.sh`）+ 分发（`skills-fanout.sh`）+ opencode / dsh 接入 + 命令契约校验

## 命令

| 命令 | 作用 |
|---|---|
| `/git/message <描述>` | 生成 Conventional Commits message（只生成，不提交） |
| `/git/commit-push` | 生成 message 后提交并推送；起点是稳定分支时先建分支 |
| `/git/branch <描述>` | 按中文描述建候选分支并切换 |
| `/git/pr-create [目标分支]` | 创建/更新 PR/MR（自动识别 gh/glab） |
| `/git/pr-merge [编号]` | 合并 PR/MR、清理分支、回主干更新 |
| `/git/release [版本]` | 合并后的发布段：打 tag → 默认建 GitHub/GitLab Release → 校验后效；变更说明 = 中文摘要 + 折叠原文 |
| `/git/tag [tag/分支]` | 给分支打注记 tag（中文摘要 + 折叠原文）并推送 |
| `/git/slim [天数]` | 仓库瘦身为浅克隆（默认保留 30 天） |
| `/git/star-classify` | 拉取并分类自己的 GitHub star |
| `/handoff [范围]` | 把当前会话压成可粘贴的续跑提示（只打印） |
| `/cleanup [范围]` | 磁盘空间回收与本地数据瘦身：先查询、用户勾选后再清理，无参数时给选项 |

参数、用法与「命令 → skill 分支」映射见 [opencode 指令集](commands-opencode/README.md)。

## 技能

| 技能 | 一句话 |
|---|---|
| [`git-kit`](skills/git-kit/SKILL.md) | Git 工作流：message / commit-push / branch / PR / tag / release / slim / star |
| [`handoff`](skills/handoff/SKILL.md) | 跨会话交接：只打印一段可粘贴的续跑提示 |
| [`project-insight`](skills/project-insight/SKILL.md) | 开源项目架构分析：决策卡 + 可迁移模式 + 学习路径，证据按需 |
| [`project-wiki`](skills/project-wiki/SKILL.md) | 面向不读源码的读者写 Wiki：散文 + 图 + 表，代码密度极低 |
| [`tech-design`](skills/tech-design/SKILL.md) | 技术方案：档位 × 场景 × 专题三轴，取证先于动笔；含既有文档评审模式 |
| [`svg-maker`](skills/svg-maker/SKILL.md) | 生成自包含、可离线打开的 SVG 图 |
| [`disk-cleanup`](skills/disk-cleanup/SKILL.md) | 磁盘空间回收与本地数据瘦身：先查询、用户勾选后只删所选，用户数据只报告 |

定位、关键规则与相互分工见 [技能说明](docs/skills.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [安装与维护](docs/installation.md) | opencode / dsh 接入、目录约定、契约校验、新增命令 |
| [技能说明](docs/skills.md) | 七个技能的定位、关键规则与分工 |
| [git-kit 工作流](docs/git-kit.md) | 入口与路由、提交 → PR → 合并、发版 |
| [opencode 指令集](commands-opencode/README.md) | 指令格式、参数、映射与校验 |
| [AGENTS.md](AGENTS.md) | 给编码 agent 的硬约束与按需加载地图（细则在 [`docs/agents/`](docs/agents/)） |

> `skills/*/SKILL.md` 是给模型看的操作指令，`docs/` 是给人看的解释。

## 许可

MIT
