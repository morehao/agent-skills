---
name: project-insight
description: 开源项目深度解读，产出每个论断都带可点开验证的真实源码引用（文件:行号），避免幻觉。当用户要求"分析、解读、洞察、深读、总结某个开源项目"、问"这个项目怎么实现的、值得学什么"，或要求解读文档附带可验证的真实源码引用时使用。输入通常是本地源码绝对路径，也可接受远端地址（自动按稳定 tag / 稳定分支选定基线后克隆，而非默认分支）。Also applies when the user asks to "analyze / examine / break down / deep-dive an open-source project", "how is this implemented", or "what's worth learning from this repo".
---

# 开源项目洞察

## 核心理念

解读一个开源项目，产出的是**技术解构与提炼**，不是文档翻译或使用教程。每篇解读回答的根本问题：这个项目解决了什么、架构怎么组织、核心实现怎么落地、值得借鉴哪些模式、与同类相比的优劣势。

**落地场景：** 默认解读产物要落进一个持续维护的 Markdown 知识库仓库（`kb_repo`）。因此约定目录结构、索引同步与写作风格，都是为了这批解读在该仓库内可长期检索、可随上游演进——为"解读入库"这一场景服务。

**默认输出架构设计思路，不是编码细节。** 解读是对设计意图（Why>What、权衡、全局关联）的解构；类型定义、函数体、表结构等编码细节默认不整段贴出，仅在**用户主动要求深入某个实现**时才展开。判断"写成叙述还是贴码"的标准 = 这段是否承载了不可替代的设计观点。

解读文档最大的敌人是**幻觉**——模型编造不存在的文件、行号、接口。因此必须坚守一条铁律：

> **让程序验证，不让模型自证。**

模型只负责产出**内容**；「这份论断是否真对得上源码」的判断，一律交给程序用确定性手段（子串匹配、路径校验、真实文件读取）去证实或纠正。文档里每个 `文件:行号` 引用，都必须能经程序重定位回真实源码，可点开验证。

**先判断模式，再动作。先读现状，后动笔。**

## 铁律（违反即重来）

1. **真源验证**：所有 `文件:行号` 引用必须经 `scripts/verify-references.mjs` 程序重定位（指纹 = 首末行双锚点），定位失败标 `[UNVERIFIED]` 保留、不静默放过（完整细则见 [references/grounding-guide.md](references/grounding-guide.md)）。
2. **图表程序校验**：产出所有 Mermaid 块落盘前跑 `scripts/check-mermaid.mjs`（**该文件无 mermaid 块属正常**，选型规则允许整篇用 SVG），任一 `[MERMAID-ERROR]` 修复至全 `OK`，不保留渲染报错图（见 [references/writing-guide.md](references/writing-guide.md)「图表约束」）。
3. **增量先读、差异驱动**：增量模式下先读现有文档再动笔，每处变更必须能追溯到上游 diff / release notes（拿不到则声明代码快照比对）（见 [references/flow-incremental.md](references/flow-incremental.md)）。
4. **只落盘，不代为提交**：本 skill 只写文件、更新索引，**不自动执行 git add/commit/push**；落地后列出变更文件清单，由用户决定是否提交。
5. **基线先行**：动笔前先确定"这次解读基于哪个版本"——稳定 tag > 稳定分支 > 默认分支（main/master/远端 HEAD）> 无 main/master 兜底矩阵，由 `scripts/select-baseline.mjs` 程序化选定，不凭印象；选定后的工作树才是 `source_repo` 与引用校验根，且基线须写进产物（见 [references/version-baseline.md](references/version-baseline.md)）。基线不定就开写 = 行号必然漂移。

## 何时使用 / 何时不用

### 何时使用
- 知识库还没有某项目的解读 → **全新分析模式**（[references/flow-new.md](references/flow-new.md)）
- 已解读项目上游发新版/重大变更 → **增量模式**（[references/flow-incremental.md](references/flow-incremental.md)）
- 已有解读但用户明确要求全量/重新解读 → **删除既有解读（经确认）后走全新分析模式**
- 对已有解读觉得深度不足、再深入补充章节 → **增量模式**
- 要求解读必须**带可点开、可验证的真实源码引用**（文件路径+行号），避免幻觉

