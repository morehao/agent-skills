# release 分支：`pr-merge` 之后的发布段

**主线只做三件事：打 tag → 跟踪 tag 触发的发布后效 → 校验并出回执。** 不改版本号、不建分支、不开 PR——版本号已经随前置 PR 合并进稳定分支。**唯一例外**：用户在选项里选了「写 CHANGELOG.md」时，会为这一个文件开一次分支 + PR（见步骤 2），且必须在打 tag 之前合入。

**两条必须守住的边界（否则会把某个仓库的习惯当成通用规律）：**

1. **版本来源因仓而异**：有可发布清单（`package.json`）就读它的 `version`；Go/Rust 等没有清单的仓库，**tag 本身就是版本源**，靠 `--tag` 传入。
2. **tag 之后发生什么因仓而异**：npm 包、容器镜像、文档站、GitHub Release，或者什么都不做。git-kit **只探测、只跟踪、只如实报告**，绝不断言"发版成功"。

## 起点与边界

| 项 | 说明 |
|---|---|
| 起点 | 稳定分支（默认 `main`）最新提交，且其版本已领先最新 tag |
| 前置 | 升版本走 `commit-push` → `pr-create` → `pr-merge`（`references/stable-branch.md`） |
| 本分支不做 | 改版本号、建 `release/*` 分支、开 PR、合并、回合并 |
| 与 `tag` 的分界 | `tag` 只打标签就结束；`release` = 打标签 + 跟踪后效 + 逐项校验 + 回执 |
| 判定来源 | 稳定分支与 tag 约束复用 `stable-branch.md` / `tag.md`「发版约束」，本文件不复述 |
| 决策方式 | **一律用选项式提问**（`references/ask-options.md`）：计划卡只负责告知，待决事项必须变成可点的选项，不打印现状等人用自然语言回答 |

## 后效是仓库事实，不是假定

预检从仓库里**探测**这些信号，探测结果写进输出，不做推断性结论：

| 信号 | 探测依据 | 校验方式 |
|---|---|---|
| `TAG_WORKFLOWS` | `.github/workflows/*.yml` 的 `on:` 段含 `tags:`（`jobs:` 之前） | 每个 workflow 的 run 结论 |
| `EFFECT_NPM` | `package.json` 有 `publishConfig`，或任一 workflow 含 `npm publish` | `npm view <name>@<version>` |
| `EFFECT_GH_RELEASE` | tag workflow 里出现 `action-gh-release` / `gh release create` | `gh release view <tag>` |
| 其他（镜像 / 文档站 / 部署） | **不探测** | 记为"未检测到"；确需跟踪时用选项问「继续（推荐）/ 指定产物与校验方式」，不猜 |

探测只看**未注释**的行（workflow 头部注释里常出现 `tags:` / `npm publish` 之类字样，注释不能算后效）。

**探测不到 ≠ 没有后效。** 报告一律写「未检测到可校验的后效」，不写「无后效」；也不把没探到的东西当成失败。

## 执行流程

### 0. 预检（只读）

```bash
bash scripts/release-preflight.sh              # 无清单仓库加 --tag v1.1.0
```

读 `VERSION_SOURCE`、`PKG_VERSION`、`PKG_CANDIDATES`、`TARGET_TAG`、`TAG_EXISTS`、`TAG_ON_BASE`、`LATEST_SEMVER`、`CHANGELOG`、`CHANGELOG_HAS_VERSION`、`COMMITS`/`TOTAL_COMMITS`、`TAG_WORKFLOWS`、`EFFECT_NPM`、`EFFECT_GH_RELEASE`、`NPM_PUBLISHED`、`STATE`、`BLOCKERS`、`WARN`。

| STATE | 含义 | 动作 |
|---|---|---|
| `READY` | 目标 tag 尚未存在 | 步骤 1 →（可选 2）→ 3 → 4 |
| `TAGGED` | tag 已存在 | **跳过步骤 2 与 3**：tag 正文不可改，CHANGELOG 也无从补入，直接跟踪与校验（重跑即幂等） |
| `NEEDS_TAG` | 无清单且未给 `--tag` | 停，**用选项**索取目标 tag（`v0.1.0` / `v1.0.0` / 自定义，另可 `先补版本清单`） |
| `BLOCKED` | 版本没领先 tag / tag 不在稳定分支历史 / `--tag` 与清单版本不一致 | 停，按 `BLOCKERS` **给对应选项**（见步骤 1 的 BLOCKED 选项表），不是「说明完就结束」 |

