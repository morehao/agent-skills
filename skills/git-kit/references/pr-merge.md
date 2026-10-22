# pr-merge 分支：合并 PR/MR

合并后**删除原分支**（head 为稳定分支时**一律保留**），切回主干并拉取最新代码。自动识别 gh/glab。默认 squash 合并（用户可覆盖）。

## 稳定分支识别（决定是否删除 head）

删除参数是**服务端删除**（gh `--delete-branch` 删远端+本地；glab `--remove-source-branch` 删远端），下发后无法事后补救。因此必须**在前置检查阶段**先判定 head 是否为稳定分支，得出 `DELETE`（删除）或 `KEEP`（保留），再决定合并命令带不带删除参数。

判定规则：head 是否稳定分支，**唯一定义在 `references/stable-branch.md`**（主干/集成分支、目标仓库默认分支、发布分支、稳定/维护分支、版本线分支；命中任一即 `KEEP`）。其中「目标仓库默认分支」的探测：`git remote show <目标仓库>` 的 `HEAD branch`，或 `gh repo view <repo-id> --json defaultBranchRef --jq .defaultBranchRef.name`——`<repo-id>` 是 `[HOST/]OWNER/REPO` 形式，按 `references/repo-id.md` 解析（远端名直接喂 gh/glab 会被拒绝：`gh repo view origin` 会查成 `morehao/origin` 报「仓库不存在」）。

不属于稳定分支的短生命周期工作分支（`feature/*`、`fix/*`、`bugfix/*`、`hotfix/*`、`chore/*`、`docs/*`、`refactor/*`、`perf/*`、`style/*`、`test/*`、`experiment/*`、`poc/*`）照常删除。

**硬规则**：`KEEP` 时全程不传删除参数、不清理本地同名分支；**即使当前分支的 PR/MR 用户显式要求删除该 head 也不删**，改为说明「该 head 是稳定分支，按规则保留」，不静默、也不擅自执行。

## 确定编号（按优先级）

1. **用户显式提供**：`$1`（斜杠命令第一参数）或消息中的编号/URL（`#123`、`github.com/.../pull/123`、`gitlab.com/.../-/merge_requests/123`）→ 直接提取编号
2. **上下文探测**：无显式编号时，若当前分支不是主干/集成分支（见 `references/stable-branch.md` 第一类，如 `main`/`master`/`trunk`/`develop`/`dev`/`integration`），探测当前分支关联的开放 PR/MR：
   - gh：`gh pr view --json number,state,baseRefName --jq '{number,state,base:.baseRefName}'`（无参数即取当前分支 PR）；报错或 `state` 非 `OPEN` → 视为探测不到
   - glab：`glab mr view <当前分支> --output json | jq '{iid, state, target_branch}'` 或 `glab mr list --source-branch <当前分支>` 解析 IID；`state` 非 `opened` → 视为探测不到
3. **三选项确认**：无论编号来自显式提供还是上下文探测，合并前都把「编号 + 标题 + 目标分支 + head 分支及其去向（`将删除` / `稳定分支，保留`）」展示给用户，并提供三个选项（**用选项式提问呈现**，见 `references/ask-options.md`；不要打印现状等用户回一句「合并吧」）：
   - **是**：确认按当前编号合并，继续执行
   - **否**：取消本次合并，停在当前状态
   - **自定义 id**：用户另给一个编号/URL，替换当前编号 → 回到「前置检查」重新校验该 PR/MR（含重新判定 head 是否稳定分支），校验不过按失败处理
   - 探测到多个候选（有歧义）时，先让用户选定一个编号，再做上述三选项确认
4. **探测不到 → 必须向用户索要编号**，不猜测、不默认用 1 或当前分支猜

## 前置检查

1. **工作区干净**：`git status --porcelain` 须为空；有未提交改动 → 提示先提交/stash，不强行合并
2. **目标仓库与工具**（同 pr-create）：目标仓库优先 `upstream`，回退 `origin`；`git remote get-url <目标仓库>` 解析主机，`github.com` → `gh`，其他（gitlab.com/自建 GitLab/Gitea 等）→ `glab`
3. **校验 PR/MR 存在且未合并**：
   - gh：`gh pr view <id> --json state,baseRefName,headRefName --jq '{state,base:.baseRefName,head:.headRefName}'`，`state` 须为 `OPEN`
   - glab：`glab mr view <id> --output json | jq '{state, base:.target_branch, head:.source_branch}'`，`state` 须为 `opened`
   - 已 `MERGED`/`merged` 或 `CLOSED`/`closed`、查不到 → 停止并完整报告
4. 记录 base/head 分支名；**若当前分支 == head**，先 `git switch <base>` 再合并（避免删除当前所在分支失败）
5. **判定 head 去向**：按上方「稳定分支识别」（唯一定义在 `references/stable-branch.md`）得 `DELETE` 或 `KEEP`；结果写进三选项确认的展示项，并在最终报告中原样复述

## 执行流程

1. **合并**（**只有 `DELETE` 才带删除参数**）：
   - `DELETE` + gh：`gh pr merge <id> --squash --delete-branch`（`--delete-branch` 同时删本地+远端分支）
   - `KEEP` + gh：`gh pr merge <id> --squash`（**不带** `--delete-branch`）
   - `DELETE` + glab：`glab mr merge <id> --squash --remove-source-branch --yes`（`--remove-source-branch` 删远端源分支，`--yes` 跳过确认）
   - `KEEP` + glab：`glab mr merge <id> --squash --yes`（**不带** `--remove-source-branch`）
   - 用户要求 merge/rebase 合并方式时，把 `--squash` 换成 `--merge`/`--rebase`（glab 用 `--rebase`），删除参数按上面 `DELETE`/`KEEP` 规则保留或去掉
2. **切回主干**：`git switch <base>`；本地无该分支则 `git switch -c <base> --track origin/<base>`
3. **更新代码**：`git pull --ff-only origin <base>`（仓库习惯非 ff 时用 `git pull origin <base>`）
4. **清理本地残留分支（仅 `DELETE`）**：`DELETE` 且本地仍存在 `<head>` 时 `git branch -D <head>`（gh 已删本地；glab 只删远端，本地残留需手动清理）；`KEEP` 时本地 `<head>`（若存在）保留不动

## 验收标准

- 复核状态：gh `gh pr view <id> --json state --jq .state` 为 `MERGED`；glab `glab mr view <id> --output json | jq -r .state` 为 `merged`
- **分支去向与判定一致**（唯一判据是合并前算出的 `DELETE`/`KEEP`，不是"删成功没删成功"）：
  - `DELETE`：`git ls-remote --heads origin <head>` 无输出
  - `KEEP`：`git ls-remote --heads origin <head>` **仍能列出** `<head>` 才算通过，报告中注明「head 为稳定分支，按规则保留」
  - `DELETE` 但被平台拒绝删除（受保护分支、权限不足等）→ 如实报告「未删除」并给出原始报错，不假装成功（默认分支/主干/发布分支已在判定阶段归入 `KEEP`，不会走到这里）
- 当前分支为 `<base>`，`git status --porcelain` 为空，`git log --oneline -3` 已含合并后的最新提交
- 任一步失败（冲突未解决、CI/检查未过、权限不足等）→ 停在当前状态完整报告 gh/glab 原始报错，不伪造成功
