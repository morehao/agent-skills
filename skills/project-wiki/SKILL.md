---
name: project-wiki
description: 为开源项目生成面向广泛读者的 Wiki 文档（Markdown）：散文为主 + 架构图 + 表格，代码密度极低，读者不打开源码也能读懂。当用户要求"给这个项目写份文档/wiki/说明""生成项目文档给团队看""把这套代码整理成可读的介绍""写个新人上手指南"时使用；**已有 wiki 需要随上游版本更新**（发新版后同步文档）时同样适用——更新模式以版本基线为 diff 两端，只改受影响的页，未受影响的页可证明仍成立、不重写。定位上与 project-insight 明确分工——需要逐条可点开验证的源码引用、要深挖设计权衡与实现细节时用 project-insight；本文档的读者是不读源码的人。Also applies when the user asks to "write a wiki / docs / overview / README-style guide for a repo", "generate readable project documentation", "update an existing wiki after a release", or "explain this codebase to the team".
---

# 项目 Wiki 文档

## 核心理念

**读者不打开源码，也能读懂这个项目。** 这句话是所有取舍的唯一来源。

deepwiki 式的项目文档之所以好读，不是因为写得"浅"，而是因为它把**表达手段按读者成本排了序**：

| 手段 | 读者成本 | 用在哪 |
|------|---------|--------|
| 散文 | 最低 | 讲清"是什么、为什么、解决什么问题" |
| 图 | 低 | 结构、流程、时序、状态——凡是有形状的东西 |
| 表格 | 低 | 一切可枚举的东西（能力、接口、配置、字段） |
| 代码 | **最高** | 只在"不看代码就说不清"时，且必须极短 |

本 skill 与 `project-insight` 的分工，一句话说清：

- **project-insight**：产出**可验证的技术解构**——每个论断带经程序重定位的 `文件:行号`、锚点指纹、
  设计权衡四要素。读者是能读源码的工程师。
- **project-wiki（本 skill）**：产出**可读的项目文档**——散文 + 图 + 表，代码与行号降到点缀。
  读者是**不读源码的人**：技术选型者、新加入的成员、跨团队同事、未来的自己。

同一段源码，两个 skill 该产出完全不同的文档；**不要用本 skill 的规范去做 project-insight 的活**。

**真实性不靠"把证据堆进正文"来证明**。本 skill 的防幻觉机制全部发生在**作者侧**：
动笔前读真源码、落盘后跑程序校验路径与行号是否真实存在。
读者看到的是一份干净的文档，不是一份带校验痕迹的文档。
机制细节与**明确放弃的精度**见 [references/grounding-light.md](references/grounding-light.md)。

## 铁律（违反即重来）

1. **零指纹、零校验痕迹进正文**。正文不出现 `<!-- anchor: … -->`、`<!-- snippet: … -->`、
   `Sources:` 前缀、行号百分比、"已校验"之类字样。校验是过程，不是产物。
2. **代码预算**：每页非图表代码块 ≤3 块、单块 ≤15 行、单页合计 ≤40 行。
   超出即 `[DOC-CODE-HEAVY]`；要么删，要么在页内写一行 `<!-- code-budget: <理由> -->` 说明为何不可省。
   这条铁律直接对应本 skill 存在的理由，**不是建议**（见 [references/writing-style.md](references/writing-style.md)「代码准入三问」）。
3. **结构先行**：动笔前先产出**页面清单**（每页：标题 / 一句话职责 / 重要度 / 依据文件 / 关联页），
   落在首页 `README.md` 的索引表里。没有清单就开写 = 必然重复与遗漏
   （见 [references/page-plan.md](references/page-plan.md)）。
4. **凡有形状必给图**：架构、请求链路、时序、生命周期、状态流转命中即给图，
   禁止用文字长段描述过程。图要真渲染通过（程序校验，不靠模型自证）。
5. **只写源码支持的内容**。不编造文件路径、版本号、性能数字、路线图。
   拿不准的要么去源码核实，要么**不写**——不允许用"可能/大概/通常是"来蒙混
   （见 [references/grounding-light.md](references/grounding-light.md)「不可编造清单」）。
6. **只落盘，不代为提交**。产出后列出文件清单，不执行 `git add/commit/push`。
7. **快照唯一**：产物的全部校验都发生在**它自述的那一个基线**上——首页契约行写的是哪个 ref，
   `--source-repo` 就必须指向哪棵工作树，并且传 `--expect-baseline` 一起交给门禁。换了树，
   "校验通过"没有意义（见 [references/version-contract.md](references/version-contract.md)）。
   > 铁律的强制力一直来自**作者自律**：程序只负责**让违反可见**（`[DOC-BASELINE-*]` 与
   > `[DOC-SRC-BASELINE-MISMATCH]` 都是 note，不阻断）。"不阻断"不等于"可以不做"——
   > 它是把判断权交回作者，而不是取消这条要求。

