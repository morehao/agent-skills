# 技能内部规则

每个技能的 `SKILL.md` 是意图路由，细节在各自的 `references/` 与 `scripts/`。这里只记 agent 改东西时容易踩的硬规则与结构，避免改错真源。技能定位与分工（给人看）见 [技能说明](../skills.md)。

## git-kit

Git 工作流（message / commit-push / branch / pr-create / pr-merge / tag / release / slim / star）。**请求分叉点：多文件结构**。`SKILL.md` 只做「意图路由」+「按需加载」指引；真实逻辑在 `references/`（各分支 .md）与 `scripts/`（.sh 脚本）。

`release` 只做 **`pr-merge` 之后**的发布段（打 tag → **默认创建 GitHub/GitLab Release** → 跟踪其他后效并逐项校验），**不改版本号、不开无关 PR**。唯一例外：用户选择写 `CHANGELOG.md` 时由 `changelog.sh --write` 写入并走一次分支 + PR（必须在打 tag 前合入，否则 tag 指向的提交没有这条记录）。

版本源由**读仓库判定**：`references/version-conventions.md` 给出 11 类主流约定的先验与现成命令——字面常量型给 `--version` + `--version-file` 边界回查并回报行号；派生/注入型只给 `--tag`；CI 硬校验版本的仓库加 `--require-version-match`。脚本里**没有任何清单格式知识**，只做「tag 样式推断 / 版本比较 / 可选回查」三件通用事，原生支持无 `package.json` 的仓库。

平台能力（`gh`/`glab`、是否已登录）与后效（workflow / GitLab pipeline / `EFFECT_HINTS` 发布步骤 + 可选 `--probe-url` 产物探测）都按仓库**探测**；事实由只读脚本 `scripts/release-preflight.sh` 给出 `STATE=READY|TAGGED|NEEDS_TARGET|BLOCKED` 与 `RELEASE_PLATFORM|RELEASE_CLI_READY|RELEASE_EXISTS|EFFECT_RELEASE`。测试：`scripts/tests/release-preflight-test.sh` / `release-verify-test.sh`（临时仓 + 桩，不需要 node）。变更说明分两层：`scripts/changelog.sh` 从 Conventional Commits 汇总**原文层**（确定性、可审计），模型在其上写**中文摘要层**（面向普通用户）；两层拼成同一份正文，`tag` 与 `release` 共用，既作 annotated tag 注记正文也作 Release body（推送前必须确认，tag 不可改；`TAGGED` 重跑从注记读回、不重算）。

发版纪律单独成篇，见 [发版纪律](release-discipline.md)。

## handoff

**刻意只有单文件 `SKILL.md`（29 行）**：规则 4 条 + 取证命令 + 输出骨架 5 节，没有 `references/`。把当前会话压成一段可直接粘贴的续跑提示：**只打印、不落盘**；新会话粘贴后先核对分支/工作区/关键文件再继续。入口 opencode `/handoff` 与 dsh `/handoff`（`print` 分支）。**frontmatter 不设 `disable-model-invocation`**：模型在技能清单里可见，既能被用户斜杠调用，也能在用户说「交接一下」或判定需要跨会话接力时自行加载——触发条件写进 `description`，别只依赖手动入口。dsh 侧命令注入仍指向 `$DSH_HOME/skills/handoff/SKILL.md` 的 read 兜底（插件仓既有实现），不以此作为可见性前提。

## project-insight

开源项目深度解读。`SKILL.md` 较大（约 50KB），铁律：

- 真源引用 `文件:行号` 必须经 `scripts/verify-references.mjs` 程序化重定位验证（指纹用**首末行双锚点**，不整段贴码；旧 snippet 格式仅存量兼容）。
- Mermaid 图必须经 `scripts/check-mermaid.mjs` 校验全 `OK`。
- `[UNVERIFIED]` / `[MERMAID-ERROR]` 一律保留，不静默放过。
- **版本基线**（step 0.5）由 `scripts/select-baseline.mjs` 程序化选定：稳定 tag > 稳定分支（`release*`/`stable*`/`maintenance*`/`1.x`）> 默认分支（main/master/远端 HEAD）> **无 main/master 的兜底矩阵**。选定后的工作树才是 `source_repo` 与引用校验根；脏工作树不静默覆盖（`git worktree` 兜底）；基线写进 README 概览一行 + `CHANGELOG.md` 顶部（不进 frontmatter）。细则在 `references/version-baseline.md`。
- 参考性内容按需加载：`version-baseline.md`（基线选择）、`data-model-guide.md`（五要素成文细则）、`errors-and-fixes.md`（查错表）、`analysis-guide.md`（深度方法论）、`large-repo-workflow.md`（并行流程）、`project-types/`（类型规格）。
- 落盘后**不做 git add/commit**。

