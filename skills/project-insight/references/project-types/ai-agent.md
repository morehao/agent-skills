# ai-agent 类型规格（ai-agent）

> 适用于：智能体 / AI Agent / agent 框架 / 多智能体编排 类项目。
> 判定信号见 [../dimension-triggers.md](../dimension-triggers.md)「类型判定与分流」；本规格在通用默认规格（[_default.md](_default.md)）基础上**追加** ai-agent 特有要求，不得放宽通用铁律（真源验证 / mermaid 校验 / kb_repo 判定 / 增量铁律 / 写作规范 / 质量红线 / 索引同步 / 规模门控 / 数据模型探测）。可叠加：framework（对外暴露扩展接口时）。

## 固定结构块（硬规格）

### 产出形态

通用产出形态 / 分文件判定 / 信息密度分配 / 索引约定见 [_default.md](_default.md)，本规格仅追加 agent 特有要求：

- 必拆子文档候选（命中并够深才拆，主题语义命名、无 `01-` 序号前缀）：
  - `memory-system.md` / `memory.md`：记忆机制（见必含要素块；对应 [../dimension-triggers.md](../dimension-triggers.md)「触发判据」第 3 条：智能体必须体现记忆机制，示例即 `memory-system.md` / `memory.md`）
  - `tool-calling.md`：工具调用与 Function/Tool 协议（工具 schema、注册/执行、错误传播、结果回注）
  - `agent-loop.md` / `orchestration.md`：主 Agent 循环 / 多 Agent 协作与任务编排（作为独立关注面够深时拆此篇）
  - `skill-system.md` / `skills.md`：Skill/技能体系（见必含要素块）
  - `mcp.md`：MCP 与外部能力接入层（见必含要素块）
  - `acp.md`：宿主接入协议层（仅 agent 对外提供 client–agent 服务时；见必含要素块）
  - `runtime.md`：运行时引擎（见必含要素块）
- 若 agent 项目自带会话/元数据存储，仍须跑「数据模型主动探测」并按五要素独立成 `data-model.md`（判定由程序化信号决定，不由"是否业务应用"的主观印象跳过；五要素细则见 [data-model-guide.md](../data-model-guide.md)）。
- 拆出子文档后按其索引约定回写（见 `_default.md`）。

### 信息密度分配

- 承接 `_default.md` 的 README 概览口径；README 架构总览侧重整体职责链（Agent → Memory → Tools → LLM 编排）。
- 子文档承载记忆系统、工具调用、Agent 循环、多 Agent 编排等转发深关注点；每篇满足通用四要素（核心结构/执行流程/设计决策/依赖）+ `文件:行号` 真源引用，且每篇至少 1 张属于本关注面的核心链路图。

## 必含要素块（硬规格）

在通用必含要素清单（`_default.md`：根因 / 概览 / 架构 / 链路 / 深挖 / 全局关联 / 真源引用）之外，ai-agent 类**必须**额外覆盖以下硬规格；可放任意标题任意顺序，顺序交给叙事主线，但逐项齐全才算完成：

