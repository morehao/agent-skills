# AGENTS.md

本仓库集中管理个人 AI 编码工具扩展：`commands-opencode/`（opencode 斜杠指令）+ `commands-dsh/`（dsh 斜杠命令插件）+ `skills/`（技能，opencode/dsh 共用）。所有说明用**简体中文**。

## 部署方式（任何修改前必读）

- **opencode 侧**：通过**软链接**注册到 `~/.config/opencode/`，本仓是唯一真源：
  - `ln -sfn <ai-kit>/skills/* ~/.config/opencode/skills/`
  - `ln -sfn <ai-kit>/commands-opencode/git ~/.config/opencode/command/git`
- **dsh 侧**：`commands-dsh/` **不是 opencode 软链扩展**，用 `./scripts/dsh-install.sh`（软链 skills 到 `$DSH_HOME/skills` + 插件注册）接入。插件注册可选两种：`link:<本仓库>/commands-dsh`（**开发**，改源码即生效）或 `dsh plugin --profile <profile> add @morehao/dsh-commands`（**安装已发布 npm 包**）。无论哪种，`skills/*` 仍由本仓库软链提供（dsh 不从 node_modules 扫描 skill）。
  - **profile 由脚本解析，不要写死**：优先级 `--profile <name>` > `$DSH_PROFILE` > 「`$DSH_HOME/profiles` 下**唯一**存在的 profile」。查看实际有哪些 profile 用 `ls ~/.dsh/profiles/`（**桌面版是 `desktop`**）。多个/零个 profile 时脚本报错列出候选，**不会**替你新建（早期版本写死 `web`，正是会凭空造 profile 的坑）。`dsh` CLI 也不要求先在 PATH：脚本会回退到桌面版 app 包内的 `runtime/cli/bin/dsh`（`*/runtime/cli/bin/dsh` 分支会额外提示先退出客户端再登记，避免并发改写 profile 配置）。
  - **只软链 skills**：`./scripts/dsh-install.sh --skills-only`（零副作用、不需要 `dsh` CLI；也等价于手敲 `mkdir -p "$DSH_HOME/skills"` + 对 `skills/` 下每个技能目录 `ln -sfn <ai-kit>/skills/<name> "$DSH_HOME/skills/<name>"`）。dsh 技能根是**用户级** `~/.dsh/skills`（全局生效），另扫项目级 `<项目根>/.dsh/skills` 与 `~/.agents/skills`。软链注册的技能在 dsh 中带 `linked` 标记且**只读**（禁止编辑/删除）——正合「本仓是唯一真源」。
  - **技能热加载**：新增/变更软链后无需重启，新会话与技能面板立即生效；只有改插件 `lib/index.js` 才需重启 dsh。
  - **改脚本时注意 bash 3.2 兼容**（macOS 自带）：不用 `mapfile`/关联数组/`${var,,}`，也不要在 `set -u` 下展开空数组。**变量后紧跟中文等非 ASCII 字符必须写 `${var}`**，否则 bash 3.2 会把该字符并入变量名报 `unbound variable`。

**`skills/` 下只允许放技能的目录**（如 `git-kit/`），禁止放置任何松散说明文件。因为 `ln -sfn skills/*` 会展开全部条目，新增的非目录文件会被一并软链过去。根 `README.md` 即安装说明。

`.gitignore` 忽略了 `.opencode/`、`.superpowers/`、`.dsh/`、`docs/superpowers/`（本地草稿/会话运行态，不入库）。另忽略 `node_modules/`。**注意 `.dsh/` 整体被忽略**：按全局约定落在 `.dsh/docs/` 的过程性文档（specs/plans/notes）因此只留本地，不随仓库分发——需要入库的方案/设计文档请直接放仓库的 `docs/` 或对应技能目录。

