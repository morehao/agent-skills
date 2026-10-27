# 技能说明

`skills/` 下的技能同时供 opencode 与 dsh 使用。每个技能一个目录：`SKILL.md` 是入口（frontmatter 的 `description` 决定何时触发），复杂逻辑按需拆到 `references/`，可程序化执行的校验/操作放在 `scripts/`。

`skills/` 下只放技能目录，不放说明文件——接入脚本和 dsh 都按目录扫描。

## git-kit

Git 工作流的唯一真源。`SKILL.md` 只做意图路由：先判断命中哪个分支，再按需加载 `references/<branch>.md`。

| 分支 | 用途 |
|---|---|
| `commit-message` | 只生成 commit message，不提交 |
| `commit-push` | 生成 message + 提交推送；起点是稳定分支时自动建工作分支 |
| `branch` | 按中文描述建候选分支并切换 |
| `pr-create` | 创建/更新 PR/MR（自动识别 gh/glab） |
| `pr-merge` | 合并 PR/MR、删 head（稳定分支保留）、回主干更新 |
| `tag` | 打注记 tag 并推送 |
| `release` | `pr-merge` 之后的发布段：预检 → 打 tag → 默认建 Release → 校验后效 |
| `slim` | 仓库瘦身为浅克隆 |
| `star-classify` | 拉取并分类 GitHub star |

`references/` 里另有跨分支共用的 `stable-branch.md`（稳定分支唯一定义）、`repo-id.md`（gh/glab 仓库参数）、`commit-format.md`、`ask-options.md`、`version-conventions.md`。完整流程见 [git-kit 工作流](git-kit.md)。

三个入口——opencode `/git/*`、dsh `/git-*`、自然语言——共用这套实现；命令只保留意图声明，不重复逻辑。

## handoff

单文件技能（只有 `SKILL.md`）。把当前会话压成一段可直接粘贴给新会话的续跑提示：

- 只打印一个 Markdown 代码块，不落盘、不改仓库；
- 每条结论带 `path:line` 或命令结果；取不到证据标 `[待核实]`，没跑过标 `[未验证]`，决策没落点标 `[未落盘]`；
- 模型可见、可自行触发：`description` 里写明触发语（「交接一下」「生成续跑提示」「handoff」、换工具/换目录/交给别人）；与斜杠入口 `/handoff` 等价，不要求用户手动敲命令。

入口：opencode `/handoff`、dsh `/handoff`。

## project-insight

开源项目深度解读：解构边界、模块责任、关键链路与设计决策，产物落进知识库仓库（README + 关注面子文档）。

- **先定基线**：`select-baseline.mjs` 按稳定 tag > 稳定分支 > 默认分支程序化选定，写作/校验同一棵树，基线写进产物；
- **叙述优先、引用按需**：正文写设计判断与权衡；代码引用只给反直觉结论、具体数字、安全边界、用户指定核验这几类关键论断，整篇零引用合法；
- **凡引用必验**：落盘的 `文件:行号` 经 `verify-references.mjs` 重定位（首末行锚点），`--stats` 可查密度（只报告不阻断），失败标 `[UNVERIFIED]`；
- **图与表承载过程**：启动流程/请求链路用 Mermaid 或 SVG（走 `svg-maker`），落盘前 `check-mermaid.mjs` 真解析、SVG 跑边拓扑审计；
- **类型规格补关注面**：数据模型 / 部署 / 智能体 / 框架等由类型判据触发，子文档按关注面拆分；
- 增量模式以 `git diff` / release notes 为唯一依据，维护独立 `CHANGELOG.md`；落盘后不做 `git add/commit`。

适合：想从项目里学架构设计、要设计判断与可迁移模式的开发者。

## project-wiki

面向**不读源码的读者**写项目 Wiki（Markdown + Mermaid，可选 `assets/*.svg`）：

- 表达手段按读者成本排序：散文 → 图 → 表 → 代码；
- 出处收进章末一行 `> 依据：`（用 code span，不写可点击链接）；正文不出现校验痕迹（锚点指纹、`Sources:`）；
- 代码预算：非图表代码块每页 ≤3 块、单块 ≤15 行、单页 ≤40 行，超了写 `<!-- code-budget: 理由 -->` 显式豁免；
- 真实性由作者侧门禁 `scripts/check-all.mjs` 保证（代码预算、依据行、首页索引、图表复杂度、版本契约等），Mermaid / SVG 校验复用 project-insight 引擎；
- 单基线契约：校验根与 `--expect-baseline` 必须一起交，快照只对自述的那个基线成立。

