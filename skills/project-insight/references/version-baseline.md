# 版本基线选择（本次解读基于哪个版本）

> 由 SKILL.md「执行流程主干」的 **step 0.5** 按需加载，位置在 step 0（输入规范化 / `kb_repo` 判定，见 [kb-repo-rules.md](kb-repo-rules.md)）之后、step 1（模式判定）之前。承载：**解读基于哪个 git ref（tag / 分支 / 默认分支）、这份快照怎么落到磁盘、基线怎么记录**。落地产出见 [flow-new.md](flow-new.md) / [flow-incremental.md](flow-incremental.md)。

## 为什么基线必须先定（不是可选细节）

- 解读产物里每条论断都靠 `文件:行号` 佐证，而**行号只在一份具体快照上成立**：同一文件在 `main` 与 `v1.2.3` 上可能差出几百行。基线不定就开写 = 行号必然漂移。
- `scripts/verify-references.mjs` 只读磁盘文件（全脚本无 git 调用），**校验根就是 `source_repo` 的工作树**。因此"基线"必须落成一份**真实可读的工作树**，且这份工作树同时是探索/写作/校验的根 —— 换了树，校验通过也无意义。
- 增量模式要拿基线当 diff 的 base ref（[flow-incremental.md](flow-incremental.md) 铁律 3 的前提）；没有记录的基线，"上游 git diff"只能靠猜。

## 判定优先级（tag > 稳定分支 > main/master > 兜底）

**一律先跑脚本，不凭印象选**（脚本只读、不改文档；`[BASELINE-AMBIGUOUS]` 非 0 退出码即走"用户选择"分支）：

```
node scripts/select-baseline.mjs <本地路径|远端URL> [--ref <ref>] [--package <名>] [--json]
```

自查：`bash scripts/tests/baseline-smoke.sh`（临时仓库里现造 fixture，断言覆盖 tag 优先 / 预发布与移动 tag 排除 / 稳定分支 / 多包歧义 / 陈旧拦截 / 无 main/master 兜底 / 特性分支不当主干 / 脏工作树 / 远端模式 / `--ref` 校验）。

| 序 | 基线类型 | 认定 |
|----|----------|------|
| 1 | **稳定 tag** | 版本号形态的正式发布 tag，取 semver 最高者；预发布与移动 tag 排除（细则见下） |
| 2 | **稳定分支** | 发行/维护语义分支（`release*` / `stable*` / `maintenance*` / `1.x`），取版本号高者 → 最近提交者 |
| 3 | **默认分支** | `main` → `master` → 远端 `HEAD` 符号引用（`git ls-remote --symref <url> HEAD`）解析出的真实默认分支 |
| 4 | **无 main/master 兜底** | 按下方兜底矩阵逐级下落，并在产物中显式声明"无稳定基线，按 {ref} 解读" |

优先级只为**默认**：用户显式给出 ref（"看最新代码""按 v2 那个 tag"）时以用户为准，但必须在产物中声明"本次按用户指定 ref 解读，非稳定版"（见下方「用户显式指定」）。

## 稳定 tag 的认定

- **纳入**：`vX.Y.Z` / `X.Y.Z` / `V1.2` / `1.2`（去掉 `v`/`V` 前缀后是纯数字点分）。
- **排除（降级到"无版本 tag 时"才考虑）**：
  - 预发布：核心版本号后带 `-alpha` / `-beta` / `-rc` / `-pre` / `-dev` / `-SNAPSHOT` / `-canary` / `-nightly`；或 tag 名含 `alpha|beta|rc|pre|dev|snapshot|canary|nightly|test` 词。
  - 移动 tag：`latest` / `stable` / `release` / `current` / `edge` / `nightly` 等非版本号 tag —— 它们指向会变，不能当快照锚点。
- **多候选排序**：semver 逐段比数值，高者胜；同版本号取带 `v` 前缀者（更规范）。
- **单仓多包 tag（monorepo）**：tag 形如 `pkg@1.2.3` / `pkg/v1.2.3`。先按 `--package <名>` 或项目主包名匹配；**匹配不到即判歧义**（[BASELINE-AMBIGUOUS]），不猜哪个包代表"项目版本"，交用户选择。

