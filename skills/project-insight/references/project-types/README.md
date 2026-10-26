# 类型规格注册表（project-types）

> 本目录是 project-insight 的**类型规格层**：一个类型一份 `{类型}.md`，结构统一，在通用默认规格（[_default.md](_default.md)）基础上**追加**该类型特有要求，**不得放宽本 skill 任何通用铁律**（真源验证 / mermaid 校验 / kb_repo 判定 / 增量铁律 / 写作规范 / 质量红线 / 索引同步 / 规模门控 / 数据模型探测）。判定规则（怎么判断项目属于什么类型、关注面怎么触发）见 [../dimension-triggers.md](../dimension-triggers.md)；本文件只负责**注册与维护**。

## 注册表

| 类型 | 规格文件 | 适用 | 必拆子文档候选（命中并够深才拆） |
|------|---------|------|--------------------------------|
| 通用默认 | [_default.md](_default.md) | 无法判定为任何具体类型，或无需类型特化时回落 | —（分文件判定见 [../flow-new.md](../flow-new.md)） |
| ai-agent | [ai-agent.md](ai-agent.md) | 智能体 / AI Agent / agent 框架 / 多智能体编排 | `memory-system.md`/`memory.md`、`tool-calling.md`、`agent-loop.md`/`orchestration.md`、`skill-system.md`、`mcp.md`、`acp.md`、`runtime.md` |
| admin | [admin.md](admin.md) | 后台管理系统 / 管理面板 / 内网运营平台 | `data-model.md`、`auth-rbac.md`、`deployment.md` |
| framework | [framework.md](framework.md) | Web 框架 / SDK / 基础库 / CLI / 编译器 | `extension.md`、`api-design.md`、语言惯用法文档（如 `goroutine-model.md`） |
| im | [im.md](im.md) | 即时通讯 / 消息系统 / 聊天 / 长连接网关 | `protocol.md`、`gateway.md`、`store.md` |
| ai-infra | [ai-infra.md](ai-infra.md) | LLM 基础设施：推理服务 / 向量数据库 / RAG 编排 / LLMOps / 模型网关 | `inference-path.md`、`vector-store.md`、`rag-pipeline.md`、`observability-eval.md` |
| database | [database.md](database.md) | 数据库 / 存储引擎：关系 / KV / 时序 / 图 / OLAP / 搜索 | `storage-layout.md`、`indexing.md`、`wal-transaction.md`、`replication.md` |

> **规格化类型 ≠ 产品类型关注面**：本注册表只收录**规格化类型**（高频、强差异，值得独立规格文件）。未列入的产品类型（可部署服务、CLI、编译器、前端、DevOps 等）**不要求**建规格文件——走 `_default.md` 通用规格 + [../dimension-triggers.md](../dimension-triggers.md)「产品类型维度」关注面触发即可。**规格文件是可选深化层，不是必填义务**；新增类型按下方流程注册，全程不碰 SKILL.md。

## 规格文件统一模板

每个 `{类型}.md` 按同一骨架组织，复制现有文件（如 [framework.md](framework.md)）改造即可：

```markdown
# {类型} 类型规格（{slug}）

> 适用于：{一句话，含中英文别名}。
> 判定信号见 [../dimension-triggers.md](../dimension-triggers.md)「类型判定与分流」；本规格在通用默认规格（[_default.md](_default.md)）基础上**追加** {类型} 特有要求，不得放宽通用铁律（…）。可叠加：{副类型声明，如 "framework（暴露 SDK/插件接口时）"}。

## 固定结构块（硬规格）

### 产出形态
- 通用产出形态 / 分文件判定 / 信息密度分配 / 索引约定见 [_default.md](_default.md)，本规格仅追加 {类型} 特有要求：
- 必拆子文档候选（命中并够深才拆，主题语义命名、无 `01-` 序号前缀）：`xxx.md` …
- 拆出子文档后按其索引约定回写（见 [_default.md](_default.md)）。

### 信息密度分配
- 承接 `_default.md` 的 README 概览口径；README 架构总览侧重…
- 子文档承载…深度关注点；每篇满足通用四要素（核心结构/执行流程/设计决策/依赖）+ `文件:行号` 真源引用，且每篇至少 1 张属于本关注面的核心链路图。

## 必含要素块（硬规格）

在通用必含要素清单（`_default.md`：根因 / 概览 / 架构 / 链路 / 深挖 / 全局关联 / 真源引用）之外，{类型} 类**必须**额外覆盖以下硬规格；可放任意标题任意顺序，顺序交给叙事主线，但逐项齐全才算完成：

- **{关注面}**：…（每条论断带 `文件:行号`；核心链路命中「强制图位清单」（见 [../writing-guide.md](../writing-guide.md)）即给 `sequenceDiagram`/`graph`，不写纯文字长段）

## 自由纵深块（软区）

- 「值得学什么」落点：…
- 常见坑：…
- 深挖指引：…；深度不足标 `[WIP]`/`TODO`，不硬凑。
```

## 新增类型流程（全程不碰 SKILL.md）

| 步骤 | 动作 | 位置 |
|------|------|------|
| ① | 复制现有规格文件作模板，填写判定信号 / 必含要素块 / 自由纵深块 | 新建 `references/project-types/{类型}.md` |
| ② | 注册：上方「注册表」表加一行（类型 \| 规格文件 \| 适用 \| 必拆子文档候选） | 本文件 `README.md` |
| ③ | 判定表补一行（README 关键词 + 顶层目录特征信号） | [../dimension-triggers.md](../dimension-triggers.md)「类型判定与分流」 |
| ④ | 可选：需要在头部声明副类型叠加时补充 | `{类型}.md` 头部 |

> 完成 ①-④ 即注册完毕：SKILL.md 的 step 4 是"加载注册表 → 按需取规格"，新类型自动被覆盖，无需改动主文件。若新类型只是某已有类型的变体，先考虑复用/扩展现有规格，不轻易新建。

## 主 + 副叠加

- 判定出主类型后，若出现强相关副类型则叠加生效（如 Go 写的 agent 框架 = ai-agent ⊗ framework）：副类型规格中的子文档/关注点合并进产出，冲突时以主类型为准。
- 各规格文件头部应声明"可叠加"方向（如 framework 类常与语言惯用法叠加、ai-infra 暴露 SDK 时与 framework 叠加），供判定与合并参考。
