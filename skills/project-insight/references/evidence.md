# 证据、基线与核验

> 由 SKILL.md 六步主干的 step 0（输入/基线）与「证据规则」按需加载。默认模式**不需要**代码索引；本文件只在两种情况下用：用户要求可核验，或某条论断值得核验。

## 默认模式：零索引，但仍然不许编造

默认产物可以完全不出现 `path:line`，但以下东西必须真实：

- 模块名、目录名、文件名、协议名、接口名；
- 版本号、依赖名、部署形态；
- 任何数字（延迟、吞吐、连接数、表数量）。

写之前自检：这个模块我真的看到了吗？这个数字有出处吗？没有就标 `[待核]`，或删掉。**流畅不等于正确。**

零索引模式的轻量核对（可选）：

```bash
node scripts/check-doc.mjs --source-repo <source_repo> <文档.md>
```

它会检查文中形如 `pkg/x.go:42` 的路径是否存在、行号是否越界；**不验证锚点内容**，锚点仍由 `verify-references.mjs` 负责。

## 什么时候必须补证据

| 触发 | 为什么 |
|---|---|
| 反直觉 / 关键机制 | 读者最可能怀疑，也最容易被模型编造 |
| 与 README / 官方文档冲突 | 冲突本身是结论，必须有落点 |
| 数字 / 性能 / 容量 / 安全 | 不给出处就是假精确 |
| 用户明确要求核验 | 交付约定 |
| 增量更新 | 改动必须能追溯到 diff / release notes |

其余情况不补。**证据是附录，不是正文的装饰。**

## 证据附录格式

集中放在「附录 A」，每条一行：

```markdown
- [pkg/gateway/conn.go:120-168](https://github.com/org/repo/blob/v1.2.3/pkg/gateway/conn.go#L120-L168) — 握手阶段完成鉴权并把权限快照挂到连接上
  <!-- anchor: func (c *Conn) handshake(ctx context.Context) error { … return c.attachPolicy(policy) -->
```

- 路径用**仓库相对路径 + 行号区间**；链接可留空或给真实 URL（空链接在部分渲染器里是死链，优先给 URL）；
- 锚点 = 区间**首行 + 末行**原文，逐字复制，各 ≤1 行、行首截断 ≤80 字符；含 `--` 时用 `<!-- anchor-base64:... -->`；
- 锚点只服务程序定位，不进入正文阅读；
- 一条证据只支撑一个论断；不要把整段源码搬进附录。
- 密度：中小项目 5–10 条、大型项目 8–15 条，覆盖关键链路、主要决策与数字即可；**不逐句标注**。

## 校验命令

```bash
# 在 skill 的 scripts/ 目录下（或从仓库根用完整路径）
node scripts/verify-references.mjs <source_repo> <文档.md> [更多.md]
node scripts/verify-references.mjs --diff <source_repo> <文档.md>   # 增量预检
```

- `<source_repo>` = 本次基线的工作树，不是知识库目录，也不是随手的 HEAD；
- 输出五态：`OK` / `WEAK`（无锚点，仅路径与行号有效）/ `MISMATCH`（锚点定位到但行号有偏差，按真实行号覆盖）/ `UNVERIFIED`（保留原样并标 `[UNVERIFIED]`）/ `TRAVERSAL`（必须修）；
- 非 0 退出码 = 未通过；定位失败**不静默放过**，在文末汇总供人工复核；
- 没有锚点时脚本降级为弱校验（路径存在、行号未越界），仍然有用。

## 基线：一行就够，但要真

默认模式在开头记一行：

```markdown
> 基线：v1.2.3（a1b2c3d）；本地工作树 clean
```

- 用 `git describe --tags --always` 或 `git rev-parse --short HEAD` 取，不凭印象；
- 没有 git 元数据时：记绝对路径 + 文件数 + 抓取时间，并声明"无法按版本 diff"；
- 远端输入：先 `git ls-remote --tags --heads` 看有哪些 ref；不确定选哪个时跑 `node scripts/select-baseline.mjs <url|path>`（稳定 tag > 稳定分支 > 默认分支 > 兜底矩阵）；
- 克隆用 `git clone --branch <ref> --depth=1 <url>`；需要 diff 历史时改 `--filter=blob:none` 或不带 `--depth`。**禁止只给 `--depth=1` 而不指定 `--branch`**（丢 tags、锁死默认分支）；
- 本地仓库有未提交改动时**不静默 checkout**：用 `git worktree add <tmp> <ref>`，或在用户确认后 `git stash`；
- 证据模式对基线要求更严：写作、校验、引用必须是同一棵树；切过树就重跑校验。

## 增量更新时的证据

1. 找到旧文记录的基线（没有就问用户或按快照比对）；
2. 选新基线 → `git diff <旧>..<新>`，或读 release notes；
3. 只改受影响的段落；重构/重排不算更新理由；
4. 在文首更新基线行，需要时在文末简述"本次依据"；
5. 证据模式下再跑 `verify-references.mjs`（可先用 `--diff` 列出 STABLE/STALE/UNRESOLVED）。

## 常见错误

| 错误 | 纠正 |
|---|---|
| 凭记忆写行号 | 只写刚读到的；写不准就只写文件、不写行号 |
| 定位失败当通过 | 标 `[UNVERIFIED]` 并汇总，不静默 |
| 为凑"可信"给每条都加引用 | 证据进附录，按触发条件给 |
| 锚点贴整段代码 | 只取首末行，各 ≤1 行 |
| 引用路径越出仓库 | `realpath` 后必须在 `source_repo` 内 |
| 数字没有实测却写得很精确 | 改写为"口径 + 参数 + 假设"或标 `[待核]` |
| 在脏工作树上直接 checkout | 用 worktree 或经确认后 stash，收尾恢复 |