`WARN` 不阻断：`dirty-worktree` 不影响打 tag；`npm-unknown` 是查不了而非未发布；`gh-missing` 表示无法跟踪流水，给选项「继续只做产物校验（推荐）/ 停止」；`latest-tag-not-semver` 表示 tag 无法与版本号比较（守卫跳过，改由计划卡的 tag 确认兜底）；`multiple-publish-packages` 要按 `PKG_CANDIDATES` 用 `--pkg` 指定发布包；`commits-truncated` 表示变更说明超过 300 条，需要时给 `changelog.sh` 加 `--max`。

### 1. 唯一一次确认（计划卡 + 选项）

```
发布计划
  版本源   <manifest: commands-dsh/package.json | tag>
  版本     <PKG_VERSION 或 --tag>（自 <LATEST_TAG> 起 N 个提交：feat a / fix b / breaking c）
  tag      <TARGET_TAG> @ <BASE_REF> 的 <sha>（注记 tag，正文见下方变更说明）
  说明     变更说明全文（进 tag 注记，也是 Release notes 的来源）
  CHANGELOG <有：<文件>，已记录/未记录 | 无此文件> → 作为下文第 ② 题的选项呈现
  后效     workflow: <TAG_WORKFLOWS 或「未检测到」>
           npm: <包名 或「未检测到」>
           GitHub Release: <是 / 未检测到>
  校验     逐个后效给结论；未检测到的不猜
```

变更说明由 `scripts/changelog.sh`（与 `tag` 共用）从 Conventional Commits 生成，**必须在打 tag 前展示给用户过目**——注记正文推送后不可修改。生成后**立刻落盘成临时文件**，它就是步骤 3 要推送的正文；用户确认的是这份文件，后续**不再重新生成**（否则步骤 2 的 CHANGELOG 合并提交会混进正文，与 `CHANGELOG.md` 也对不上）：

```bash
NOTES="$(mktemp)"
{ echo "release: ${TARGET_TAG}"; echo; \
  bash scripts/changelog.sh --from "${LATEST_TAG}" --to "${BASE_REF}" --link-to "${TARGET_TAG}"; } > "$NOTES"
cat "$NOTES"          # 作为计划卡正文展示；决策走下面的选项
```

首个版本去掉 `--from`。**`--link-to` 不可省**：`--to` 是 `origin/main` 这类远端跟踪名，直接塞进 compare 链接会得到 404；`--link-to` 指向即将打的 tag，推送后链接即有效。

计划卡只是**告知**（版本源、tag、sha、注记正文、探测到的后效）。紧接着必须**把这一阶段所有待决事项并进同一次选项式提问**（`references/ask-options.md`）——不要打印完计划卡就停下来等用户回一句「可以」。长内容留在计划卡正文里，选项只写短标签 + 后果：

| STATE | 同一次提问里的题 | 选项（推荐项在前） |
|---|---|---|
| `READY` | ① 是否按此打 tag | `按此打 tag`（推荐）/ `取消` / `改 tag 名或说明` |
| | ② 是否写 `CHANGELOG.md` | `不写，直接打 tag`（推荐，零副作用）/ `写，并走一次分支 + PR` |
| | ③ GitHub Release 谁创建（**仅** `EFFECT_GH_RELEASE=no` 时问） | `不创建`（推荐）/ `由本流程创建` |
| `NEEDS_TAG` | 目标 tag | `v0.1.0`（推荐，首个版本）/ `v1.0.0` / `自定义` |
| `TAGGED` | 无需提问（只跟踪校验，重跑幂等） | — |

- `EFFECT_GH_RELEASE=yes` 时第 ③ 题不问：由仓库 workflow 创建，本流程只校验 notes 非空，不擅自再建一个。
- 第 ② 题选「写」才进步骤 2；选「不写」则全程不碰工作区。

`BLOCKED` 时同样不是「逐条说明就结束」，而是按 `BLOCKERS` 给选项：

| `BLOCKERS` | 选项（推荐项在前） |
|---|---|
| `version-not-ahead-of-tag` | `升 patch 到 <下一版>`（推荐）/ `升 minor 到 <y>` / `升 major 到 <z>` / `只跟踪现有 tag，不发新版本` |
| `tag-not-on-base` | `停止`（推荐）/ `授权删 tag 重打`（不可逆：正文与目标 sha 都无法改） |
| `tag-version-mismatch` | `先升版本到 <tag 版本>`（推荐）/ `改用清单版本 <PKG_VERSION> 作 tag` / `停止` |

除「只跟踪现有 tag」外，升版本都要走 `commit-push` → `pr-create` → `pr-merge`，合并后重新预检（**本流程不改版本号**）。

用户选完后**不再中途询问**；后续唯一会再提问的场合是步骤 4 出现失败/超时（给「只报告 / 重跑 / 下个版本」，见步骤 4）。

### 2. 可选：写 CHANGELOG.md（需要一次分支 + PR）

