---
name: git-kit
description: Git 工作流辅助工具包。当用户要求生成 commit message、提交/推送代码变更、基于中文描述创建/切换分支、面向目标仓库创建/更新 PR/MR、按编号合并 PR/MR 并回主干更新、给分支打版本标签并推送、在已合并的稳定分支上打 tag 并验证发布产物（pr-merge 之后的发布段）、将当前 git 仓库瘦身为浅克隆、或拉取并分类 GitHub star 仓库时使用该 skill（含"写个commit信息""提交一下""开个分支做XX""提个PR""把PR合并掉""打个tag""发版""发个版本""把仓库瘦身""分类我的star"等模糊表述）。
---

# Git Kit

Git 常见操作的统一入口。先按「意图路由」理解用户要做什么，落到一个分支执行，再按该分支的验收标准收尾。

本 skill 采用多文件结构。**主文件只含意图路由。** 命中某个分支后，按「按需加载」指引读取对应子文件执行其完整流程，避免一次性加载全部内容。

## 意图路由（决策树）

从用户消息解析意图，落入唯一分支。**不得跳过路由直接执行。**

| 分支 key | 命中信号（用户消息中出现） | 对应子文件 |
|---------|--------------------------|-----------|
| `commit-push` | 提交/推送当前变更（"提交""push""commit""推送"）；起点是稳定分支时自动建工作分支 | `references/commit-push.md`（含 `commit-format.md`） |
| `commit-message` | 只要 commit message 文案（"写个commit消息""生成commit信息"，或用户明确说"不用提交、只要文案"） | `references/commit-message.md`（含 `commit-format.md`） |
| `branch` | 分支 + 中文描述（"建个分支…""切到新分支…""开个分支做XX"） | `references/branch.md` |
| `pr-create` | 创建/更新 PR/MR（"提PR""创建合并请求""更新MR"） | `references/pr-create.md` |
| `pr-merge` | 合并 PR/MR 并回主干更新（"合并PR""合并MR""merge PR""把PR合掉""合入主干"）；命中后 head 为稳定分支时保留不删 | `references/pr-merge.md` |
| `tag` | 只给分支打版本标签并推送（"打tag""打个tag""打标签""release tag""给分支打标签"） | `references/tag.md` |
| `release` | `pr-merge` 之后的发布段（"发版""发个版本""发布新版本""上线这个版本""走一遍release流程"）；从已合并的稳定分支打 tag → 跟踪该仓库 tag 触发的后效并逐项校验（不假定是 npm） | `references/release.md` |
| `slim` | 仓库瘦身/浅克隆/减小体积（"瘦身""清理git历史""shallow clone"） | `references/slim.md` |
| `star-classify` | 拉取并分类自己 star 的 GitHub 仓库（"分类我的star""把我star的仓库整理成清单"） | `references/star-classify.md` |

**模糊请求直接按意图覆盖交叉处理：**
- 既说"提交"又说"推送" → `commit-push`（含生成 message）；只说"信息/文案"或明确"不提交" → `commit-message`。
- PR/MR 相关：**"合并请求"作 GitLab 术语（名词）** → `pr-create`；**"合并"作动词**（合并XX/合入XX/merge）→ `pr-merge`。
- **`tag` 与 `release` 的分界**：`tag` 只给分支打标签就结束（任意分支、任意时机）；`release` 是 `pr-merge` **之后**的发布段——版本号已在稳定分支上，它负责打 tag、跟踪该仓库 tag 触发的后效（发布流水 / npm / Release 等，按探测结果）并出回执。用户要「升版本/开 PR/合并」时不属于 `release`，走 `commit-push` + `pr-create` + `pr-merge`。
- 未命中任何信号 → 停止并询问用户具体要做的 Git 操作，不擅自动手。

