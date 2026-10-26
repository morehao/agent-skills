# ai-infra 类型规格（ai-infra）

> 适用于：LLM 基础设施 类项目——推理服务与部署框架（vLLM / TGI / Ollama）、向量数据库（Milvus / Qdrant / Chroma）、RAG 编排与中间件（LlamaIndex / LangChain 类）、Embedding / 重排服务、LLMOps 与评测（evals / 可观测）、模型网关与路由（LiteLLM / OpenRouter 类）、Agent 运行时平台（Dify / n8n 类）。
> 判定信号见 [../dimension-triggers.md](../dimension-triggers.md)「类型判定与分流」；本规格在通用默认规格（[_default.md](_default.md)）基础上**追加** ai-infra 特有要求，不得放宽通用铁律（真源验证 / mermaid 校验 / kb_repo 判定 / 增量铁律 / 写作规范 / 质量红线 / 索引同步 / 规模门控 / 数据模型探测）。可叠加：framework（对外暴露 SDK / 插件接口时）。

## 固定结构块（硬规格）

### 产出形态

通用产出形态 / 分文件判定 / 信息密度分配 / 索引约定见 [_default.md](_default.md)，本规格仅追加 ai-infra 特有要求：

- 必拆子文档候选（命中并够深才拆，主题语义命名、无 `01-` 序号前缀）：
  - `inference-path.md`：推理 / 请求链路（模型加载、调度、流式 token、批处理与抢占）
  - `vector-store.md`：向量存储与检索（索引结构、量化、过滤、持久化）
  - `rag-pipeline.md`：RAG 数据链路（切分 / embedding / 检索 / 重排 / 上下文组装）
  - `observability-eval.md`：可观测与评测（指标、trace、eval 集、回归门禁）
- 若自带会话/元数据存储或 RAG 语料存储，仍须跑「数据模型主动探测」并按五要素独立成 `data-model.md`（判定由程序化信号决定；五要素细则见 [../data-model-guide.md](../data-model-guide.md)）。
- 拆出子文档后按其索引约定回写（见 `_default.md`）。

### 信息密度分配

- 承接 `_default.md` 的 README 概览口径；README 架构总览侧重整体请求链路（Client → Gateway/Router → Serving → Model/Vector Store）与各层职责。
- 子文档承载推理调度、向量检索、RAG 管线、观测评测等深度关注点；每篇满足通用四要素（核心结构/执行流程/设计决策/依赖）+ `文件:行号` 真源引用，且每篇至少 1 张属于本关注面的核心链路图。

## 必含要素块（硬规格）

在通用必含要素清单（`_default.md`：根因 / 概览 / 架构 / 链路 / 深挖 / 全局关联 / 真源引用）之外，ai-infra 类**必须**额外覆盖以下硬规格；可放任意标题任意顺序，顺序交给叙事主线，但逐项齐全才算完成：

- **推理 / 请求链路**：模型加载与热切换、批处理策略（dynamic batching / continuous batching）、请求调度与抢占、流式 token 的输出路径、超时与错误传播（每条论断带 `文件:行号`；命中「强制图位清单」即给 `sequenceDiagram`/`graph`，如"一次推理请求从接入到流式返回"的时序，不写纯文字长段）。
- **算力 / 显存管理**：KV cache 管理与复用（prefix caching）、量化（INT8/FP8/GGUF 等）与显存占用的权衡、并发度与吞吐 / 延迟 / 成本的三角取舍。
- **向量存储与检索**：索引结构（HNSW / IVF / 暴力扫描）及其召回率-延迟-内存权衡、向量量化、元数据过滤、写入路径（增量 / 批量 / 删除与墓碑）、持久化与备份。
- **RAG 数据链路**：切分策略（chunk 大小 / 重叠 / 结构化切分）、embedding 选型、检索 → 重排 → 上下文组装 → 生成 的完整管线（跨模块时序给 `sequenceDiagram`）。
- **可观测与评测**：核心指标（吞吐 / 首 token 延迟 / 错误率 / 成本）、trace 与日志、eval 集与回归门禁（评测如何进 CI）。
- **多租户与限流**：租户隔离、配额 / 限流 / 熔断、计费或用量统计（有则覆盖）。

## 自由纵深块（软区）

- 「值得学什么」落点：吞吐与延迟的工程权衡（batching / caching / 量化）、向量索引的召回率-成本取舍、RAG 管线各环节的失败模式、评测如何防止"看起来好用"的回归。
- 常见坑：
  - 只写"用了什么模型/框架"，不讲吞吐、延迟、成本的三方权衡。
  - 把向量库写成字段/参数清单而非设计——应讲索引结构在具体召回率-延迟需求下的取舍。
  - 不写批处理与调度策略（这是 LLM 基础设施吞吐差异的核心）。
  - RAG 只写"支持哪些步骤"，不讲每一步的失败模式与补偿（检索不到 / 重排降级 / 上下文超限）。
- 深挖指引：比较不同推理服务的批处理与 KV cache 策略、不同向量库的索引与量化取舍、不同 RAG 框架的管线编排；深度不足标 `[WIP]`/`TODO`，不硬凑。
