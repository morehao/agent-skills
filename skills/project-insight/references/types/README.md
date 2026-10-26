# 类型提问清单（types）

> 由 [method.md](../method.md)「原型判定」按需加载。这里**不是产出规格**，而是**提问清单**：同一类系统天然会被问到同一批架构问题，带着问题读，比从头翻文件快得多。

## 怎么用

1. 按 [method.md](../method.md)「原型判定」选一个主类型（可叠加一个副类型）；
2. 读对应 `{类型}.md` 的问题清单，挑 8–10 个与该项目最相关的；
3. 答不上来的问题，要么继续读，要么写进"边界、风险与开放问题"——不要用泛泛而谈填空；
4. 清单只负责"问对问题"，**不规定章节、不要求逐项覆盖**。

## 注册表

| 类型 | 适用 | 文件 |
|---|---|---|
| 后端服务 / 网关 | Web/API、后台、IM、长连接、可部署服务 | [backend-service.md](backend-service.md) |
| 前端应用 / Web 客户端 | React/Vue/Svelte、SSR/SPA、管理台、桌面 Web | [frontend-app.md](frontend-app.md) |
| 框架 / 库 / SDK | 框架、基础库、SDK、CLI、编译器、开发工具 | [framework-library.md](framework-library.md) |
| 数据 / 存储 | 数据库、KV、搜索、缓存、存储引擎 | [data-storage.md](data-storage.md) |
| AI Agent / LLM 应用 | Agent、RAG、Copilot、多智能体 | [ai-agent.md](ai-agent.md) |
| AI 基础设施 | 推理服务、向量库、模型网关、LLMOps | [ai-infra.md](ai-infra.md) |
| 基础设施 / 运行时 | DevOps、云原生、调度、分布式运行时 | [infrastructure.md](infrastructure.md) |
| 通用回落 | 判不出类型，或类型特征不明显 | [_default.md](_default.md) |

## 主 + 副类型

- 判一个主类型，再用副类型补问题（如 Go 写的 agent 框架 = ai-agent + framework）；
- 冲突时以主类型的问题为主，副类型只补"它确实具备"的问题；
- 不为凑类型而硬套：判不出来就用 [_default.md](_default.md)，不阻塞分析。

## 新增类型

只在新类型反复出现、且问题清单与现有类型差异明显时才加：复制一个文件，写 10–15 个"这类系统必须回答的问题" + 典型决策 + 常见坑，并在上表注册。**不需要改 SKILL.md。**
