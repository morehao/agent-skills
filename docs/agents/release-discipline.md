# 发版纪律

**对任何仓库都一样：升版本不得直接提交稳定分支**（`main` 也不接受直推，发版不构成例外）。

路径固定：改 version → `commit-push` 建分支 → `pr-create` → `pr-merge` 合并 `main` → 再打 tag。规则见 `skills/git-kit/references/stable-branch.md` 与 `tag.md`「发版约束」；完整流程见 [git-kit 工作流](../git-kit.md) 的「发版」段。

## `pr-merge` 之后走 `/git/release`

只读预检 → 一次确认 → 打 tag → **默认创建 GitHub/GitLab Release** → 逐个跟踪其他后效（workflow / GitLab pipeline / 产物，**按仓库探测**）并出回执。

边界：**不改版本号、不开无关 PR**，不假定仓库发 npm，不假定版本写在 `package.json`。

| 预检 STATE | 动作 |
|---|---|
| `READY` | 打 tag + 建 Release |
| `TAGGED` | 补建/校验 Release 并跟踪 |
| `NEEDS_TARGET` | 先读仓库定目标版本，再带 `--version` / `--tag` 重跑 |
| `BLOCKED` | 按 `BLOCKERS` 停（含多版本线 `target-tag-ambiguous`） |

变更说明由 `scripts/changelog.sh` 从 Conventional Commits 汇总，tag 推送前必须确认（tag 不可改）。脚本细节与平台探测方式见 [技能内部规则](skill-internals.md#git-kit)。

**不再使用 changesets。**
