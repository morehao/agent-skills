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

## tech-design 文档门禁回归

```bash
node skills/tech-design/scripts/tests/check-design-doc-test.mjs
```

退出码：`0` 全部断言通过 / `1` 有断言失败。

这个测试守的是门禁脚本本身：合规文档必须通过、**故意违规必须被拦住**（缺状态块、残留 `TBD`、`N/A` 空壳章节、备选无「不做」、缺追溯表、DDL 与正文两说、**按章节缺图与档位最小图集**）、`--strict` 只提升 warn、`note` 在任何模式下都不阻断、`--tier light` 只免追溯表（图照查）。夹具在 `skills/tech-design/scripts/tests/fixtures/`，其中 `good-full.md`（含 Mermaid 时序/ER 与同目录 `architecture.svg`）同时是「高质量完整档」的可参照样例。

改了 `check-design-doc.mjs` 的规则或严重度，必须同步改夹具与断言——夹具不跟着改，等于把门禁调松而不自知。

规则与严重度的**唯一清单**用 `node skills/tech-design/scripts/check-design-doc.mjs --list-rules` 查；文档里不抄枚举，回归测试会断言清单与源码里 `report()` 发出的码一一对应。

`skills/tech-design/scripts/tests/behavior/baseline.md` 是**人工行为回归**（要跑模型，不进 CI）：技能新增或大改后按其中 B1–B5 场景复跑，把新出现的偷懒话术追加到 `references/anti-rationalization.md`。

## disk-cleanup：编码契约 / 删除安全 / 回归测试

三条命令，都能在 Linux 与 macOS 上跑（CI 是 ubuntu-latest）：

```bash
node scripts/check-disk-cleanup-codes.mjs     # 编码契约与文档一致
node scripts/check-disk-cleanup-safety.mjs    # 删除出口与 bash 3.2 约束
bash skills/disk-cleanup/scripts/tests/run.sh # 纯 bash 断言（假 HOME，不碰真实数据）
```

退出码统一：`0` 通过 / `1` 有漂移或断言失败 / `2` 用法或环境错误（文件读不到、脚本跑不起来、JSON 解析失败）。

**单一事实源**：`skills/disk-cleanup/scripts/data/codes.tsv`（编码 id/label/desc/sudo，29 个）与
`scripts/data/protect.tsv`（保护清单 pattern/scope/reason）。`--list --json` 由 TSV 派生，
文档与脚本都不许再硬编码编码列表——v1 的漂移（文档写「16 个」实际 22 个）就是因为数量没被校验。

`check-disk-cleanup-codes.mjs` 校验五类结构一致：
`--list --json` 与 TSV 逐项相同（id/顺序/label/desc/sudo）、`references/cleanup.md` 索引表与 TSV 一一对应**且数量相同**、
`SKILL.md` 里每个 `--flag` 在 `usage()` 里真实存在（反向检查，防文档教 agent 敲不存在的参数）、
`--list` 文本的 `[需 sudo]` 与 TSV 的 sudo 列一致、references 的 `--only` 示例只用声明过的编码。

`check-disk-cleanup-safety.mjs` 校验五条硬约束：
`rm`/`find -delete` 只允许出现在 `lib/safety.sh` 的 `dc_funnel_rm`（单条）与 `dc_batch_flush`（批量）内（报文件:行）、
禁 bash 4 语法（`mapfile`/`readarray`/`declare -A`/`${v,,}`/`${v^^}`/`<<<`/`&>>`）、
`mac_cleanup.sh` 必须调用 `dc_env_assert`、`scripts/**/*.sh` 全量过 `/bin/bash -n`、
以及「变量后紧跟中文」直接失败（bash 3.2 会把它当成变量名的一部分 → `unbound variable`）、
禁止把删除委托给外部清理工具（`mo`/`mole` 的 `clean`/`uninstall`/`purge`/`optimize`——删除只能出自本仓库的漏斗，理由见[决策记录](decisions.md)）。

`tests/run.sh` 覆盖内核不变量：路径断言拒绝清单、`HOME` 为空/相对时 `exit 2`、保护清单
（hard 拦 / soft 拦 / `!pattern` 解 soft / hard 不可解 / 用户追加生效）、`dc_under` 的 `/Users/x` vs `/Users/xy`、
`run_timeout` 返回 124 与耗时上界、`json_esc`、参数契约（`--clean` 缺 `--only/--skip/--all`、单独 `--dry-run`、未知编码、
未知参数 → `exit 2`）、`codes.tsv` ↔ `--list --json`、reason/status 枚举闭合、dry-run 与 clean 的 `deletable_kb` 一致、
**候选清单契约**（`--json` 的 `manifest` 与 TSV 行数一致、7 列、编码/判定/类型枚举闭合、plan 模式零删除、`--manifest` 落点与拒绝条件、查询模式为 `null`）。
所有删除类用例只在 `HOME=$(mktemp -d)` 的假树上跑，退出即清理。