**这是 release 唯一的越界动作，且只由用户在选择时明确开启。** 不选就完全保持原样：不建分支、不开 PR、不碰工作区。

为什么必须开分支：`CHANGELOG.md` 是仓库文件，直接改稳定分支违反「稳定分支不直接提交」；而 release 又不该有写权限，所以交给正常的 PR 流程。**顺序不能颠倒**——文件必须在打 tag 之前合进稳定分支，否则 tag 指向的那次提交里没有这条记录。

触发条件：`STATE=READY` 且用户选了「写」。

1. **写入工作区**（幂等，已记录则跳过）：

   ```bash
   git switch -c "docs/changelog-${TARGET_TAG}" "${BASE_REF}"
   bash scripts/changelog.sh --from "${LATEST_TAG}" --to "${BASE_REF}" \
        --version "${TARGET_TAG}" --link-to "${TARGET_TAG}" --write CHANGELOG.md
   ```

   退出码：`0` 已写入（`CREATED` / `WROTE`）／`3` 该版本小节已存在（视为完成，继续下一步）／`4` 无变更可记录（报告并跳过写文件，直接去打 tag）。

2. **提交并推送**（同一链式；远端用预检的 `${REMOTE}`，不要写死 `origin`——双远端仓库里 upstream 才是发布源）：

   ```bash
   git add CHANGELOG.md && git commit -m "docs(changelog): record ${TARGET_TAG}" && git push ${REMOTE} HEAD && echo "PUSH_OK"
   ```

3. **建 PR 并合并**：复用同 skill 的 `pr-create` → `pr-merge`（base 为稳定分支、squash、head 是 `docs/*` 非稳定分支 → `DELETE`）。合并前不进入下一步。

4. **重新预检**：合并后稳定分支前移，tag 必须指向**新的** `<BASE_REF>`：

   ```bash
   bash scripts/release-preflight.sh
   ```

   确认 `STATE` 仍为 `READY`、`TAG_EXISTS=no`、`CHANGELOG_HAS_VERSION=yes`（记录已在主干上），再进步骤 3。**注意：主干前移不影响已确认的正文**——步骤 3 仍用步骤 1 那份 `${NOTES}`，不重新生成（重新生成会把刚合入的 `docs(changelog)` 提交算进正文）。

失败即停：CHANGELOG PR 没合进来之前**不打 tag**。已打 tag 才发现漏记 → 不改 tag，改为在下一个版本补记，或经用户明确授权后删 tag 重打（见「失败与重跑」）。

### 3. 打 tag

按 `references/tag.md`：注记 tag、指向 `<BASE_REF>` 最新提交、推送前核对版本一致。**正文直接用步骤 1 已让用户确认的 `${NOTES}`**：

```bash
git fetch ${REMOTE} --tags
git tag -a "${TARGET_TAG}" -F "$NOTES" "${BASE_REF}"
git push ${REMOTE} "${TARGET_TAG}"
echo "TAG_PUSH_OK"
```

注记正文 = 首行 `release: <TARGET_TAG>` + 步骤 1 的变更说明（含已确认的 compare 链接）；首个版本省掉 `--from`。

`STATE=TAGGED` 时不重复打，直接进步骤 4（此时步骤 2 的 CHANGELOG 分支也不再提供——tag 已固定）。若这次是重跑、步骤 1 没生成 `${NOTES}`，先按步骤 1 的命令现生成一份（`--to` 用当前的 `BASE_REF`），否则步骤 4 的 `gh release create` 会拿到空路径。

### 4. 逐个跟踪后效

对 `TAG_WORKFLOWS` 里的**每一个** workflow：

```bash
gh run list --workflow <file> --limit 20 --json databaseId,headBranch,status,conclusion
```

按 `headBranch == <TARGET_TAG>` 匹配，15 秒一次、最多 10 分钟，逐个给结论：

| workflow 结论 | 报告 |
|---|---|
| `success` | ✅ 耗时 t |
| `failure` | ❌ 给 run 链接与失败步骤 |
| 超时未结束 | ⏳ 给 run 链接与当前状态 |
| 匹配不到 run | ⚠️ 说明「该 workflow 未见 tag 触发记录」，不判成功 |

出现 `failure` / 超时 / 匹配不到 run 时，报告完给**一题选项**（`references/ask-options.md`）：`只报告`（推荐）/ `gh run rerun <id>`（仅 failure）/ `下个版本再发`。不自行 rerun，也不因为「重跑一下可能就好了」替用户决定。

然后按探测到的产物类型校验：

