# 写作与仓库约定

## 写作

- 中文为主，代码/术语保留英文。
- 子文档**主题语义命名**（`architecture.md`、`data-model.md`），**不用数字序号前缀**。
- 标题用 Markdown 天然层级语义式命名，不加 `## 1. X` 这类数字前缀。
- `docs/` 是给人看的解释性文档，`skills/*/SKILL.md` 是给模型看的操作指令，两者分工不重叠。

## 图

- 图放 `docs/assets/`；分层结构用 SVG，流程/时序/状态用 Mermaid。
- 新画或重排的 SVG 必须跑 `skills/tech-design/scripts/audit-svg-topology.mjs`；Mermaid 必须跑 `skills/tech-design/scripts/check-mermaid.mjs` 且零 warn。

## Git

- git-kit 用 Conventional Commits；分支前缀映射见 `skills/git-kit/references/branch.md`（feature/fix/hotfix/refactor/release/experiment/poc 等）。
- 发版路径见 [发版纪律](release-discipline.md)。

## 过程性文档与忽略项

- 过程性文档（需求设计 / 开发计划 / 排查记录）默认落工作区 `.dsh/docs/{specs,plans,notes}/`，文件名 `<YYYY-MM-DD>-<topic>-{design,plan,notes}.md`。
- `.gitignore` 忽略了 `.opencode/`、`.superpowers/`、`.dsh/`、`docs/superpowers/`（本地草稿/会话运行态，不入库），另忽略 `node_modules/`。
- **注意 `.dsh/` 整体被忽略**：按全局约定落在 `.dsh/docs/` 的过程性文档因此只留本地、不随仓库分发——需要入库的方案/设计文档请直接放仓库的 `docs/` 或对应技能目录。

## 改脚本（bash 3.2）

macOS 自带 bash 3.2，脚本必须兼容：不用 `mapfile` / 关联数组 / `${var,,}`，也不要在 `set -u` 下展开空数组。**变量后紧跟中文等非 ASCII 字符必须写 `${var}`**，否则 bash 3.2 会把该字符并入变量名并报 `unbound variable`。
