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
- frontmatter 标 `disable-model-invocation: true`：只允许用户手动调用，模型不会自动触发。

入口：opencode `/handoff`、dsh `/handoff`。

## project-insight

开源项目深度解读，产出一份「每条论断都能核验」的 Markdown：

- 真源引用必须 `文件:行号`，并由 `scripts/verify-references.mjs` 程序化重定位（首末行双锚点，不整段贴码）；
- Mermaid 图由 `scripts/check-mermaid.mjs` 真解析；
- 版本基线由 `scripts/select-baseline.mjs` 选定（稳定 tag > 稳定分支 > 默认分支 > 无 main/master 的兜底矩阵），基线写进 README 概览与 `CHANGELOG.md` 顶部；
- `[UNVERIFIED]` / `[MERMAID-ERROR]` 保留，不静默放过；
- 落盘后不做 `git add/commit`。

适合：要逐条点开核验、要深挖设计权衡的读者。

## project-wiki

面向**不读源码的读者**写项目 Wiki（Markdown + Mermaid，可选 `assets/*.svg`）：

- 表达手段按读者成本排序：散文 → 图 → 表 → 代码；
- 出处收进章末一行 `> 依据：`（用 code span，不写可点击链接）；正文不出现校验痕迹（锚点指纹、`Sources:`）；
- 代码预算：非图表代码块每页 ≤3 块、单块 ≤15 行、单页 ≤40 行，超了写 `<!-- code-budget: 理由 -->` 显式豁免；
- 真实性由作者侧门禁 `scripts/check-all.mjs` 保证（代码预算、依据行、首页索引、图表复杂度、版本契约等），Mermaid / SVG 校验复用 project-insight 引擎；
- 单基线契约：校验根与 `--expect-baseline` 必须一起交，快照只对自述的那个基线成立。

适合：给团队一份能读的文档。与 `project-insight` 的分工是**受众不同**：要逐条核验走前者，要给不读源码的人读走后者。

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

配图 Mermaid 与 SVG 均为一等公民；`check-mermaid.mjs` / `audit-svg-topology.mjs` / `render-svg-preview.mjs` 是 project-insight 引擎的薄壳。

## svg-maker

生成自包含、纯 SVG 的架构图、流程图与概念图，单个 `.svg` 文件内联 CSS，可双击离线打开。两种输出模式：`architecture-svg`（软件/云/基础设施拓扑）与 `clean-svg`（概念、流程、生命周期、简单数据流）。模板在 `references/svg-template.md`。

## disk-cleanup

磁盘空间回收与本地数据瘦身。核心分工：**脚本是执行引擎，判断与安全门在 `SKILL.md`**。

- 一条流程不分叉：只读测量 → 分类报告 → 用户同意后执行 → 前后对比复核；
- macOS 磁盘（`scripts/mac_cleanup.sh`，查询 / `--clean --dry-run` / `--clean` 三模式）覆盖缓存、日志、临时文件、Time Machine 快照与开发工具缓存；
- 本地数据库（`scripts/cleanup-opencode.sh`）只是其中一个对象：**仅在用户点名或该库明显偏大时处理**，不是每次清理的固定步骤；事务内删旧会话 + 清孤儿 snapshot + `VACUUM`；
- 用户数据（聊天记录、浏览器配置、虚拟机镜像、iOS 设备备份、邮件附件）**只报告大小与路径**，不代删；
- agent 执行环境没有 TTY，`sudo` 三步（`/tmp`、`/var/folders`、Time Machine）交给用户在自己的终端跑；不可逆操作前先给 `.backup` 备份命令。

细节见 `references/cleanup.md`（清理项与阈值、`/var/folders` 定向、数据库安全边界、手动清单）。

入口：opencode `/cleanup`（无参数时先给选项）；dsh 侧暂无对应斜杠命令，走自然语言。

## 怎么选

| 需求 | 技能 |
|---|---|
| 把 Git 流程走完（提交、PR、合并、发版） | `git-kit` |
| 换会话 / 换工具，先把现场交接出去 | `handoff` |
| 读懂一个开源项目，留下可核验的笔记 | `project-insight` |
| 给团队写一份不读源码也能看懂的 Wiki | `project-wiki` |
| 写技术方案 / 设计文档 | `tech-design` |
| 只要一张独立图表 | `svg-maker` |
| 磁盘满了 / 要清缓存与旧会话 | `disk-cleanup` |
