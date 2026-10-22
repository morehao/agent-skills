---
description: pr-merge 之后的发布段：在已合并的稳定分支上打 tag → 默认创建 GitHub/GitLab Release → 跟踪其他后效并逐项校验（只打标签用 /git/tag）
---

# 任务
本命令由 `git-kit` skill 的 **release 分支**实现。

用 `skill` 工具加载 `git-kit`，将本次请求视为 `release` 意图执行。

# 参数
$ARGUMENTS

> 可选目标 tag。版本源由**读仓库判定**（先按 `references/version-conventions.md` 认出主流约定：字面常量型 `--version` + `--version-file` 边界回查、派生/注入型只给 `--tag`、CI 硬校验版本加 `--require-version-match`；脚本不认识任何清单格式，无 `package.json` 仓同样适用），后效按仓库探测（`EFFECT_HINTS` 只给证据）；**是否发 npm、是否由 CI 建 Release、跑哪些流水，一律按仓库探测 + 用户选择，不硬编码**（Release 默认仍由本流程创建，这一点不变）。先跑 `scripts/release-preflight.sh` 只读预检，再按 `STATE`（READY/TAGGED/NEEDS_TARGET/BLOCKED）决定打 tag、只做跟踪、还是先定目标版本；**Release 是默认交付物**：平台是 GitHub/GitLab、CLI 已登录且 CI 不建时默认由本流程创建（body 复用 tag 注记正文），CI 已建则只校验，平台/CLI 不可用才降级为手动命令。打 tag 前把「tag + 目标 sha + 变更说明 + Release 计划 + 探测到的其他后效」一次性展示给用户确认。要不要把本次变更写进 `CHANGELOG.md` 也在这张计划卡里问：选了就开 `docs/changelog-<tag>` 分支走一次 `pr-create` → `pr-merge`，**合进稳定分支后**才打 tag（不选则完全不碰工作区）。
