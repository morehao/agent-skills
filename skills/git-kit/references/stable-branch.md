# 稳定分支（git-kit 唯一定义，commit-push / pr-merge / tag / release 共用）

**git-kit 内所有「稳定分支」判断只用这一份定义**，各分支只决定「命中后怎么办」，不再各自复述判定表。

对分支名**全名**匹配（大小写不敏感），命中任一即稳定分支。**没有"名字含 `release` 就算"这类模糊匹配**——`feature/release-notes`、`fix/release-lock` 都**不是**稳定分支（`release-*` 只匹配以 `release-` 开头的整名）：

| 类别 | 命中形式 |
|------|---------|
| 主干/集成分支 | `main`、`master`、`trunk`、`develop`、`development`、`dev`、`integration` |
| 目标仓库默认分支 | `git remote show <目标仓库>` 的 `HEAD branch`（或 `gh repo view <repo-id> --json defaultBranchRef --jq .defaultBranchRef.name`）——名字不在上列也算 |
| 发布分支 | `release`、`release/*`、`release-*`、`releases/*` |
| 稳定/维护分支 | `stable`、`stable/*`、`stable-*`、`maintenance/*`、`maint/*`、`support/*`、`lts/*` |
| 版本线分支 | `v?<主版本>.x` 整名匹配，如 `1.x`、`2.0.x`、`v3.x` |

`<repo-id>` 是 `[HOST/]OWNER/REPO` 形式的仓库标识，按 `references/repo-id.md` 解析（远端名不能直接喂 gh/glab）。

**不是**稳定分支的短生命周期工作分支：`feature/*`、`fix/*`、`bugfix/*`、`hotfix/*`、`chore/*`、`docs/*`、`refactor/*`、`perf/*`、`style/*`、`test/*`、`experiment/*`、`poc/*`。

## 命中后各分支的动作（唯一差异点）

| 分支 | 用途 | 命中稳定分支时 |
|------|------|---------------|
| `commit-push` | 提交推送 | **不直接提交**，先自动建工作分支再提交（`references/commit-push.md`） |
| `pr-merge` | 合并 PR/MR | head 为稳定分支 → `KEEP`，**一律保留不删**（`references/pr-merge.md`） |
| `tag` | 打版本 tag | **优先**作为 tag 来源分支（偏好，非禁止）（`references/tag.md`） |
| `release` | 发布段（打 tag + 跟踪后效） | 以**远端**稳定分支为发布基准：tag 指向它、版本号读它（`references/release.md`） |

**无例外**：发版升版本（改仓库里那个版本源文件的 `version`；哪个文件是版本源由读仓库决定，仓库不声明版本时以 tag 为版本源）**同样不直接提交稳定分支**——走 `commit-push` 建分支 → PR → 合并 `main`，合并后再打 tag（顺序与守卫见 `references/tag.md`「发版约束」）。

## 边界

- 本定义**只服务 git-kit 的写操作**（提交/合并/打 tag）。
- `project-insight` 里的「稳定分支」（选解读基线：稳定 tag > 稳定分支 > 默认分支）是**另一个概念**，用于挑选只读快照，判定规则在 `skills/project-insight/references/version-baseline.md`，**不要**与本文互相替换。