### 何时不用
- 翻译官方文档 / 写使用教程（本 skill 不做）。
- 项目专属约定（放项目的 instructions 文件，不进 skill）。
- 纯静态需求可枚举、无代码深挖场景，直接写死即可。

**临时分析判别：** 默认按"入库"规范执行（完整目录树 + 索引同步）。若用户只要一段临场解读、明确不落进知识库仓库，产出主体解读即可，并主动告知"本次未做索引同步、未做落地目录判定"；否则默认走完整入库流程（含 `kb_repo` 判定，见 [references/kb-repo-rules.md](references/kb-repo-rules.md)）。

**范围锁定（两则）：**
- 索引同步只增改**本项目**的索引条目与被改页面，不顺手重排/改写
  `{分类}/README.md` 或顶层 `README.md` 里其他项目的条目格式。
- 解读产物（`{分类}/{项目}/…`）**绝不落入被分析的源码仓库根内**；即使
  `kb_repo` 判定因排除信号走到"用户选择"分支，也不得把解读 md 写进 `source_repo`。

## 执行流程主干（按需加载路由）

每步的完整细则在对应 references 文件，命中即按需加载；**SKILL.md 只保留路由 + 每次必用的铁律与引用格式**。

| 步骤 | 做什么 | 按需加载 |
|------|--------|---------|
| 0 落地目标判定 | 输入规范化（realpath / 远端浅克隆）；`kb_repo` 判定（结构扫描 + 排除信号 + 用户选择分支） | [references/kb-repo-rules.md](references/kb-repo-rules.md) |
| 0.5 版本基线选择 | 跑 `scripts/select-baseline.mjs` 选定基线（稳定 tag > 稳定分支 > 默认分支 > 无 main/master 兜底）→ 基线工作树作 `source_repo`/校验根 → 基线写进 README 概览 + CHANGELOG | [references/version-baseline.md](references/version-baseline.md) |
| 1 模式判定 | 存在（或 grep 命中别名）→ 默认增量；**用户明确要求全量 → 删除既有解读（经确认）走全新**；不存在 → 全新 | 增量 → [references/flow-incremental.md](references/flow-incremental.md)；全新（含删后全量）→ step 2 |
| 2 规模门控分流 | 复杂度×规模 → 路径 A/B/C/D（5 万行仅经验锚点，合理性优先） | [references/flow-new.md](references/flow-new.md)；路径 C → [references/large-repo-workflow.md](references/large-repo-workflow.md) |
| 3 探索与数据模型探测 | README → 架构文档 → 目录树 → 核心模块 → 链路；其间跑「数据模型主动探测」 | [references/flow-new.md](references/flow-new.md)；命中 → [references/data-model-guide.md](references/data-model-guide.md) |
| 4 类型判定与分流 | README 关键词 + 顶层目录特征判定类型（主+副叠加，冲突以主类型为准）→ 加载对应规格 | [references/dimension-triggers.md](references/dimension-triggers.md) → [references/project-types/README.md](references/project-types/README.md) → `references/project-types/{类型}.md`（未识别回落 [_default.md](references/project-types/_default.md)） |
| 5 定维度 | README 自述提名（优先级最高）+ 类型/语言模板提名 → 源码探测验证后取 2-4 个深入 | [references/dimension-triggers.md](references/dimension-triggers.md) + [references/flow-new.md](references/flow-new.md) |
| 6 写作 | 写深不翻译：Why>What、权衡、叙事连贯、四要素；写作细则与图表约束；**叙述型文档动笔前先过「写作口径确认四问」** | [references/analysis-guide.md](references/analysis-guide.md) + [references/writing-guide.md](references/writing-guide.md) + [references/narrative-design-template.md](references/narrative-design-template.md)（叙述型骨架/13 章）+ [references/quantification.md](references/quantification.md)（量化口径）+ [references/figure-batch-workflow.md](references/figure-batch-workflow.md)（多图并行） |
| 7 真源 + 图表 + 结构校验 | 对本次产出全部 md 跑 `verify-references.mjs` 与 `check-mermaid.mjs`；**另有 `architecture-design.md` 时跑 `scripts/check-narrative-all.mjs`（内含 `scan-narrative.mjs` + mermaid + SVG 边拓扑审计，`--preview` 出预览图）**，非 0 退出码视为未通过 | [references/grounding-guide.md](references/grounding-guide.md) + [references/figure-batch-workflow.md](references/figure-batch-workflow.md) |
| 8 索引同步（收尾三步） | 建项目 README → 更新 `{分类}/README.md` 索引 → 必要时顶层 README 加分类 | [references/kb-repo-rules.md](references/kb-repo-rules.md) |
| 9 提交边界 | 列出变更文件清单，不代为 git commit | — |