**发布工具链**：仓库根是一个**最小的 pnpm workspace**（`package.json` 仅 `private: true` + `workspaces: ["commands-dsh"]`，`pnpm-workspace.yaml` 只列 `commands-dsh`），仅为 `.github/workflows/release.yml`（**tag 触发**）服务。发布方式是**打 `vX.Y.Z` tag → OIDC（Trusted Publishing）自动发布 `@morehao/dsh-commands`**（`npm publish --provenance`，无长效 token）；tag 版本须与 `commands-dsh/package.json` 的 `version` 一致（不一致拒绝发布）。**升版本不得直接提交稳定分支**（`main` 也不接受直推，发版不构成例外）：改 version → `commit-push` 建分支 → `pr-create` → `pr-merge` 合并 `main` → 再打 tag（规则见 `skills/git-kit/references/stable-branch.md` 与 `tag.md`「发版约束」）。**不再使用 changesets**。根目录的 `package.json` / `pnpm-workspace.yaml` / `pnpm-lock.yaml` **不是 skills 或命令运行的前提**；它们是「把 commands-dsh 发布到 npm」的专用机制。**唯一发布子包是 `commands-dsh/`**；skills 与 opencode 侧不入包。**完整流程、一次性 npm 侧设置与踩坑清单见 [`PUBLISHING.md`](PUBLISHING.md)。**

## 目录结构速览

- `commands-opencode/git/*.md` — opencode 斜杠指令。是**委托壳**，只加载 `git-kit` skill 并按某种意图执行，不含逻辑。
- `commands-dsh/` — dsh 插件（`lib/index.js`）。**不是 opencode 软链扩展**，经 `scripts/dsh-install.sh` 注册进 dsh profile；同样只声明「命令 → git-kit 分支」意图表，不含逻辑。改动同受下面 git-kit「单一真源」约束。**也是一个可扩展的 npm 子包**（`@morehao/dsh-commands`，cordis 插件名 `dsh-commands`）：`package.json` 的 `name` 必须与 `cordis.patch.yml` 的 `insert[0].name`（dsh 用于 `import()` 的模块标识符）一致；`lib/index.js` 的 `export const name`（cordis 插件名）与 `insert[0].id` 对齐、与模块标识符解耦。改包名时三者同步核对。仓库目录名 `commands-dsh/` 与 npm 包名刻意不同（前者与 `commands-opencode/` 平行，后者是发布名），由 `repository.directory` 关联。
- `scripts/dsh-install.sh` — dsh 一键接入（软链 skills + 注册 commands-dsh 插件），幂等。选项：`--profile <name>` / `--skills-only`（只软链技能、跳过插件）/ `--npm`（插件走 npm 已发布包）/ `-h`；`--skills-only` 是零副作用的安全子集。
- `skills/git-kit/` — Git 工作流（message/commit-push/branch/pr-create/pr-merge/slim/star）。**请求分叉点：多文件结构**。`SKILL.md` 只做「意图路由」+「按需加载」指引；真实逻辑在 `references/`（各分支 .md）与 `scripts/`（.sh 脚本）。
  - `commands-opencode/git/*`、`commands-dsh/` 与 `skills/git-kit` **共享同一实现**（互为入口：opencode 斜杠 / dsh 斜杠 / 自然语言）。改命令类的需求应落到 skill 分支，命令只保留意图声明。
