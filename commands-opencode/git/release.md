---
description: pr-merge 之后的发布段：在已合并的稳定分支上打 tag → 跟踪该仓库 tag 触发的后效并逐项校验（只打标签用 /git/tag）
---

# 任务
本命令由 `git-kit` skill 的 **release 分支**实现。

用 `skill` 工具加载 `git-kit`，将本次请求视为 `release` 意图执行。

# 参数
$ARGUMENTS

> 可选目标 tag。版本源与后效都按仓库探测：有 `package.json` 读其版本，无清单（Go/Rust）用 `--tag`；发 npm、建 Release、跑哪些流水不写死。先跑 `scripts/release-preflight.sh` 只读预检，再按 `STATE`（READY/TAGGED/NEEDS_TAG/BLOCKED）决定打 tag、只做跟踪、还是索取版本；打 tag 前把「tag + 目标 sha + 变更说明 + 探测到的后效」一次性展示给用户确认。要不要把本次变更写进 `CHANGELOG.md` 也在这张计划卡里问：选了就开 `docs/changelog-<tag>` 分支走一次 `pr-create` → `pr-merge`，**合进稳定分支后**才打 tag（不选则完全不碰工作区）。