- `EFFECT_NPM=yes`：`npm view <name>@<version> --registry https://registry.npmjs.org` → 可见 / 不可见 / 查不了（三档，查不了不算失败也不算成功）
- `EFFECT_GH_RELEASE=yes`：`gh release view <tag>` → 存在（并检查 notes 非空）/ 不存在
- 选项里选了「由本流程创建」：`gh release create <tag> --notes-file "$NOTES"`（用步骤 1 已确认的文件；重跑时先按上面说明生成）→ 创建后回读确认
- 两者皆 `no` 且 `TAG_WORKFLOWS=<none>`：明确写「本仓未检测到 tag 触发的发布流水；tag 即交付物」，不做任何成功断言

非 GitHub 仓库（GitLab/Gitea）：`gh run list` 不适用，报告为「流水状态未知」，并给选项 `继续按可得信息出回执`（推荐）/ `停止，人工核对后再跑`，不猜。

### 5. 回执

```
✅ release v1.1.0（tag 已推送）
  tag       v1.1.0 → 3f9c2a1（main 上）              ✅
  workflow  release.yml                              ✅ success 2m13s
  npm       @morehao/dsh-commands@1.1.0              ✅ 可见
  gh rel.   —                                        ⏭ 未检测到
  changelog CHANGELOG.md                             ✅ 已记录 v1.1.0
```

每个后效独立一行、独立结论，**不合并成一句「发布成功」**。任一 ❌ 时回执顶部改成 `⚠️` 并列出失败项。

## 失败与重跑

| 情况 | 处理 |
|---|---|
| workflow 失败 | **不删 tag 重打**（tag 不可变）；给 run 链接 + 选项 `只报告`（推荐）/ `gh run rerun <id>` / `下个版本再发` |
| 仍在跑 | 可中止；重跑本流程会从 `TAGGED` 继续跟踪，不会重复打 tag |
| 已全部通过 | 重跑同样给出一致回执（幂等） |
| 版本没领先 tag | `STATE=BLOCKED`，给选项 `升 patch`（推荐）/ `升 minor` / `升 major` / `只跟踪现有 tag`，再走升版本 PR |
| tag 不在主干 | `STATE=BLOCKED` + `BLOCKERS=tag-not-on-base`，多为打错分支；给选项 `停止`（推荐）/ `授权删 tag 重打`（不可逆） |
| `--tag` 与清单版本不一致 | `STATE=BLOCKED` + `BLOCKERS=tag-version-mismatch`，给选项 `先升版本到 <tag 版本>`（推荐）/ `改用清单版本作 tag` / `停止`，**不静默改 tag 目标** |
| 无清单且无 `--tag` | `STATE=NEEDS_TAG`，用选项索取目标 tag（`v0.1.0` / `v1.0.0` / 自定义） |
| CHANGELOG PR 未合并 | 停：不打 tag。先合并 PR 再重新预检（否则 tag 指向的提交没有这条记录） |
| CHANGELOG 已含该版本 | `changelog.sh` 退出码 3，视为完成，不重复写、不重复开 PR |
| 打完 tag 才发现漏记 | 不改 tag；记到下一个版本，或经用户明确授权后删 tag 重打 |

## 边界

- **不做**：改 `package.json`、改代码、删 tag、重打 tag、force push、npm 撤销发布（只能 `deprecate`）、改 workflow、代跑发布脚本
- **唯一例外**：用户在选择里明确要写 `CHANGELOG.md` 时，会建**一个** `docs/changelog-<tag>` 分支并走一次 `pr-create` → `pr-merge`。不选则完全不碰工作区；除 `CHANGELOG.md` 外不改任何文件，且必须合进稳定分支后才打 tag
- **不假设**：不内置任何"发版必须发 npm"的判断；npm 只是探测到才校验的一个后效
- **不替代**：`tag`（任意分支打标签）、`pr-merge`（合并本身）

## 验收标准

- 远端存在 `<TARGET_TAG>`，且 `git merge-base --is-ancestor <TARGET_TAG> <BASE_REF>` 成立
- 版本源为 manifest 时：`<BASE_REF>` 的 `package.json.version == <TARGET_TAG>`（去 `v`）
- tag 注记非空且含变更说明（`git for-each-ref --format='%(contents)' refs/tags/<tag>` 可读）
- 每个探测到的后效都有独立结论（成功 / 失败 / 未知），没有一个被静默跳过
- 每个需要用户决定的场合都落成了**带选项的提问**（含推荐项与自定义兜底），没有开放式追问、没有「打印现状等人回复」
- 未探测到的后效在回执里显式标注「未检测到」，不说成「无后效」或「已发布」
- 选了写 CHANGELOG 时：合并后重新预检 `CHANGELOG_HAS_VERSION=yes`，且 tag 指向**合并之后**的 `<BASE_REF>`（不是合并前那次的 sha）
- 任一步失败 → 停在当前状态，报告「STATE + 已做/未做 + 下一条命令」，不伪造成功