- **记忆机制**：分层记忆（curated/episodic/prospective）、上下文压缩 / compaction、检索策略、持久化。（每条论断带 `文件:行号`；核心链路命中「强制图位清单」（见 [../writing-guide.md](../writing-guide.md)）即给 `sequenceDiagram`/`graph`，如"从检索到回注上下文"的时序，不写纯文字长段）
- **主 Agent 循环**：感知 / 推理 / 规划 / 行动 的循环结构、停止条件、token 预算（上下文耗尽时的行为、最大步数/最大调用上限）。
- **工具调用**：工具定义 schema、函数执行、错误传播、结果回注上下文（谁注册/校验工具、调用失败的传播链、结果如何写回对话与记忆）。
- **会话 / 任务状态**：会话持久化、任务级状态、多轮上下文管理（状态存哪里、何时读、失败如何恢复）。
- **Skill 体系**：技能如何定义与编排（schema/清单）、发现与加载机制、内容如何注入系统上下文（Prompt 拼接位置与优先级）、与内置工具/插件的关系、命中触发判据。能力点足以覆盖才独立 `skill-system.md`；项目无 skill 概念则标注"该方向不适用，不硬凑"。
- **MCP / 外部能力接入**：采用的 transport（stdio / HTTP / SSE 等）、客户端-服务端角色划分、工具/资源/提示三元协议如何映射进内部工具调用、错误与时序治理（超时 / 重连 / 流式半开）。内置工具无 MCP 时标注不适用；够深入时可独立 `mcp.md`。
- **宿主接入协议（ACP，agent 对外提供 client–agent 服务时必含）**：当项目以宿主（client）→ agent 形态对外暴露——被编辑器/宿主应用拉起（agent server / CLI 子进程协议），判定信号：README/源码含 "Agent Client Protocol"、`acp/`、agent server、JSON-RPC over WebSocket + session 生命周期——才覆盖：client/agent 角色划分与各自持有的状态、session 生命周期（`session/new`、prompt、流式 update、abort 等；方法名/版本按项目实际演进组织，不背书外部规范版本号）、transport 选择（stdio / TCP）与进程/连接生命周期、工具调用与权限请求在宿主与 agent 间的往返（谁声明、谁执行、宿主侧授权/审批点）、会话保存与恢复、取消与错误语义。纯库内编排、无宿主侧协议则标注"该方向不适用，不硬凑"。层次区分：MCP = agent 接**能力**（工具/资源），ACP = 宿主接 **agent 产品**，两者常并存（同一 agent server 既是 MCP client 又是 ACP server）；够深可独立 `acp.md`（项目自有叫法优先，如 `agent-server.md`）。
- **Runtime（运行时）**：承载 Agent 循环的引擎层职责——请求分发、会话状态机、授权 / 沙箱边界、上下文与 token 预算管理、进程 / 事件循环生命周期。刻意区别于「主 Agent 循环」：runtime 是策略的执行引擎，循环是策略本身。够深入时可独立 `runtime.md`。
- **通信机制**：Agent 与工具 / MCP 服务端 / 多 Agent 之间的消息通信方式（IPC、stdin 协议、事件总线、流式），信任边界与错误传播。并入 runtime / mcp 叙述，不单独成篇。

## 自由纵深块（软区）

- 「值得学什么」落点：Agent 如何做记忆分层的权衡、工具调用的可靠性设计（重试 / 超时 / 权限）、多 Agent 之间的通信与信任边界、Skill 的发现与注入机制、MCP 的 transport 与错误治理、宿主接入协议（ACP）的 session 生命周期 / 权限往返 / transport 治理、运行时与主循环分离的职责边界。
- 常见坑：
  - 把记忆系统写成表/清单而非设计——应讲检索策略与 compaction 权衡（Why>What），而不是罗列缓存项。
  - 只讲 What（用了什么模型）不讲 Why（为什么不提前缀总结件、为什么选这种上下文管理）。
  - 工具调用只写"支持哪些工具"，不讲调用可靠性（重试、超时、权限、结果回注失败时的处理）。
  - Skill/MCP 写成"支持哪些工具/技能"的清单而非设计——应讲命中触发、上下文注入、transport 与服务治理的权衡。
  - 把宿主接入协议写成方法清单（罗列 session 方法名）而非设计——应讲 session 生命周期、工具与权限在宿主/agent 间的往返、transport 与进程治理；尤其不要把 ACP（宿主→agent）与 MCP（agent→工具）两层混为一谈。
  - 把 Runtime 与主循环混为一谈——应讲清引擎层（runtime）与策略层（循环）的分离，各自管什么。
- 深挖指引：比较不同 agent 项目的记忆 / 上下文管理 / 工具调用方案，提炼可迁移模式；比较其 Skill 注入方式、MCP 接入的可靠性、宿主接入协议（ACP）的 session 与权限模型，及 ACP / MCP / A2A / AG-UI 的分层取舍、运行时与主循环的耦合度；深度不足标 `[WIP]`/`TODO`，不硬凑。