## 何时使用 / 何时不用

### 何时使用
- 用户要"一份文档/wiki/介绍/上手指南"，读者是**人**，不是要顺着行号去核源码的人
- 项目已成型，需要沉淀成可读的架构与能力说明
- 需要给非本项目的同事讲清楚"这东西是什么、怎么用、怎么部署"
- **已有 wiki 需要随上游版本更新**（上游发新版 / 要补充深度）→ **更新模式**
  （见 [references/update-flow.md](references/update-flow.md)）

### 何时不用
- **需要逐条可验证的源码引用、要深挖设计权衡** → 用 `project-insight`
- **写技术方案/设计文档**（要做什么、怎么改、影响面）→ 用 `tech-design`
- **只要一张独立的图** → 用 `svg-maker`
- 翻译官方文档 / 抄 README 改排版（本 skill 不做，那是复述不是产出）

## 执行流程主干（按需加载路由）

| 步骤 | 做什么 | 按需加载 |
|------|--------|---------|
| 0 定基线 | 确定"这份文档描述的是哪个版本"：稳定 tag > 稳定分支 > 默认分支 > 无 main/master 兜底矩阵，由 `scripts/select-baseline.mjs` 程序化选定；陈旧 / 歧义走**三选一裁决** | [references/version-contract.md](references/version-contract.md) |
| 0.5 版本契约 | 把选定结果写成首页**唯一一处**契约行（ref + 短 SHA + 日期），并确认 `--source-repo` 就是该基线工作树 | [references/version-contract.md](references/version-contract.md) |
| 1 落点判定 | 确定文档落在哪：独立模式 `<cwd>/<项目名>-wiki/` 或 KB 模式 `{kb_repo}/{分类}/{项目名}-wiki/`；**绝不落在被描述项目的源码根内** | [references/landing.md](references/landing.md) |
| 2 模式判定 | `{输出目录}/README.md` 存在且含页面索引 → **更新模式**；否则全新 | 更新 → [references/update-flow.md](references/update-flow.md)；全新 → step 3 |
| 3 探索 | README（自述能力点，权重最高）→ 目录树 → 依赖清单 → 部署文件 → 核心模块 → 主链路 | [references/page-plan.md](references/page-plan.md) |
| 4 规划页面清单 | 定 4-12 页，每页一句话职责且**互不重叠**；产出首页骨架（索引表 + 阅读顺序） | [references/page-plan.md](references/page-plan.md) + [references/page-templates.md](references/page-templates.md) |
| 5 逐页写 | 按页面骨架：引言 → 分节 → 图 → 表 →（可选）代码 → 依据 → 小结 | [references/page-templates.md](references/page-templates.md) + [references/writing-style.md](references/writing-style.md) + [references/diagrams.md](references/diagrams.md) |
| 6 校验 | 跑 `scripts/check-all.mjs`：依据行真实性 + 代码预算 + 索引一致 + Mermaid 真渲染 + 契约行与落点；非 0 即未通过 | [references/grounding-light.md](references/grounding-light.md) |
| 7 收尾 | 回填首页索引与阅读顺序；**逐条回应每一条 note**；列出变更文件清单，不代为 commit | — |

## 页面骨架（通用，不绑定标题字面）

每页都应能回答"读者读完这页知道了什么"。按下面的顺序组织，**不适用的节直接删掉，不留 N/A**：

1. **引言**（1-2 段）：这页讲什么、它在整个系统里的位置、读者读完能回答哪个问题。
2. **分节正文**（`##` / `###` 语义式标题，不加 `## 1.` 数字前缀）：
   讲清架构、组件、数据流或逻辑。先给结论，再展开理由。
3. **图**：凡有形状的内容给图（结构/时序/状态/数据流）；图前一句导读、图后一句"该看什么"。
4. **表**：可枚举的东西一律成表——能力清单、接口、配置项、数据字段、错误码、环境变量。
5. **代码**（默认不出现）：仅当"不看代码就说不清"时给**极短**片段，且前后必有散文解释它在说什么。
6. **依据**（章末一行，聚合式）：`> 依据：\`path/a.go:112-168\`、\`path/b.ts:45-90\``
7. **小结**（可选）：这页的要点回扣到整体。

各类页面的骨架与必答问题见 [references/page-templates.md](references/page-templates.md)。
产出形态（首页 + 主题页）与文件命名约定见 [references/page-plan.md](references/page-plan.md)。

## 引用与真实性的轻量口径

- **依据行聚合，不逐句内联**。每章末尾一行 `> 依据：…` 集中列出该章结论的源码出处；
  正文只在关键论断处点缀行内引用，每页行内引用 **≤5 处**（超出报 `[DOC-INLINE-REFS]`）。
  > 这是与 project-insight 最大的形式差异：那边每句论断后紧跟 `文件:行号` + 锚点指纹；
  > 这边把出处**收进章末一行**，读的时候可以整行跳过，想深究的人又能顺着去查。