## 文档元数据（frontmatter）纪律

每篇解读文档（README 与各关注面子文档）开头统一放轻量 YAML frontmatter，作为可检索的元数据头：
- **必写 / 推荐** `type`（短描述性概念类型）、`title`（人类可读标题）、
  `description`（一两句、面向检索优化的摘要）、`tags`（稳定英文标签）。
  `description` 专门服务知识库检索——决定读者在索引能否命中这篇，务必
  具体、含项目与关注面关键词。
- **不写** 时间戳、版本、`文件:行号` 计数等"由程序/定期维护生成"的字段；
  留给外部索引，解读作者不臆造。
- **保留** 已有用户扩展字段：增量时未知字段原样保留，仅事实/正文变化才改。

> frontmatter 是文档自带的 YAML 头，不是外置清单文件——不违背本 skill
> "信息源单一 = 文档自身"的约束。

## 引用格式（高频必用；完整细则见 [references/grounding-guide.md](references/grounding-guide.md)）

- 引用路径用**仓库相对路径 + 行号**：`模块/子目录/文件名.ext:行号`（如 `pkg/utils/util.go:42`）；禁止裸文件名。
- 正文呈现 = 「一句结论/权衡 + `[path:start-end]()`」，**不内嵌整段代码**；完整实现交给读者点源码。
- 每条展示引用后紧邻**首末行双锚点指纹注释**（不进入正文渲染）：`<!-- anchor: 区间首行原文 … 区间末行原文 -->`；锚点从源码**逐字复制**（各 ≤1 行、行首截断 ≤80 字符、含 `--` 用 base64 `<!-- anchor-base64:… -->`）。
- **定位失败不允许静默放过**：找不到匹配的引用保留原样并追加 `[UNVERIFIED]`，文末汇总列出供人工复核。

## 必含要素清单（统一核查底线；不绑定标题、不绑定顺序）

| 必含要素 | 承载内容 | 说明 |
|----------|---------|------|
| 根因 | 解决什么根本问题 | 全篇锚点，防止功能罗列 |
| 概览 | 是什么 / 痛点 / 适用场景 | 配核心能力清单表 + 技术栈一览表 |
| 架构 | 架构总览图（按选型规则用 SVG 或 Mermaid）/ 模块职责映射(目录树) | 架构与模块对应 |
| 链路 | 启动流程 或 请求链路 | 图承载，非文字长段 |
| 深挖 | ≥1 个按项目特点深入的关注面 | 核心实现 / 设计模式 / 部署 / 数据模型 / 插件与 MCP / 语言惯用法…，Why>What + 权衡 |
| 全局关联 | 每个模块分析连回整体设计哲学 | 叙事连贯，避免孤立代码审查 |
| 真源引用 | ≥2 处带 `仓库相对路径/文件.ext:行号` 的代码引用 | 经程序重定位验证 |

