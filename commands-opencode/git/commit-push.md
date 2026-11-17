---
description: 基于代码变更生成 commit message 并提交、推送到远端；处于稳定分支时自动新建工作分支
---

# 任务
本命令由 `git-kit` skill 的 **commit-push 分支**实现。

用 `skill` 工具加载 `git-kit`，将本次请求视为 `commit-push` 意图执行。

# 参数
本命令无参数。

> 命令后附带的文字不是入参：只在与本次提交内容直接相关时当作补充说明，否则忽略，仍按 `commit-push` 分支的默认流程执行。
