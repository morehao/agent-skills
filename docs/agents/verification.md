# 校验与运行

所有校验都用 node 直跑（不是打包器）。依赖与退出码一并记在这里，避免现拼命令。

## 命令契约校验

```bash
node scripts/check-opencode-commands.mjs
node scripts/check-opencode-commands.mjs --dsh ../dsh-commands   # 顺带比对另一仓
```

退出码：`0` 通过（可带提示）/ `1` 有错误 / `2` 用法错误。

校验项：

- frontmatter 只允许官方字段，`description` 非空、单行；
- 正文 `**<branch> 分支**` 对应 `skills/<skill>/references/<branch>.md` 存在（单文件技能只查 `SKILL.md`）；
- `$ARGUMENTS` 独立成行；无参数命令必须显式写「本命令无参数」；
- 两份 README 的表格与命令文件**双向**一一对应；
- 「指令 → skill 分支」联动表的 branch/skill 与正文声明一致；
- `--dsh`：branch/skill 不一致判失败，description 差异只提示；并检查 dsh 有、opencode 没有的委托命令。

新增/修改命令的完整步骤见 [安装与维护](../installation.md) 的「新增或修改命令」。

## disk-cleanup 编码表校验

```bash
node scripts/check-disk-cleanup-codes.mjs
```

退出码：`0` 一致 / `1` 有漂移 / `2` 用法或环境错误（脚本跑不起来、JSON 解析失败）。

单一事实源是 `skills/disk-cleanup/scripts/mac_cleanup.sh --list --json`（脚本里的 `KNOWN_IDS` 与元数据），
校验它与三处文档一一对应：

- `skills/disk-cleanup/references/cleanup.md` 的「清理项编码」表（漏写/多写都判失败）；
- `skills/disk-cleanup/SKILL.md` 勾选表第二列（`--only` 编码）；
- `docs/agents/skill-internals.md` 的「清理项编码（…）」清单。

改了编码（新增/删除/改名）必须四处同步，否则用户会看到脚本不认的编码（`--only` 直接 exit 1）或漏掉可清理项。

### CI

[`.github/workflows/commands.yml`](../../.github/workflows/commands.yml) 在 push 到 `main` 与所有 PR 上跑两个 job：

| job | 内容 | 失败含义 |
|---|---|---|
| `contract` | `node scripts/check-opencode-commands.mjs` + `node scripts/check-disk-cleanup-codes.mjs` + 两个安装脚本 `bash -n` | 命令契约/README/`$ARGUMENTS` 不合规、disk-cleanup 编码与文档漂移，或脚本有语法错误 |
| `dsh-parity` | checkout `morehao/dsh-commands` 到 `.ci/dsh-commands`，跑 `--dsh` | 两仓的 branch/skill 漂移（description 差异只提示，不失败） |

本地等价：`node scripts/check-opencode-commands.mjs --dsh ../dsh-commands`。CI 依赖另一仓的 `main`，dsh-commands 改了 branch key 这里会立刻红——这是预期信号，不是 flaky。

## 环境类检查（本地，不进 CI）

本源内容与各 agent 软链都依赖本机 `$HOME`，CI 跑不了。改动接入相关代码后本地自查：

```bash
./scripts/skills-install.sh --check       # 本源 ~/.agents/skills 是否与本仓一致（缺失/落后）
./scripts/skills-fanout.sh --check        # 各 agent 目录的软链是否都指向本源
./scripts/opencode-install.sh --check     # 上面两项的 opencode 侧 + 命令软链
```

三者都是只读，问题数 >0 退出 1。`skills-install.sh --check` 报「本源与本仓不一致」通常意味着「本仓改了但还没 push/发布」。要试“写”的动作，必须用临时目录（见 installation.md「改脚本注意」），别对着真实 `~/.agents` 跑。

## project-insight 引擎

默认模式不跑引用重定位：`check-doc.mjs` 做确定性体检（链接 / 资产 / SVG / 证据路径 / 孤立图），`check-mermaid.mjs` 与 SVG 审计按图运行；**证据模式**才跑 `verify-references.mjs`。