适合：给团队一份能读的文档。与 `project-insight` 的分工是**产出性质不同**：要学架构设计、要决策与可迁移模式走前者；要一份不读源码也能读的系统说明走后者。

## tech-design

技术方案 / 技术设计文档，三轴决策：

- **档位**（轻量 / 标准 / 完整）定篇幅；
- **场景**（新建 / 增量改造 / 结构重构 / 替换迁移 / 下线废弃 / 专项优化，单选）定过程义务；
- **专题**（架构 / API / 数据模型 / 性能容量 / 安全 / 迁移手法，可多选）定技术加固点。

先答「落点」第 0 问（新系统 / 既有系统的新模块 / 既有系统的既有模块），再按叙事链 9 问推理，**取证先于动笔**。四条硬要求：

- **事实有据**：既有系统的现状、影响面、调用方、容量水位带 `路径:行号`、监控口径或工单号；取不到标 `[待核实]`；
- **量化义务**：性能、容量、可用性、成本、收益给数字 + 口径 + 假设；
- **取舍对偶**：每个选型写代价与不该选的场景，并回指目标；
- **宁轻勿重**：不适用章节删掉，不留 N/A。

交付前过三道闸：作者自检 → 文档门禁 `check-design-doc.mjs`（占位符/空壳章节/状态块/备选/追溯表/DDL 一致性，三档严重度）→ 评审 gate（完整档必跑，独立上下文 + 并行 lens，只回 `VERDICT` 与 top3）。

配图 Mermaid 与 SVG 均为一等公民；`check-mermaid.mjs` / `audit-svg-topology.mjs` / `render-svg-preview.mjs` 是 project-insight 引擎的薄壳。

## svg-maker

生成自包含、纯 SVG 的架构图、流程图与概念图，单个 `.svg` 文件内联 CSS，可双击离线打开。两种输出模式：`architecture-svg`（软件/云/基础设施拓扑）与 `clean-svg`（概念、流程、生命周期、简单数据流）。模板在 `references/svg-template.md`。

## disk-cleanup

磁盘空间回收与本地数据瘦身。核心分工：**脚本是执行引擎，判断与安全门在 `SKILL.md`**。

- 一条流程不分叉：只读测量 → 分类报告 → **用户勾选最终清理项** → 只跑勾选项 → 前后对比复核；
- macOS 磁盘（`scripts/mac_cleanup.sh`，查询 / `--list` / `--top [N]` / `--clean --dry-run` / `--clean --only <ids>` / `--json`）覆盖缓存、日志、临时文件、Time Machine 快照、开发工具缓存，以及**项目层**（`projects`：node_modules/构建产物）与**应用内缓存**（`appcache`、`updaters`）；清理项编码是勾选单位，`--only/--skip` 决定这次到底删什么，`--clean` 不带 `--only` 时必须显式 `--all`；
- 报告给**两个数字**：目录总量与本次可删量（只删 mtime 阈值的项两者可能差一个数量级），受 TCC 保护的目录单独计数；
- 本地数据库（`scripts/cleanup-opencode.sh`）只是其中一个对象：**用户勾选或点名才处理**，不是每次清理的固定步骤；默认先备份 + `integrity_check` 再事务内删旧会话 + 清孤儿 snapshot + `VACUUM`，`--dry-run` 只统计不落盘；
- 用户数据（聊天记录、浏览器配置、虚拟机镜像、iOS 设备备份、邮件附件）**只报告大小与路径**，不代删，也不进勾选清单；
- agent 执行环境没有 TTY，`sudo` 两步（`/private/tmp`、Time Machine 快照）交给用户在自己的终端跑；不可逆操作前先给 `.backup` 备份命令。

细节见 `references/cleanup.md`（清理项与阈值、`/var/folders` 定向、数据库安全边界、手动清单）。

入口：opencode `/cleanup`（无参数时先给选项）；dsh 侧暂无对应斜杠命令，走自然语言。

## 怎么选

| 需求 | 技能 |
|---|---|
| 把 Git 流程走完（提交、PR、合并、发版） | `git-kit` |
| 换会话 / 换工具，先把现场交接出去 | `handoff` |
| 从开源项目里学架构设计，要判断与可迁移模式 | `project-insight` |
| 给团队写一份不读源码也能看懂的 Wiki | `project-wiki` |
| 写技术方案 / 设计文档 | `tech-design` |
| 只要一张独立图表 | `svg-maker` |
| 磁盘满了 / 要清缓存与旧会话 | `disk-cleanup` |
