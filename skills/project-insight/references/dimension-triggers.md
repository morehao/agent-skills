# 类型判定与关注面触发判据

> 由 SKILL.md「执行流程主干」的 step 4（类型判定与分流）与 step 5（定维度）按需加载。本文件是**判定规则层**：① 项目属于什么类型 → 加载哪个类型规格；② 项目天然带哪些关注面 → 是否拆子文档。类型规格文件本体与注册表见 [project-types/README.md](project-types/README.md)；分文件判定（拆不拆、产出形态）见 [flow-new.md](flow-new.md)。

## 类型判定与分流（step 4 细则）

### 判定来源（按优先级）

1. **README 自述类型关键词**（agent/assistant；admin/console/control panel；framework/sdk/library；im/chat/messaging…）。
2. **顶层目录结构特征**（`agent/`/`plugins/`/`memory/` → ai-agent；`internal/`/`cmd/`+仅服务端 → admin；`pkg/`+扩展接口 → framework；`protocol/`/`gateway/`/`session/` → im）。
3. **数据模型探测是否命中**（辅助，不单独定类型；探测信号见 [data-model-guide.md](data-model-guide.md)）。

> 新增类型的判定关键词/目录特征，随注册表同步补充（见 [project-types/README.md](project-types/README.md)「新增类型流程」第 3 步）。

### 主 + 副叠加

判定出主类型；若出现强相关副类型则叠加生效（如 Go 写的 agent 框架 = ai-agent ⊗ framework）。副类型规格中的子文档/关注点合并进产出，冲突时以主类型为准。各类型可叠加声明见对应规格文件头部。

### 加载对应规格

按判定结果加载 `references/project-types/{类型}.md`（注册表见 [project-types/README.md](project-types/README.md)）；无法识别时加载 [_default.md](project-types/_default.md)，回落通用默认产出，不阻塞解读。

- **标注**：产物 README 顶部标注「本解读按 {类型} 类规格产出 / 回落通用默认规格」，便于回溯。
- 类型规格只能细化该类型关注的产出结构，**不得放宽本 skill 任何通用铁律**（真源验证 / mermaid 校验 / 增量模式 / 写作规范 / 质量红线 / 索引同步）。通用默认产出规范见 [_default.md](project-types/_default.md)。

## 关注面触发判据（step 5 提名来源）

> **命中即候选、浅则并入、够深才独立成篇**，机制全程一致。候选关注面来源分三个维度：**① 被分析项目 README 自述能力点**（见 [flow-new.md](flow-new.md)「定维度」节，优先级最高）、**② 产品类型**（项目"是什么"决定的关注面）、**③ 语言惯用法**（项目"用什么写"决定的深层主题）。命中即登记候选，是否独立成文由「分文件判定」的"篇幅够不够深"决定（见 [flow-new.md](flow-new.md)）。**README 点名的独特卖点即使落在下方模板之外，仍需源码探测后尝试成文，不得因"模板没列"而忽略。**

### 产品类型维度

项目形态天然带哪些关注面；不逐条全写，取最突出者：