## 稳定分支的认定

| | 命中 | 排除 |
|---|---|---|
| 模式 | 前缀命中：`release` / `releases` / `stable` / `lts` / `maintenance` / `maint` / `support`（后接 `/` 或 `-`，如 `release/1.x`、`stable-2.0`）；或纯版本形态：`1.x` / `v1.2.x` / `1.2` | `feat/*`、`feature/*`、`fix/*`、`bugfix/*`、`hotfix/*`、`refactor/*`、`chore/*`、`docs/*`、`test/*`、`experiment/*` / `exp/*`、`poc/*`、`wip/*`、`tmp/*`、`dependabot/*`、`renovate/*` |
| 排序 | 版本号高者 → 最近提交者（本地仓库可读日期，远端退化为字典序，保证确定性） | — |

主干名（`main` / `master` / `trunk` / `develop` / `development` / `default` / `next`）**不参与本档**，它们在第 3、4 档处理。

## 无 main/master 的兜底矩阵

仓库没有 `main` / `master` 是**常态而非异常**（默认分支叫 `develop` / `trunk` / `next` 的项目不少）。逐级下落，命中即止：

| 级 | 兜底来源 | 说明 |
|----|----------|------|
| 4.1 | 远端 `HEAD` 符号引用解析出的默认分支 | 最可靠：`git ls-remote --symref <url> HEAD` 第 2 行即 `refs/heads/<默认分支>`；这是托管平台的真实默认分支，不靠命名猜 |
| 4.2 | 本地 `refs/remotes/origin/HEAD` | 已有克隆的等价信号；本地读不到时用 4.1 的 `ls-remote` 补 |
| 4.3 | 当前 `HEAD` 所在分支（**仅当它不是特性/临时分支**） | 默认分支名叫 `devel` / `master-2` 这类认不出命名时最实用；命中即在产物中报告"基线与默认命名无关" |
| 4.4 | 常见主干名 | `trunk` → `develop` → `development` → `default` → `next` → `head` |
| 4.5 | 最近提交的非特性分支 | 排除特性/临时分支前缀后取提交最新者 |
| 4.6 | 只剩 tag | 取最新 tag（含预发布）并在产物中声明"仓库无分支可依，按 {tag} 解读" |

六级全空（裸仓库且无分支无 tag）→ `[BASELINE-AMBIGUOUS]`，交用户给出 ref。
**禁止**默默把"当前 `HEAD`"当基线的前提是：它必须是**非特性分支**且已被脚本报告出来；detached HEAD 或特性分支（`feat/*`、`wip/*`…）一律不得当主干 —— 那可能是任何人的半成品（这条与禁止凭 cwd 臆断 `kb_repo` 同理）。

## 两个必须拦住的坑

- **陈旧 tag 陷阱**：项目停更或已切到新版本线时，"最高 tag"会指向过时快照。选定 tag 落后**默认分支**超过阈值（默认 500 commits 或 730 天，脚本内可调）→ 输出 `[BASELINE-STALE]` 警告并**要求用户确认**，不静默按老 tag 解读（老代码里可能已删掉的模块会让整篇解读失真）。
- **用户显式指定 ref**：`--ref` / 用户口头指定时，覆盖上述优先级；脚本仍校验该 ref 存在（远端任意 SHA 无法离线校验，脚本会标注），产物必须声明"按用户指定 ref 解读，非稳定版"，且**不得**把这个 ref 写成语义上的"稳定基线"（记录时写原 ref）。

## 基线落地：从 ref 到"可读工作树"（验证根）

选定 ref 只是元数据；解读与校验都需要一份磁盘工作树。**解读对象基本是开源项目，所以默认动作是最轻的那种 —— 让基线成为"进入"的起点，而不是事后回退**：

