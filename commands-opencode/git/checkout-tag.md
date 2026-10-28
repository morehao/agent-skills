---
description: 切换到当前仓库的最新 tag（按版本号取最高，非 semver 退化为最近创建）；只切不改，默认 detached HEAD，要基于该 tag 开发才另建分支
---

# 任务
本命令由 `git-kit` skill 的 **checkout-tag 分支**实现。

用 `skill` 工具加载 `git-kit`，将本次请求视为 `checkout-tag` 意图执行。

# 参数
$ARGUMENTS

> 可选目标 tag 名：给了就切到该 tag（本地/远端都不存在则停并列出候选，不静默改用最新）；为空则探测最新 tag（按版本号取最高，非 semver 退化为最近创建）后切换。默认切到 detached HEAD，不新建分支、不提交、不推送。