- `skills/project-insight/` — 开源项目深度解读。`SKILL.md` 较大（约 50KB），含铁律：真源引用 `文件:行号` 必须经 `scripts/verify-references.mjs` 程序化重定位验证（指纹用**首末行双锚点**，不整段贴码；旧 snippet 格式仅存量兼容），Mermaid 图必须经 `scripts/check-mermaid.mjs` 校验全 `OK`。`[UNVERIFIED]`/`[MERMAID-ERROR]` 一律保留不静默放过。**版本基线**（step 0.5）由 `scripts/select-baseline.mjs` 程序化选定：稳定 tag > 稳定分支（`release*`/`stable*`/`maintenance*`/`1.x`）> 默认分支（main/master/远端 HEAD）> **无 main/master 的兜底矩阵**；选定后的工作树才是 `source_repo` 与引用校验根，脏工作树不静默覆盖（`git worktree` 兜底），基线写进 README 概览一行 + `CHANGELOG.md` 顶部（不进 frontmatter），细则在 `references/version-baseline.md`。参考性内容按需加载在 `references/`（`version-baseline.md` 基线选择、`data-model-guide.md` 五要素成文细则、`errors-and-fixes.md` 查错表、`analysis-guide.md` 深度方法论、`large-repo-workflow.md` 并行流程、`project-types/` 类型规格）。落盘后**不做 git add/commit**。
- `skills/project-wiki/` — 面向**不读源码的广泛读者**产出项目 Wiki 文档（Markdown 文件：内嵌 Mermaid + 可选 `assets/*.svg`，不依赖渲染服务与外链解析）。与 `project-insight` 的分工是**受众不同**：那边每条论断后跟 `文件:行号` + 锚点指纹，供能读源码的人逐条核验；这边表达手段按**读者成本**排序（散文 → 图 → 表 → 代码），出处**收进章末一行** `> 依据：`（**不写可点击链接**，用 code span），正文**禁止出现任何校验痕迹**（锚点指纹、`Sources:`）。`SKILL.md` 是意图路由 + 六条铁律（含**代码预算**：非图表代码块每页 ≤3 块、单块 ≤15 行、单页 ≤40 行；超了要么删、要么在页内写一行 `<!-- code-budget: <理由> -->` 显式豁免）；参考性内容按需加载在 `references/`（`page-plan.md` 页面规划与产出形态、`page-templates.md` 各类页面骨架与必答问题、`writing-style.md` 读者画像与代码准入三问、`diagrams.md` **图选型**——默认 Mermaid，仅结构/分层、左右对比、回边状态机、节点 ≥12 四类升级 SVG——与 Mermaid 硬约束、`grounding-light.md` 轻量真源与取舍说明）。**真实性移到作者侧**：`scripts/check-docs.mjs` 是自研门禁（19 个输出码，覆盖代码预算、依据行路径存在与行号未越界、首页索引一致性、图表复杂度与参与者声明等），其中 `[DOC-SRC-UNPARSED]`/`[DOC-SRC-UNCHECKED]` 是两条**反静默**机制——认不出的引用写法、以及"有引用却没传 `--source-repo`"，都要报出来而不是当作没有引用跳过；`scripts/check-all.mjs` 是**唯一门禁入口**（编排自研门禁 + 复用 project-insight 引擎的 Mermaid 真解析 / SVG 边拓扑审计，因此**无需另行 npm install**）；`scripts/select-baseline.mjs` 是 project-insight 同名脚本的薄壳；回归测试 `scripts/tests/gates-regression.sh`（23 条断言，含「故意违规必须被拦住」的夹具）。落盘后**不做 git add/commit**。
- `skills/tech-design/`（原 `tech-design-proposal`，曾用名 `design-doc`）— 技术方案/技术设计文档生成。多文件：`SKILL.md` 只做意图路由（**档位 × 场景 × 专题**三轴：档位定篇幅、场景（单选）定过程义务、专题（可多选）定技术领域加固点；**场景判定前先答「落点」第 0 问**——新系统 / 既有系统的新模块 / 既有系统的既有模块，决定取证对象与义务增量：宿主约束、对宿主的影响、必须谁签）+ 工作流（澄清 → 定档 → 定落点与场景 → 选专题 → **取证 → 按叙事链推理** → 量化 → 撰写 → 自检落盘）+ 交付前自检 + 落盘收尾（含文档状态块：状态/作者/评审人/拍板人；收尾原为 `output.md`，已合并进 SKILL.md，避免两份说法漂移）；参考性内容按需加载在 `references/`（`templates.md` **叙事链 9 问与顺序依赖** + 三档骨架与各节必答项、`scenarios.md` **落点义务增量（A/B/C）** + 六类场景义务包（新建/增量改造/结构重构/替换与迁移/下线与废弃/专项优化：必答项 + 章节增删 + 验收与回滚形态）、`focus-areas.md` 专题加固点与迁移手法手段库、`quantification.md` 量化与量级估算（含收益口径、可用性预算、最脆弱假设）、`quality-bar.md` 图/代码/论证红线 + 反模式表 + 评审清单）。职责边界：**过程义务归场景**（落点义务 + 迁移/兼容/回滚/等价性验证），**技术必答项归专题**，两者不重复表述。四条硬要求：**事实有据**（既有系统的现状/影响面/调用方/容量水位必须带 `路径:行号`、监控口径或工单号，取不到标 `[待核实]`）、**量化义务**（性能/容量/可用性/成本/收益的论断必须给数字+口径+假设）、**取舍对偶**（每个选型写代价、不该选的场景，并回指目标或约束）、**宁轻勿重**（不适用的章节删掉，不留 N/A）。配图 **Mermaid 与 SVG 均为一等公民**，按图的职责选（结构/映射/对比/回边状态机 → SVG，走 `svg-maker` 产出；时序/线性小图 → Mermaid；节点 ≥12 或含分层/泳道/边界即改用 SVG），同一张图不做双份。`scripts/check-mermaid.mjs`、`scripts/audit-svg-topology.mjs`、`scripts/render-svg-preview.mjs` 均为 project-insight 引擎的薄壳（单一真源）；SVG 结构图新画或重排后必须跑边拓扑审计（唯一能程序化发现「看着对、边连错」的手段），成稿含图必须校验，`[MERMAID-ERROR]` 与审计非 0 不静默放过。
- `skills/svg-maker/` — 独立 SVG 图表生成（`SKILL.md` + `references/svg-template.md`）。