| 输入形态 | 工作树状态 | 默认动作 | 理由 |
|---|---|---|---|
| 远端 URL（最常见） | — | `git clone --branch <ref> --depth=1 <url> <dest>` | 基线即克隆起点，**一次到位、无需二次检出**；tag 同样支持 `--branch`。禁止裸 `--depth=1`（丢 tags、锁死默认分支）；需要 diff 历史时改 `--filter=blob:none` 或不带 `--depth` |
| 本地路径（本次自己的克隆 / 用户源码克隆） | 干净（`git status --porcelain` 为空） | 就地 `git checkout <ref>` | 最省事；detached HEAD 无妨。**进入前记下原 `HEAD`（分支名或 SHA），收尾恢复**并向用户报告这两步 |
| 本地路径 | 脏（有未提交改动） | **不静默覆盖** → 二选一：① `git worktree add <tmp> <ref>`（非破坏性，推荐）② 用户确认后 `git stash` + `git checkout <ref>` + 收尾 `git stash pop` | 用户改动可能与本任务无关，本 skill 无权丢弃；worktree 是脏树场景的兜底，不是默认路径 |
| 本地路径 | Git 过旧 / 不支持 worktree | `git archive <ref> \| tar -x -C <tmp>` | 有独立工作树可读，代价是拿不到 `git diff` 历史 |

- 无论哪条路径，**`source_repo` = 该工作树 `realpath` 后的绝对路径**，它同时是引用校验根（见 [grounding-guide.md](grounding-guide.md)）。
- 收尾：`git checkout <原 ref>` 恢复（worktree 场景 `git worktree remove <tmp>`），并在交付说明里写清"解读在 {ref} 上完成、原工作树已恢复"。
- 工作树已等于选定基线（`git describe --tags --exact-match` 命中或 HEAD 即该 ref）时**跳过检出**，不折腾。

## 基线记录（写进产物，不留记忆）

frontmatter 按纪律不写版本类字段（[SKILL.md](../SKILL.md)「文档元数据纪律」/ [kb-repo-rules.md](kb-repo-rules.md)），基线改记在两处**已在的**载体上：

1. **`CHANGELOG.md` 顶部条目首行**：`依据：<ref>@<短SHA>`（该文件本就是版本集中入口，[flow-incremental.md](flow-incremental.md)「版本变更汇总」已规定首行写依据来源）。
2. **项目 `README.md` 概览处一行**：`解读基线：v1.2.3（abc1234）`（整行用反引号包住，ref + 短 SHA 各就位）—— 作为"现状描述对得上哪份代码"的锚点，读者一眼可核。

全新模式的首次解读同样写这两处（此时 `CHANGELOG.md` 可能尚不存在，按 flow-incremental 的「首次创建并回写链接」约定建）。

## 与增量模式的衔接

增量时基线演化成 diff 的两端，门禁顺序固定为：

```
记录基线 ref（旧） → select-baseline.mjs 选定新 ref → git diff <旧>..<新> → verify-references.mjs --diff 引用预检 → 仅 STALE/UNRESOLVED 章节可改
```

- 找不到基线记录（老解读、脚本未署基线）→ 退化为**代码快照比对**，并在文中显式声明"本次依据代码快照比对，非官方 changelog"（[flow-incremental.md](flow-incremental.md) 已有该退化语义）。
- 新旧基线相同且无新 release → 触发增量止损（noop），不重写。

## 歧义处理（走"用户选择"分支）

命中以下任一即 `[BASELINE-AMBIGUOUS]` / `[BASELINE-STALE]`（脚本非 0 退出码），**不做开放式提问**，按结构化候选（通常二选一）列出 + 各自代价与后果：

- 多包 tag 无法唯一定位项目版本；
- 最高版本 tag 并列（不同包线或 `v1.2` 与 `1.2.0` 混用）；
- 选定 tag 判定陈旧（`[BASELINE-STALE]`）；
- 无 tag、无分支、无默认分支可依。

话术示例：

> "该项目无法唯一确定稳定基线：候选 ① `v2.1.0`（比默认分支 `main` 落后 830 commits，可能已过时）② 默认分支 `main`@`a1b2c3d`（最新开发态）。按 tag 解读更稳但可能漏掉新版本，按 `main` 解读最新但行号会随开发漂移。请选择，或直接给出 ref。"