> **标题一律用 Markdown 天然层级，不加数字序号前缀。** 顶层 `##` 即最高章节，`###`/`####` 表达从属关系；不写 `## 1. X`、`## 0. X`、`## 第N部分：X` 这类数字前缀标题（**唯一例外**：叙述型 `architecture-design.md` 允许 `## 一、` 与 `### N.M` 编号——设计文档惯例、长文交叉引用依赖编号，代价由 `[HEADING-SEQ]`/`[XREF-DANGLING]` 兜底，见 [references/narrative-design-template.md](references/narrative-design-template.md)）；并列列举如需体现顺序用语义词（`## 决策一` / `### 亮点` / `### 问题`），列表项内部序号不算标题。**硬化"要素"而非"章节标题/顺序"**——要素人人一致、顺序交给叙事主线（数据流 / 分层 / 问题驱动，见 [references/analysis-guide.md](references/analysis-guide.md)）。分文件判定（≥3 个可独立深挖的关注面必须拆子文档）与产出形态见 [references/flow-new.md](references/flow-new.md)。

## 质量红线（提交前逐项自检，两模式均适用）

- [ ] `kb_repo` 已通过判定或用户确认，不是凭 cwd 直接臆断
- [ ] **基线已程序化选定并记录**：跑过 `scripts/select-baseline.mjs`（稳定 tag > 稳定分支 > 默认分支 > 无 main/master 兜底矩阵），`source_repo` 就是该基线的工作树（脏工作树未被静默覆盖，收尾已恢复原 HEAD）；基线已写进 README 概览一行 + `CHANGELOG.md` 顶部条目；`[BASELINE-STALE]` / `[BASELINE-AMBIGUOUS]` 已走用户确认（[references/version-baseline.md](references/version-baseline.md)）
- [ ] 核心能力清单表 / 技术栈一览表 / 架构总览图（工具按选型规则）/ 至少一条启动流程或请求链路 / ≥2 处带 `仓库相对路径/文件.ext:行号` 的代码引用 / 根因说清
- [ ] **定维度已纳入被分析项目 README 自述能力点**：README 宣传的核心能力已列为候选关注面并经源码探测——属实且够深则成文；与源码不符（过时/夸大）处已标注并剔除，未因"模板没列"而漏掉
- [ ] 多关注面项目已按关注面拆子文档，未把全部内容压进单个 README；README 含独立「子文档索引」专章列全 + 「核心模块导读表」每行就近内链，新增即回写
- [ ] **已按类型规格加载并覆盖了对应关注面**：按 [references/project-types/README.md](references/project-types/README.md) 注册表加载对应类型规格，逐项覆盖其「必含要素块」；回落 `_default.md` 时已标注「按通用默认规格产出」；类型规格仅补充细化，未放宽任一通用铁律
- [ ] **数据模型关注面已按「数据模型主动探测」判定**：跑过探测信号（`*.sql` / `migrations/` / models 实体 / ORM 建表入口），命中即按 [references/data-model-guide.md](references/data-model-guide.md) 五要素成文、未命中不硬凑
- [ ] **类型触发项已覆盖**：可部署 → 部署文档（docker-compose / Dockerfile / systemd 等形态 + 运维要点）；长流程 → 跨模块 `sequenceDiagram`；智能体 → 记忆 / Agent 循环 / 工具调用 / Skill / MCP / Runtime / 会话状态 / 宿主接入协议（ACP，agent 对外提供 client–agent 服务时；按 [references/project-types/ai-agent.md](references/project-types/ai-agent.md)）；命中语言惯用法维度 → 对应深层主题成文（落在设计语境 + `文件:行号`，非语言教科书）
- [ ] 深度达标：关键论断含 Why / 权衡 / 对比（而非泛泛而谈），核心模块满足四要素可复现性（[references/analysis-guide.md](references/analysis-guide.md)）
- [ ] **正文无整段贴码**：编码细节化为叙述 + `文件:行号`，代码块仅留承载设计的关键片段，无 `> [path] — 整段代码` 孤立块
- [ ] **强制图位已用图**：启动流程 / 核心请求链路 / 连接-会话生命周期 / 跨模块时序命中即给**图**（工具按 [references/kb-repo-rules.md](references/kb-repo-rules.md) 选型规则）；数据模型文档已有 ER 图 + 每张核心表字段表；每篇子文档 ≥1 张本关注面核心链路图
- [ ] 标题为语义式（`##` 层级 + 语义词），无 `## 0.` / `## 1.` / `## 第N部分` 数字前缀（**叙述型 `architecture-design.md` 除外**：按 [references/narrative-design-template.md](references/narrative-design-template.md) 用 `## 一、` + `### N.M` 编号，且编号与引用已通过程序校验）；正文中文为主、英文引用必配中文解读，无孤立纯英文段落
- [ ] 索引同步：已落在 `kb_repo` 并更新 `{分类}/README.md`，必要时顶层 `README.md`
- [ ] **frontmatter 元数据合规**：每篇解读文档带 `type/title/description`
      （+可选 `tags`），`description` 面向检索；无线索自造时间戳/版本等程序
      字段；增量时保留未知扩展字段
