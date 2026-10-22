---
description: pr-merge 之后的发布段：在已合并的稳定分支上打 tag → 默认创建 GitHub/GitLab Release → 跟踪其他后效并逐项校验（只打标签用 /git/tag）
---

# 任务
本命令由 `git-kit` skill 的 **release 分支**实现。

用 `skill` 工具加载 `git-kit`，将本次请求视为 `release` 意图执行。

# 参数
$ARGUMENTS

> 可选目标 tag。版本源与后效都按仓库探测：有 `package.json` 读其版本，无清单（Go/Rust）用 `--tag`；不发 npm、不建 Release、跑哪些流水都不写死。先跑 `scripts/release-preflight.sh` 只读预检，再按 `STATE`（READY/TAGGED/NEEDS_TAG/BLOCKED）决定打 tag、只做跟踪、还是索取版本；**Release 是默认交付物**：平台是 GitHub/GitLab、CLI 已登录且 CI 不建时默认由本流程创建（body 复用 tag 注记正文），CI 已建则只校验，平台/CLI 不可用才降级为手动命令。打 tag 前把「tag + 目标 sha + 变更说明 + Release 计划 + 探测到的其他后效」一次性展示给用户确认。要不要把本次变更写进 `CHANGELOG.md` 也在这张计划卡里问：选了就开 `docs/changelog-<tag>` 分支走一次 `pr-create` → `pr-merge`，**合进稳定分支后**才打 tag（不选则完全不碰工作区）。