| 产品类型 | 典型关注面 |
|----------|-----------|
| 可部署服务（Docker/常驻/云/安装器） | 单独「部署文档」：`docker-compose.yml` / `Dockerfile` / `systemd` / `launchd` / `fly.toml` / `render.yaml` 等形态 + 运维要点 |
| 有数据存储 / 库框架自带系统表 | 单独「数据模型」文档（判据见下方第 1 条，程序化探测决定，写五要素，细则见 [data-model-guide.md](data-model-guide.md)） |
| 智能体 (Agent) | 须体现 agent 关注面：记忆/上下文机制、主 Agent 循环、工具调用、Skill 体系、MCP 接入、宿主接入协议（ACP，对外提供 client–agent 服务时）、Runtime、会话状态（详见 [ai-agent.md](project-types/ai-agent.md)） |
| 较长业务流程 | `sequenceDiagram` 时序图体现完整业务链路（跨模块数据流/事件时序），不画单模块局部流；入「架构深读」链路节或 `flow-*.md` |
| Web/API 框架 | 生命周期 / 中间件链 / 路由表 / 扩展点机制（如 Koa 洋葱模型、Hono 路由基数树） |
| CLI 工具 | 参数解析 / 插件系统 / 配置管理 / 退出码与错误约定 |
| 编译器 / 语言运行时 | IR 与 pass 架构 / 类型系统 / 求值或执行模型 / GC 或内存管理 / 前端到后端的分层 |
| 数据库 / 存储引擎 | 存算布局 / 索引结构 / WAL 与刷盘 / 事务与一致性模型 / 缓存淘汰（详见 [database.md](project-types/database.md)） |
| 前端 / UI 库 | 状态管理 / 响应式更新 / 渲染性能 / 组件组合与复用 |
| DevOps / 基础设施 | 资源抽象 / 生命周期编排 / 可观测性 / 安全边界 |

### 语言惯用法维度

项目用什么语言写，天然触发"该语言的深层惯用法"深挖；这些往往正是"值得学什么"中最有迁移价值的部分：

| 语言 | 典型深层主题 |
|------|-------------|
| Go | 协程/goroutine 与并发模型、`sync` 原语、接口组合与依赖注入 |
| Rust | 所有权与借用、生命周期、零成本抽象、`Result`/错误处理体系 |
| TypeScript 前端 | 状态管理、响应式更新、渲染性能、类型系统的深度使用 |
| Python | `asyncio`、GIL 与并发取舍、装饰器/元编程、鸭子类型与接口约定 |
| JVM（Java/Kotlin） | 内存模型、GC 调优、反射/字节码、可空性与类型设计 |

### 触发判据（显式规则 4 条）

1. **有数据存储，或作为库/工具形态自带系统表与会话/元数据存储** → 单独「数据模型」文档：核心表/实体关系、存储选型与理由、Schema 演进策略（如 JSON blob + 提升列 / 迁移）、读写路径。文件名统一 `data-model.md`（存量文档如已用 `db-design.md` 则沿用原名，新文档一律 `data-model.md`）。**必含内容与写法见 [data-model-guide.md](data-model-guide.md)**（ER 图 + 每表字段表 / 存储选型 / 核心表设计 / 演进策略 / 读写路径）。注意：是否触发该判据由「数据模型主动探测」的程序化扫描信号决定，**不由「这项目是不是业务应用」的主观印象决定**——纯 library 框架只要自带系统表（如 go-admin 的 `goadmin_*`）、迁移（`migrations/`）、或 models 实体，同样属于数据模型关注面，须覆盖。
2. **有较长业务流程** → 用 `sequenceDiagram` 时序图体现完整业务链路（跨模块/跨服务的数据流、事件时序），而非只画单模块局部流；放在「架构深读」的请求链路节或单独 `flow-*.md`。
3. **智能体 (Agent) 相关** → 必须按 [ai-agent.md](project-types/ai-agent.md) 规格覆盖其全部必含关注面：记忆机制、主 Agent 循环、工具调用、Skill 体系、MCP 接入、宿主接入协议（ACP，仅当对外提供 client–agent 接入：agent server / CLI 子进程协议 / README 含 "Agent Client Protocol"；纯库内编排则标注不适用）、Runtime、会话/任务状态、通信机制。示例文件名 `memory-system.md` / `memory.md` / `tool-calling.md` / `skill-system.md` / `mcp.md` / `acp.md` / `runtime.md`。
4. **语言惯用法命中**（语言维度表）→ 作为候选关注面独立成文（如 `goroutine-model.md`/`ownership-lifetimes.md`）或并入架构深读的相关小节；写法：每个惯用法论断带 `文件:行号` + "为什么选这个模型"的权衡，落在具体设计语境，不写成语言教科书。