**参数约定**（从用户消息提取，优先于任何上下文）：
- `branch`：提取中文描述（候选分支名唯一依据）。
- `pr-create`：可选目标分支名；没有则探测目标仓库默认分支。
- `pr-merge`：优先取用户显式提供的编号/URL；没有则探测当前分支关联的开放 PR/MR；无论来源，合并前都展示「编号 + 标题 + 目标分支 + head 分支及其去向（将删除 / 稳定分支保留）」并给用户**三选项（是 / 否 / 自定义 id）**确认；探测不到则要求用户提供编号，不猜测。head 为稳定分支时**一律保留不删**，判定与覆盖规则见 `references/stable-branch.md` 与 `references/pr-merge.md`。
- `release`：可选 tag（`v1.1.0`）；有可发布清单的仓库版本号取自稳定分支的 `package.json`（此时传 tag 必须与之一致），无清单的仓库（Go/Rust 等）必须用 `--tag` 指定。若 `STATE=BLOCKED`/`NEEDS_TAG` 按提示处理，不自行改版本号。
- `tag`：可选分支名或 tag 名（`$1`）；没有则探测最新 tag 与来源分支、候选分支、候选版本号并**先展示给用户选择确认**，不擅自决定打哪个分支/版本。目标是**发布**的仓库要额外对齐版本号（tag 版本必须等于发布包 `package.json` 版本，否则发布工作流拒绝发布）——不一致时先走 `commit-push` + `pr-create` 升版本，见 `references/tag.md`「发版约束」。
- `slim`：可选保留天数 `N`；没有则默认 `30 days ago`。

**两类消息的上下文约束：**
- 命中 `commit-message` 或 `branch` 分支时，只处理用户提供的话术/描述，**忽略任何代码、文件、git diff、git status 等上下文**。
- 命中 `commit-push`、`pr-create`、`pr-merge`、`tag`、`release`、`slim` 分支时，主动读取 git 状态是必要的（diff/remote/历史）。

## 按需加载

确认分支后，执行以下子文件的完整流程：

- `commit-push` 或 `commit-message`：先 `read references/commit-format.md`，再 `read references/<对应分支>.md`，最后按该文件执行。`commit-push` 另需先 `read references/stable-branch.md`（起点是稳定分支时自动建分支，发版升版本不例外）。
- `branch`：`read references/branch.md`。
- `pr-create`：先 `read references/repo-id.md`（gh/glab 的仓库参数规则），再 `read references/pr-create.md`。
- `pr-merge`：先 `read references/stable-branch.md`（判定 head 是否保留）与 `read references/repo-id.md`（gh/glab 的仓库参数规则），再 `read references/pr-merge.md`。
- `tag`：先 `read references/stable-branch.md`（候选分支的稳定分支偏好），再 `read references/tag.md`（含「发版约束」：版本号对齐与升版本顺序），并用 `scripts/changelog.sh --link-to <tag>` 生成注记正文（推送前让用户确认）。
- `release`：先 `read references/ask-options.md`（**决策点一律用选项式提问**，不打印现状等人用自然语言回答），再 `read references/release.md`（发布段流程与计划卡），再 `read references/tag.md`「发版约束」（版本对齐与注记 tag），运行 `scripts/release-preflight.sh` 做只读预检（返回 `STATE` 决定是打 tag、只验证、还是索取版本；`BLOCKERS` 非空即停，`WARN` 只如实报告），用 `scripts/changelog.sh --link-to <tag>` 生成**并落盘**变更说明（进 tag 注记，推送前过目；之后不再重算）。若用户选择把变更写进 `CHANGELOG.md`：`changelog.sh --from <上个 tag> --to <BASE_REF> --version <tag> --link-to <tag> --write CHANGELOG.md` → 开 `docs/changelog-<tag>` 分支 → `pr-create` → `pr-merge` → 重新预检，再打 tag（正文仍用先前冻结那份）。
- `slim`：`read references/slim.md`，按其中指引运行 `scripts/git-slim.sh`（脚本为单一真源，与 `/git/slim` 命令共用）。
- `star-classify`：`read references/star-classify.md`，按其中指引运行 `scripts/git-star.sh`。