**CI**（`.github/workflows/commands.yml` 的 `contract` job）跑：命令契约 + 上面三条 + tech-design 文档门禁 + `scripts/**`、`skills/**` 全量 `bash -n`。

改了编码 / 阈值 / 参数 / 保护清单，要同步改：`data/codes.tsv` 或 `data/protect.tsv` + `references/*.md`（`cleanup.md` 索引表必改）+ 必要时 `SKILL.md` 的流程（不要在 SKILL 里抄编码表）。

## disk-cleanup 差分 oracle（研发期，可选，不进 CI）

```bash
bash scripts/dev/tests/mole-oracle-test.sh                  # 夹具回归（不需要装 Mole）
scripts/dev/mole-oracle.sh --collect-ours --limit 60         # 现跑我们的预览再比
scripts/dev/mole-oracle.sh --ours plan.tsv --out report.md   # 用已有清单
```

前置：先在你自己的终端跑一次 `mo clean --dry-run`——Mole 必须写 `~/.config/mole/clean-list.txt`，沙箱里会失败。

产出三类：**缺口**（Mole 会清、我们完全不碰）、**冲突**（我们标 `protected`、Mole 会清，安全相关）、**多出**（我们计划删、Mole 不碰）。三类都是**待审线索**，不是结论：Mole 认的不等于该删，它不认的也可能是它自己在保护。

工具只读、不调用 `mo`、不进技能包；为什么只当研发期 oracle 而不是运行时依赖，见[决策记录](decisions.md)。

## 环境类检查（本地，不进 CI）

本源内容与各 agent 软链都依赖本机 `$HOME`，CI 跑不了。改动接入相关代码后本地自查：

```bash
./scripts/skills-fanout.sh --check        # 各 agent 目录的软链是否都指向本源
./scripts/opencode-install.sh --check     # 上面一项的 opencode 侧 + 命令软链
```

两者都是只读，问题数 >0 退出 1。本源与本仓是否一致需要自行比对（`skills` CLI 不提供 `--check`）：先 `git push` 再用 `skills` CLI 发布一次即可保持同步。要试“写”的动作，必须用临时目录（见 installation.md「改脚本注意」），别对着真实 `~/.agents` 跑。

## project-insight 引擎

引用校验只在文档真的带引用时才有条目：`verify-references.mjs` 对含引用的 md 逐条重定位（首末行双锚点）；**零引用文档直接通过**（打印「无引用（允许）」）。`--stats` 只报密度、不阻断。Mermaid / SVG 校验按图运行。

```bash
# 在仓库根跑（也可 cd skills/project-insight/scripts 后用 node <script>.mjs）
node skills/project-insight/scripts/verify-references.mjs <source_repo> <文档.md>...       # 含引用才跑；零引用自动通过
node skills/project-insight/scripts/verify-references.mjs --diff <source_repo> <文档.md>...  # 增量预检
node skills/project-insight/scripts/verify-references.mjs --stats <文档.md>...              # 密度自查（退出码恒 0）
node skills/project-insight/scripts/check-mermaid.mjs <文档.md>...
node skills/project-insight/scripts/audit-svg-topology.mjs <图.svg> [--strict]
node skills/project-insight/scripts/render-svg-preview.mjs <图.svg>
node skills/project-insight/scripts/scan-narrative.mjs [--repo-root <解读目录>] <architecture-design.md>...
node skills/project-insight/scripts/check-narrative-all.mjs <architecture-design.md>...
node skills/project-insight/scripts/select-baseline.mjs <本地路径|远端URL> [--ref <ref>] [--package <名>] [--json]
```

- `verify-references.mjs`：首参是源码仓库根（= 声明的基线工作树），不是知识库目录；五态输出，`UNVERIFIED`/`TRAVERSAL` 不静默放过。`--stats` 输出每篇引用数、密度与「单段多引用」段落，仅作自查。
- `check-mermaid.mjs`：真解析所有 Mermaid 块；`[MERMAID-ERROR]` 必须修到全 `OK`。
- `audit-svg-topology.mjs`：SVG 边拓扑审计，结构图新画或重排必跑。有 `class="node"/"edge"` 走严格模式，`diagram-design` 产物自动走几何推断（输出标「推断模式」）；`[EDGE-UNPARSED]`（识别不到节点）与非 0 退出码都必须修。
- `render-svg-preview.mjs`：自绘 SVG 的目视兜底（展平 `var()` 后出 PNG）。`diagram-design` 产物直接看其 HTML，不进必跑清单。
- `scan-narrative.mjs` / `check-narrative-all.mjs`：叙述型 `architecture-design.md` 的零代码索引、标题编号与交叉引用校验；没有该文档时不跑。
- `select-baseline.mjs`：稳定 tag > 稳定分支 > 默认分支 > 兜底矩阵；退出码 `2` = 需用户确认/选择。

本地回归（临时目录，不需外部服务）：

```bash
bash skills/project-insight/scripts/tests/baseline-smoke.sh     # 基线选择
bash skills/project-insight/scripts/tests/references-smoke.sh   # 零引用合法 / 五态 / --stats
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