## project-wiki

面向**不读源码的广泛读者**产出项目 Wiki（Markdown：内嵌 Mermaid + 可选 `assets/*.svg`，不依赖渲染服务与外链解析）。与 `project-insight` 的分工是**受众不同**：那边每条论断后跟 `文件:行号` + 锚点指纹，供能读源码的人逐条核验；这边表达手段按**读者成本**排序（散文 → 图 → 表 → 代码），出处**收进章末一行** `> 依据：`（**不写可点击链接**，用 code span），正文**禁止出现任何校验痕迹**（锚点指纹、`Sources:`）。

`SKILL.md` = 意图路由 + **七条铁律**，其中两条最容易违规：

- **代码预算**：非图表代码块每页 ≤3 块、单块 ≤15 行、单页 ≤40 行；超了要么删，要么在页内写一行 `<!-- code-budget: <理由> -->` 显式豁免。
- **快照唯一**（第 7 条）：全部校验只对自述的那一个基线成立，校验根与 `--expect-baseline` 必须一起交。

流程：**0 定基线 → 0.5 版本契约 → 1 落点判定 → 2 模式判定（已有 wiki → 更新模式）→ 3–7**。

references：`version-contract.md`（单基线契约与陈旧三选一裁决）、`landing.md`（落点两模式：独立 `<cwd>/<项目名>-wiki/` 与 KB `{kb_repo}/{分类}/{项目名}-wiki/`，与 project-insight 的 `{分类}/{项目}/` **平级兄弟目录**、零文件名冲突）、`update-flow.md`（版本事件驱动的更新流程）、`page-plan.md`（页面规划与产出形态）、`page-templates.md`（各类页面骨架与必答问题）、`writing-style.md`（读者画像与代码准入三问）、`diagrams.md`（**图选型**：默认 Mermaid，仅结构/分层、左右对比、回边状态机、节点 ≥12 四类升级 SVG；含 Mermaid 硬约束）、`grounding-light.md`（轻量真源 + **严重度与归级判据** + 正文合法声明清单）。

**真实性移到作者侧**：`scripts/check-docs.mjs` 是自研门禁，**三档严重度 `error`/`warn`/`note`，语义已冻结**——`--strict` 只提升 warn，**note 在任何模式下都不影响退出码**但必须默认打印；新增检查一律 note，唯一够格升 error 的是落点 `[DOC-DOCROOT-IN-SRC]`（理由写在 grounding-light）。覆盖代码预算、依据行路径存在与行号未越界、首页索引一致性、图表复杂度与参与者声明、版本契约与校验根一致性、落点与 KB 索引可达性。`[DOC-SRC-UNPARSED]`/`[DOC-SRC-UNCHECKED]` 是两条**反静默**机制——认不出的引用写法、以及「有引用却没传 `--source-repo`」都要报出来，不当作没有引用跳过。引用/代码块/frontmatter 的解析实现是 `scripts/lib/doc-parse.mjs`（单一真源，与预检脚本共用）。

`scripts/check-all.mjs` 是**唯一门禁入口**（编排自研门禁 + 复用 project-insight 引擎的 Mermaid 真解析 / SVG 边拓扑审计，因此**无需另行 npm install**），汇总里带 note 计数并提醒「结论是否真的在自述基线上校验过」。`scripts/plan-update.mjs` 是**更新预检，不是门禁**：`--from <旧ref> --to <新ref>` 出两张清单（受影响页 `[DOC-UPDATE-TOUCHED]`、未覆盖变更面 `[DOC-UPDATE-UNCOVERED]`，并给行号漂移的真实新行号）；`--emit/--against` 做结构指纹前后比对（`[DOC-UPDATE-SHRUNK]`/`[DOC-UPDATE-PAGE-DROPPED]`）；退出码只表达「清单有没有产出来」。`scripts/select-baseline.mjs` 是 project-insight 同名脚本的薄壳。回归测试 `scripts/tests/gates-regression.sh`（**45 条断言**，含「故意违规必须被拦住」以及「note 不阻断、`--strict` 下也不阻断」的夹具）。落盘后**不做 git add/commit**。

## tech-design