- [ ] **引用增量门禁（增量模式）**：动笔前已跑 `verify-references.mjs --diff`，
      STALE/UNRESOLVED 对应章节才改、STABLE 章节原文保留；无改依据时已止损
- [ ] **所有代码引用经程序重定位验证**（`verify-references.mjs` 全过，非记忆行号）；定位失败已标 `[UNVERIFIED]` 并汇总列出；路径为仓库相对路径且未脱离仓库根（[references/grounding-guide.md](references/grounding-guide.md)）
- [ ] **指纹注释仅首末行锚点**：每条引用后至多含区间首行 + 末行两行原文（各 ≤1 行、截断 ≤80 字符），无整段代码注释；锚点逐字复制、含 `--` 用 base64
- [ ] **已产出 `architecture-design.md`（叙述型架构设计说明，零代码索引、与证据型完全隔离）**：骨架按 [references/narrative-design-template.md](references/narrative-design-template.md) 的七步/13 章，必含清单齐全（含总体架构、模块责任、决策备选与复审触发条件、验收与开放问题）；量化按三档口径（[references/quantification.md](references/quantification.md)）；跑过 `scripts/check-narrative-all.mjs` 通过（含 `[HEADING-SEQ]` / `[XREF-DANGLING]` / `[FIGURE-ONLY]`）（[references/kb-repo-rules.md](references/kb-repo-rules.md)「叙述型文档」）
- [ ] **SVG 图由 `svg-maker` skill 产出**（环境无此 skill 时才自绘并说明）；所有 Mermaid / SVG 图可渲染、不报错，且无 mermaid + svg 重复；Mermaid 块已跑 `scripts/check-mermaid.mjs` 全 `OK`，`[MERMAID-WARN]`（`<br>` 换行 lint）已收敛为 0；**图表已按复杂度选型**（节点 ≥12 或含分叉/汇合/分区/泳道/回边 → SVG，见 [references/writing-guide.md](references/writing-guide.md)「图表约束」）；**SVG 已跑 `scripts/audit-svg-topology.mjs` 核对边拓扑，并用 `scripts/render-svg-preview.mjs` 出图目视核验**
- [ ] 源码输入为本地绝对路径，`source_repo` 已用 `realpath` 规范化并作验证根（= **选定基线的工作树**，不是随手一个 HEAD）
- [ ] 落盘后已列出变更文件清单供用户决定是否提交，未擅自执行 git commit

## 常见错误与对策

写作/校验中遇到反复问题时，对照 [references/errors-and-fixes.md](references/errors-and-fixes.md) 自查。高发项：信任记忆行号、正文/指纹整段贴码、流程写纯文字长段、数据模型写成字段清单、漏拆子文档/漏索引、mermaid 渲染报错、**重排章节后编号重复/交叉引用失效**、**图看着对但边连错**、**没有实测数据时编造指标或只写"缺失"**、**把欠账写成"刻意的设计选择"**。