```bash
# 在仓库根跑（也可 cd skills/project-insight/scripts 后用 node <script>.mjs）
node skills/project-insight/scripts/check-doc.mjs [--source-repo <源码根>] [--strict] <文档.md>...
node skills/project-insight/scripts/check-mermaid.mjs <文档.md>...
node skills/project-insight/scripts/audit-svg-topology.mjs <图.svg> [--strict]
node skills/project-insight/scripts/render-svg-preview.mjs <图.svg>
node skills/project-insight/scripts/verify-references.mjs <source_repo> <文档.md>...
node skills/project-insight/scripts/select-baseline.mjs <本地路径|远端URL> [--ref <ref>] [--package <名>] [--json]
```

- `check-doc.mjs`：退出码 `0` 通过（可带提示）/ `1` 有错误（`--strict` 下提示也计失败）/ `2` 用法或读取错误；`--source-repo` 用来核对证据附录里的 `[path:start-end]` 与正文 `path:line` 是否存在、行号是否越界。
- `check-mermaid.mjs`：真解析所有 Mermaid 块；`[MERMAID-ERROR]` 必须修到全 `OK`。
- `audit-svg-topology.mjs` / `render-svg-preview.mjs`：SVG 边拓扑审计与目视预览；新画或重排必跑。
- `verify-references.mjs`：**证据模式**用；首参是源码仓库根（= 声明的基线工作树），不是知识库目录；五态输出，`UNVERIFIED`/`TRAVERSAL` 不静默放过。
- `select-baseline.mjs`：默认模式只在文首记一行 `git describe`；远端输入或证据模式才需要程序化选基线；退出码 `2` = 需用户确认/选择。
- 旧叙述型门禁 `scan-narrative.mjs` / `check-narrative-all.mjs` 已退役（编号、零索引不是新默认产物要求）。

本地回归（临时目录，不需外部服务）：

```bash
bash skills/project-insight/scripts/tests/baseline-smoke.sh     # 基线选择 15 条断言
bash skills/project-insight/scripts/tests/doc-check-smoke.sh    # 文档体检 12 条断言
```

`skills/project-insight/scripts/` 依赖 `mermaid`、`jsdom`（`select-baseline.mjs` 只用 node 内置模块 + `git`，无 npm 依赖）。`node_modules` 被 gitignore，**首次需在其中 `npm install`**；若本机用 `cp -r` 复制注册而非软链，复制后要在副本的 `scripts/` 重装。

## project-wiki 门禁

```bash
node skills/project-wiki/scripts/check-all.mjs <输出目录|md...> \
  [--source-repo <源码根>] [--expect-baseline <ref>] [--kb-repo <知识库根>] \
  [--allow-in-repo] [--strict] [--preview]

node skills/project-wiki/scripts/plan-update.mjs <输出目录> --source-repo <源码根> \
  --from <旧ref> --to <新ref> [--emit <快照.json>]
# 或：... --against <快照.json>

bash skills/project-wiki/scripts/tests/gates-regression.sh
```

- `check-all.mjs` 是**唯一门禁入口**：编排自研门禁 + Mermaid 引擎 + SVG 边拓扑审计。退出码 `0` 通过（仅有 warn/note）/ `1` 存在 error / `2` 用法或依赖缺失。**三档严重度**：`--strict` 只提升 warn，note 永不阻断；`--source-repo` 必须指向自述基线的工作树，漏传或 HEAD 不符时如实降级说明而**不假装通过**。
- `plan-update.mjs` 是**更新预检，不是门禁**：出「受影响页 + 未覆盖变更面」两张清单、给行号漂移的真实新行号、前后比对结构指纹；退出码 `0` = 清单已产出，不表达通过与否。
- `gates-regression.sh`：**45 条断言**，逐条验证「故意违规必须被拦住」与「note 不阻断、`--strict` 下也不阻断」。

## 安装脚本自测

用临时配置根，别拿真实配置试：

```bash
OPENCODE_CONFIG="$(mktemp -d)" ./scripts/opencode-install.sh
OPENCODE_CONFIG="$(mktemp -d)" ./scripts/opencode-install.sh --check
```