技术方案 / 技术设计文档生成（原 `tech-design-proposal`，曾用名 `design-doc`）。多文件：`SKILL.md` 只做意图路由（**档位 × 场景 × 专题**三轴：档位定篇幅、场景（单选）定过程义务、专题（可多选）定技术领域加固点；**场景判定前先答「落点」第 0 问**——新系统 / 既有系统的新模块 / 既有系统的既有模块，决定取证对象与义务增量：宿主约束、对宿主的影响、必须谁签）+ 工作流（澄清 → 定档 → 定落点与场景 → 选专题 → **取证 → 按叙事链推理** → 量化 → 撰写 → 自检落盘）+ 交付前自检 + 落盘收尾（含文档状态块：状态/作者/评审人/拍板人；收尾原为 `output.md`，已合并进 SKILL.md，避免两份说法漂移）。

references：`templates.md`（**叙事链 9 问与顺序依赖** + 三档骨架与各节必答项）、`scenarios.md`（**落点义务增量 A/B/C** + 六类场景义务包：新建/增量改造/结构重构/替换与迁移/下线与废弃/专项优化——必答项 + 章节增删 + 验收与回滚形态）、`focus-areas.md`（专题加固点与迁移手法手段库）、`data-model.md`（**数据库设计落法**：正文三张表——实体清单/字段/索引与查询匹配 + 简版 ER 图 + **DDL 只在附录**且为唯一可执行真源）、`quantification.md`（量化与量级估算：收益口径、可用性预算、最脆弱假设）、`quality-bar.md`（图/代码/论证红线 + 反模式表 + 评审清单）。

职责边界：**过程义务归场景**（落点义务 + 迁移/兼容/回滚/等价性验证），**技术必答项归专题**，两者不重复表述。

四条硬要求：

- **事实有据**：既有系统的现状/影响面/调用方/容量水位必须带 `路径:行号`、监控口径或工单号，取不到标 `[待核实]`。
- **量化义务**：性能/容量/可用性/成本/收益的论断必须给数字 + 口径 + 假设。
- **取舍对偶**：每个选型写代价、不该选的场景，并回指目标或约束。
- **宁轻勿重**：不适用的章节删掉，不留 N/A。

配图 **Mermaid 与 SVG 均为一等公民**，按图的职责选（结构/映射/对比/回边状态机 → SVG，走 `svg-maker` 产出；时序/线性小图 → Mermaid；节点 ≥12 或含分层/泳道/边界即改用 SVG），同一张图不做双份。`scripts/check-mermaid.mjs` / `audit-svg-topology.mjs` / `render-svg-preview.mjs` 均为 project-insight 引擎的薄壳（单一真源）；SVG 结构图新画或重排后必须跑边拓扑审计（唯一能程序化发现「看着对、边连错」的手段），成稿含图必须校验，`[MERMAID-ERROR]` 与审计非 0 不静默放过。

## svg-maker

独立 SVG 图表生成（`SKILL.md` + `references/svg-template.md`）。

## disk-cleanup

磁盘空间回收。**一条流程不分叉**：只读测量（`scripts/mac_cleanup.sh` 默认模式，仅 macOS）→ 分类报告（可勾选 / 需应用内 / 需 sudo）→ **用户勾选最终清理项** → 只跑勾选项 → 前后对比复核。两个脚本都是执行引擎：`mac_cleanup.sh` 有查询 / `--list` / `--top [N]` / `--clean --dry-run` / `--clean --only <ids>` / `--json` 几类用法（无 `--only/--skip` 的 `--clean` 必须显式 `--all`，否则 exit 2），清理项编码（`caches`、`logs`、`tmp`、`varfolders`、`snapshots`、`trash`、`xcode`、`toolcache`、`bigbuild`、`docker`、`appcache`、`updaters`、`projects`）是用户勾选的落地单位，`--only/--skip` 决定这次到底删什么；报告一律双口径（目录总量 vs 本次可删量），已知纯缓存目录整删、其余按 mtime 阈值，TCC 拒绝的条目单独计数；`cleanup-opencode.sh` 是**本地数据库这一个对象**的处理方式（用户勾选或点名才跑，默认 `.backup` + `integrity_check` 后才动数据，事务内删旧会话 + 清孤儿 snapshot + `VACUUM`，另有只读 `--dry-run`），不是固定步骤。编码表以 `mac_cleanup.sh --list --json` 为单一事实源，`scripts/check-disk-cleanup-codes.mjs` 在 CI 校验它与 `SKILL.md`、`references/cleanup.md`、本文件不漂移。**`SKILL.md` 只做流程与铁律**（先查询后删除、最终清理项由用户勾选、用户数据只报告不代删、sudo 交给用户终端、不可逆前先备份、不虚构数字），**不复述成散文步骤**让模型现拼命令。细节在 `references/cleanup.md`。原 `scripts-kit` 仓的 `tools/cleanup/` 已迁入此处，该仓只留指向。