## 运行脚本（project-insight 的 node_modules 不入库）

`skills/project-insight/scripts/` 依赖 `mermaid`、`jsdom`（`select-baseline.mjs` 只用 node 内置模块 + `git`，无 npm 依赖）。`node_modules` 被 gitignore，**首次需在其中 `npm install`**；若本机用 `cp -r` 复制注册而非软链，复制后要在副本的 `scripts/` 重装。校验用 node 直跑（不是打包器）：
- `node scripts/select-baseline.mjs <本地路径|远端URL> [--ref <ref>] [--package <名>] [--json]`（只读：选基线 + 给落地命令；退出码 2 = 需用户确认/选择）
- `node scripts/verify-references.mjs <source_repo> <解读.md>...`（首参 = 源码仓库根 = 基线工作树，非知识库仓库）
- `node scripts/check-mermaid.mjs <解读.md>...`（在 `scripts/` 下）
- `node skills/project-wiki/scripts/check-all.mjs <输出目录|md...> [--source-repo <源码根>] [--strict] [--preview]`（project-wiki 的**唯一门禁入口**：编排自研门禁 + 上面的 Mermaid 引擎 + SVG 边拓扑审计；退出码 0 通过 / 1 存在 error / 2 用法或依赖缺失）
- `bash skills/project-wiki/scripts/tests/gates-regression.sh`（project-wiki 门禁回归：23 条断言，逐条验证「故意违规必须被拦住」）

## 写作约定

- 中文为主，代码/术语保留英文。
- 子文档**主题语义命名**（`architecture.md`、`data-model.md`），**不用数字序号前缀**。
- 标题用 Markdown 天然层级语义式命名，不加 `## 1. X` 这类数字前缀。
- git-kit 用 Conventional Commits；分支前缀映射见 `skills/git-kit/references/branch.md`（feature/fix/hotfix/refactor/release/experiment/poc 等）。