- **不写可点击链接**。依据行用 code span（`` `path:line` ``），不做 `[path]()` 之类的链接语法——
  产物不依赖任何渲染服务与外链解析，读者在 GitHub / 编辑器里直接读。
  注意这只约束**链接写法**，不约束表达手段：该出图就出图（Mermaid 内嵌，或 `assets/` 下的 SVG）。
- **明确放弃的精度**（有意取舍，不是疏漏）：不做锚点指纹、不做逐句行号重定位。
  程序只保证**路径真实存在、行号落在文件范围内**；行号可能有小幅偏移。
  这挡住了绝大多数幻觉（编造文件、离谱行号），代价是可读性；细则见
  [references/grounding-light.md](references/grounding-light.md)。
- **正文合法声明**（不受铁律 1 约束）：契约行（`**本文档依据**：…`）、陈旧 / 未发布版本声明、
  「现状与边界」，都是**读者需要**的信息，不是校验痕迹。前两类是版本口径，后者是诚实声明——
  该写就写，不要为了"干净"把它们删掉（清单见 [references/grounding-light.md](references/grounding-light.md)）。

## 质量红线（落盘前逐项自检）

- [ ] 首页 `README.md` 有**页面索引表**与**建议阅读顺序**；索引里的每个文件都真实存在，每个真实页面都被列出
- [ ] 页面清单已先于正文产出，每页一句话职责**互不重叠**；重叠的已合并
- [ ] **代码预算达标**：每页 ≤3 块 / 单块 ≤15 行 / 单页 ≤40 行；超出的已删或已写 `<!-- code-budget: 理由 -->`
- [ ] **正文无校验痕迹**：无 `<!-- anchor -->`、无 `Sources:`、无"已校验"字样
- [ ] **凡有形状必给图**：架构总览、请求链路、时序、生命周期、状态流转命中即给图；每页 ≥1 张本页主题图
- [ ] 每张图有图前导读与图后着落，不是孤立插图
- [ ] 可枚举内容已成表（能力 / 接口 / 配置 / 字段 / 错误码），没有退化成散文罗列
- [ ] 依据行存在的章节，其引用的路径与行号已由 `scripts/check-all.mjs --source-repo <基线工作树>` 校验通过
- [ ] Mermaid 全部真渲染通过（`[MERMAID-ERROR]` 为 0）
- [ ] 标题为语义式，无 `## 1.` / `## 0.` / `## 第N部分` 数字前缀
- [ ] 每页带 frontmatter（`title` + `description`），`description` 面向检索；KB 模式下含 `type: 项目 Wiki`
- [ ] 首页**契约行**存在且可核对：ref + 短 SHA + 日期（日期取自 git），`[DOC-BASELINE-*]` 无未处理项
- [ ] **校验根正确**：`--source-repo` = 基线工作树，且与 `--expect-baseline` 一起传（`[DOC-SRC-BASELINE-MISMATCH]` 已处理）
- [ ] 全文中文为主，术语与标识符保留英文；无未解释的孤立英文长段
- [ ] 没有编造的版本号、性能数字、路线图；不确定的内容已删除而非含糊表述
- [ ] 文档**未落入被描述项目的源码根内**（`[DOC-DOCROOT-IN-SRC]` 为 0）；KB 模式下索引已同步（`[DOC-KB-UNLINKED]` 已处理）
- [ ] **每一条 note 都已逐条回应**（含预检脚本产出的 `[DOC-UPDATE-*]`）：命中页 + 处置，写进交付清单
- [ ] 已列出变更文件清单，未代为 commit

## 常见错误与对策

| 坑 | 表现 | 对策 |
|---|---|---|
| 写成了 project-insight | 满篇 `文件:行号` + 段段贴码 + 锚点注释 | 回到核心理念：读者不打开源码。把出处收进章末依据行 |
| 用代码代替解释 | "核心逻辑见下" + 30 行代码 | 代码准入三问（[writing-style.md](references/writing-style.md)）；过不了就用散文讲清它做了什么 |
| 逐函数罗列 | "模块 A 有 f1、f2、f3……" | 聚合成能力/职责表，讲"能做什么"而不是"有什么函数" |
| 图是插图 | 小节里孤零零一张图 | 图前给导读（这是什么），图后给着落（该看什么、代价是什么） |
| 页面职责重叠 | 架构页与能力页讲同一批模块 | 规划阶段合并；一页只回答一个问题 |
| 含糊代替核实 | "性能应该不错""大概是这么实现的" | 去源码核实，或**删掉**。不许用模糊词兜底 |
| 抄 README 当文档 | 结构与 README 雷同 | README 是**线索来源**不是产出模板；文档要回答 README 没回答的"为什么"与"怎么运转" |
