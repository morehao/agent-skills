# opencode 指令集

本目录存放 opencode 自定义指令，安装方式见 [`docs/installation.md`](../docs/installation.md)。为什么用命令文件而不是插件、以及 skill 的 `opencode/slash` 何时能替代命令，见[「为什么是命令文件而不是插件」](../docs/installation.md#为什么是命令文件而不是插件)。

## 文件结构规范（对齐 opencode 源码）

每条指令是一个 Markdown 文件，opencode 扫描配置目录下 `command/`、`commands/`（本项目把 `git/` 与 `handoff.md` 软链到 `~/.config/opencode/command/`），文件名（含子目录）即命令名，如 `git/branch.md` → `/git/branch`。

- frontmatter 仅允许官方 `ConfigCommandV1.Info` 字段：`description`、`agent`、`model`、`variant`、`subtask`（多余键会被忽略；`scripts/check-opencode-commands.mjs` 会直接判失败，别加）。
- 正文是模板：`$ARGUMENTS` 整段替换为原始参数（官方 `issues.md`/`learn.md` 惯例为**独立成行裸写**，勿用反引号包裹——参数为空时会残留孤立反引号）；`$1`…`$N` 按位置替换（本项目未用）。模板不含占位符时，非空参数会追加到正文末尾。
- 本项目命令均为**委托壳**：固定"# 任务"（声明由哪个 skill 的哪个分支实现 + 用 `skill` 工具加载该 skill）+ "# 参数"（`$ARGUMENTS` + 参数语义说明）两段结构。

## Git 指令

| 路径 | 功能 |
|------|------|
| `git/branch` | 基于中文描述生成候选分支名，选择后从基准分支创建并切换 |
| `git/message` | 将中文描述转换为 Conventional Commits 格式的 commit message（纯生成，不提交） |
| `git/pr-create` | 基于代码差异向目标仓库创建或更新 PR/MR（自动识别 gh/glab） |
| `git/pr-merge` | 按编号合并 PR/MR，删除原分支（head 为稳定分支时保留），切回主干并更新代码（自动识别 gh/glab） |
| `git/release` | pr-merge 之后的发布段：打 tag → 默认创建 GitHub/GitLab Release → 按仓库探测跟踪后效并逐项校验；tag 注记与 Release body 共用同一份变更说明（中文摘要 + 折叠原文，推送前确认并冻结） |
| `git/tag` | 查看最新 tag 与来源分支，选择分支与版本号，构建注记 tag（中文摘要 + 折叠原文）并推送 |
| `git/commit-push` | 基于代码变更自动生成 commit message 并执行提交推送 |
| `git/slim` | 将当前 git 仓库瘦身为浅克隆，默认保留 30 天历史 |
| `git/star-classify` | 拉取并分类自己的 GitHub star 仓库，输出中文分组清单 |

### 与 git-kit skill 的联动

这些 Git 指令均为**委托壳**（`git/*.md` 软链为 `/git/<子命令>`）：加载 `git-kit` skill 并落到对应分支执行，逻辑单一真源在 `skills/git-kit/references/` 与 `skills/git-kit/scripts/`，避免重复漂移。

| 指令 | 委托的 skill 分支 |
|------|-------------------|
| `git/branch` | `git-kit` branch |
| `git/message` | `git-kit` commit-message |
| `git/pr-create` | `git-kit` pr-create |
| `git/pr-merge` | `git-kit` pr-merge |
| `git/release` | `git-kit` release |
| `git/tag` | `git-kit` tag |
| `git/commit-push` | `git-kit` commit-push |
| `git/slim` | `git-kit` slim |
| `git/star-classify` | `git-kit` star-classify |

若在对话中直接描述意图（如"写个 commit 信息""分支做 XX"），opencode 也可不经斜杠指令、直接触发 `git-kit` skill 完成同样的操作；命令与 skill 是同一实现的两条入口。

### Git 指令用法

在 opencode 对话中输入斜杠命令调用：

- `/git/branch <中文描述>` → 生成候选分支名，选择后创建并切换
- `/git/message <中文描述>` → 生成 commit message
- `/git/pr-create [目标分支]` → 基于差异创建/更新 PR/MR（默认探测 main/master）
- `/git/pr-merge [编号]` → 合并 PR/MR（无编号时探测当前分支关联的 PR/MR 并确认），删除原分支（head 为稳定分支时保留），切回主干并更新（默认 squash）
- `/git/tag [tag名或分支名]` → 探测最新 tag 与来源分支，选择分支与版本号后打注记 tag（变更说明 = 中文摘要 + 折叠原文）并推送
- `/git/release` → pr-merge 之后的发布段：只读预检 → 一次确认 → 打 tag → **默认创建 GitHub/GitLab Release** → 按仓库探测跟踪后效（流水 / 产物）并出校验回执；变更说明由 tag 注记与 Release body 共用（推送前冻结，只打标签用 `/git/tag`）
- `/git/commit-push` → 分析当前变更自动提交并推送
- `/git/slim [天数]` → 瘦身当前仓库（默认保留 30 天历史）
- `/git/star-classify` → 拉取并分类自己的 GitHub star 仓库

## Handoff 指令

| 路径 | 功能 |
|------|------|
| `handoff` | 把当前会话的任务状态压缩成一段可粘贴的续跑提示（只打印，不落盘） |

`/handoff` 委托 `handoff` skill 的 `print` 分支，逻辑单一真源在 `skills/handoff/`。它只打印一个 Markdown 代码块：复制到新会话即可续跑，有进展后重跑一次刷新交接。命令不写文件、不改仓库，也没有 `/handoff/resume`——恢复靠在新会话粘贴文本。

## Cleanup 指令

| 路径 | 功能 |
|------|------|
| `cleanup` | 磁盘空间回收与本地数据瘦身（macOS 为主）：先只读测量 → 用户勾选清理项 → 只清所选；用户数据只报告不代删 |

`/cleanup` 委托 `disk-cleanup` skill 的 `cleanup` 分支，逻辑单一真源在 `skills/disk-cleanup/`（`SKILL.md` 流程 + `references/cleanup.md` 清理对象 + `scripts/` 两个执行脚本）。

磁盘清理是一个动作而不是固定清单，所以命令**默认只读**，而且**最终删哪些由用户勾选**：

- `/cleanup`（无参数）→ **先给编号选项**（只看占用 / 选勾清理 / 本地数据库 / 取消），不执行任何脚本，也不先「顺手查一下」；
- `/cleanup 只看占用` → 只读统计并分类报告，每项带编码与实测大小；
- `/cleanup 选勾清理`（口语「执行」同义）→ 先出清单，**用户勾选后**才 `--clean --only <勾选的编码>`；`/tmp` 与 Time Machine 快照这两项交给用户自己的终端；
- `/cleanup 预览` → 对已勾选的编码跑 `--clean --dry-run --only <编码>`，只打印不删除；
- `/cleanup 本地数据库` → 数据库瘦身：先备份、先闭库再执行。

没勾的项一律不动；用户只回一句「清理吧」时，也要先让他勾选，不许自动全选。

## 校验

改完指令文件或本 README 后，在仓库根目录运行：

```bash
node scripts/check-opencode-commands.mjs
```

它机械校验：frontmatter 只含官方字段且 `description` 非空、正文声明 `**<branch> 分支**` 且 `skills/<skill>/references/<branch>.md` 存在、`$ARGUMENTS` 独立成行（无参数命令声明「本命令无参数」）、本 README 与根 README 的表格和文件一一对应。加 `--dsh ../dsh-commands` 可顺带比对另一仓的 `COMMANDS` 表（branch 不一致判失败，描述差异只提示）。
