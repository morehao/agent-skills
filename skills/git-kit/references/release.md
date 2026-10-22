# release 分支：`pr-merge` 之后的发布段

**主线：打 tag → 创建/校验平台 Release → 跟踪 tag 触发的其他后效 → 出回执。** Release（GitHub/GitLab）是**默认交付物**：平台支持、CLI 可用且 CI 不负责时，默认由本流程创建，**不额外加一次提问**。不改版本号、不建分支、不开 PR——版本号已经随前置 PR 合并进稳定分支。**唯一例外**：用户在选项里选了「写 CHANGELOG.md」时，会为这一个文件开一次分支 + PR（见步骤 2），且必须在打 tag 之前合入。

**三条必须守住的边界（否则会把某个仓库或某个平台的习惯当成通用规律）：**

1. **版本来源因仓而异**：有可发布清单（`package.json`）就读它的 `version`；Go/Rust 等没有清单的仓库，**tag 本身就是版本源**，靠 `--tag` 传入。
2. **Release 能力因平台而异**：GitHub 用 `gh`，GitLab 用 `glab`；host、平台、CLI、登录状态、Release 是否已存在全部由预检**探测**。平台未知（自建/非 GitHub/GitLab）时**不猜 API**，降级为「只打 tag + 给手动命令」。
3. **tag 之后发生什么因仓而异**：npm 包、容器镜像、文档站、CI 建的 Release，或者什么都不做。git-kit **只探测、只跟踪、只如实报告**，绝不断言"发版成功"。

## Release 是默认交付物

| 情形 | 默认行为 |
|---|---|
| 平台是 GitHub/GitLab、CLI 已登录、CI 不建 Release | **本流程创建**（body = 已确认的变更说明） |
| CI 会建 Release（`EFFECT_RELEASE=workflow`） | 不重复建，只校验；流水失败导致缺失时给「补建」选项 |
| 平台未知 / CLI 缺失 / 未登录 | 不建，回执写清原因并给**可复制的手动命令** |
| 用户明确选「只打 tag，不建 Release」 | 不建（显式降级，不是默认） |

Release 的 title/name = tag 名；body = tag 注记里除首行 `release: <tag>` 之外的同一份正文（单一真源，两处不会漂移）。

## 起点与边界

| 项 | 说明 |
|---|---|
| 起点 | 稳定分支（默认 `main`）最新提交，且其版本已领先最新 tag |
| 前置 | 升版本走 `commit-push` → `pr-create` → `pr-merge`（`references/stable-branch.md`） |
| 本分支做 | 打 tag、**创建/校验平台 Release**、跟踪后效、逐项校验、出回执 |
| 本分支不做 | 改版本号、建 `release/*` 分支、开 PR、合并、回合并、删 Release、改 tag |
| 与 `tag` 的分界 | `tag` 只打标签就结束；`release` = 打标签 + Release + 跟踪后效 + 回执 |
| 判定来源 | 稳定分支与 tag 约束复用 `stable-branch.md` / `tag.md`「发版约束」，本文件不复述 |
| 决策方式 | **一律用选项式提问**（`references/ask-options.md`）：计划卡只负责告知，待决事项必须变成可点的选项，不打印现状等人用自然语言回答 |

## 后效是仓库事实，不是假定

预检从仓库里**探测**这些信号，探测结果写进输出，不做推断性结论：

| 信号 | 探测依据 | 校验方式 |
|---|---|---|
| `TAG_WORKFLOWS` | GitHub：`.github/workflows/*.yml` 的 `on:` 段含 `tags:`（`jobs:` 之前） | 每个 workflow 的 run 结论 |
| `EFFECT_RELEASE` | GitHub：tag workflow 含 `action-gh-release` / `gh release create`；GitLab：`.gitlab-ci.yml` 由 `CI_COMMIT_TAG` 触发且含 `release:` / `glab release create` | CI 建则校验；CI 不建则**默认由本流程创建** |
| `EFFECT_NPM` | `package.json` 有 `publishConfig`，或任一 workflow 含 `npm publish` | `npm view <name>@<version>` |
| `RELEASE_EXISTS` | `gh release view` / `glab release view`（未登录/查不了 → `unknown`） | 决定「创建」还是「只校验」 |
| 其他（镜像 / 文档站 / 部署） | **不探测** | 记为"未检测到"；确需跟踪时用选项问「继续（推荐）/ 指定产物与校验方式」，不猜 |

探测只看**未注释**的行（workflow / `.gitlab-ci.yml` 头部注释里常出现 `tags:` / `release:` / `npm publish` 之类字样，注释不能算后效）。

**探测不到 ≠ 没有后效。** 报告一律写「未检测到可校验的后效」，不写「无后效」；也不把没探到的东西当成失败。

## 执行流程

### 0. 预检（只读）

```bash
bash scripts/release-preflight.sh              # 无清单仓库加 --tag v1.1.0
```

读 `HOST`、`REPO_ID`、`RELEASE_PLATFORM`、`RELEASE_CLI`、`RELEASE_CLI_READY`、`EFFECT_RELEASE`、`RELEASE_EXISTS`、`RELEASE_PRERELEASE`、`CI_SYSTEM`、`GITLAB_TAG_CI`、`VERSION_SOURCE`、`PKG_VERSION`、`PKG_CANDIDATES`、`TARGET_TAG`、`TAG_EXISTS`、`TAG_ON_BASE`、`LATEST_SEMVER`、`CHANGELOG`、`CHANGELOG_HAS_VERSION`、`COMMITS`/`TOTAL_COMMITS`、`TAG_WORKFLOWS`、`EFFECT_NPM`、`NPM_PUBLISHED`、`STATE`、`BLOCKERS`、`WARN`。

| STATE | 含义 | 动作 |
|---|---|---|
| `READY` | 目标 tag 尚未存在 | 步骤 1 →（可选 2）→ 3 → 4（默认创建 Release） |
| `TAGGED` | tag 已存在 | **跳过步骤 2 与 3**：tag 正文不可改，CHANGELOG 也无从补入；直接进步骤 4（**Release 缺失则补建**，重跑即幂等） |
| `NEEDS_TAG` | 无清单且未给 `--tag` | 停，**用选项**索取目标 tag（`v0.1.0` / `v1.0.0` / 自定义，另可 `先补版本清单`） |
| `BLOCKED` | 版本没领先 tag / tag 不在稳定分支历史 / `--tag` 与清单版本不一致 | 停，按 `BLOCKERS` **给对应选项**（见步骤 1 的 BLOCKED 选项表），不是「说明完就结束」 |

`WARN` 不阻断，但决定了 Release 的默认动作：

| `WARN` | 影响 |
|---|---|
| `release-cli-missing` | 本平台 CLI 不在 PATH → 无法自动创建，计划卡标「附手动命令」 |
| `release-auth-missing` | CLI 未登录该 host → 同上，并提示先登录 |
| `release-host-unknown` | 自建/非 GitHub/GitLab → 不猜 API，只给手动命令 |
| `release-check-unknown` | 有 CLI 但查询失败 → 不能断言已存在；`TAGGED` 时不冒险创建 |
| `dirty-worktree` | 不影响打 tag |
| `npm-unknown` | 查不了而非未发布 |
| `latest-tag-not-semver` | tag 无法与版本号比较（守卫跳过），改由计划卡的 tag 确认兜底 |
| `multiple-publish-packages` | 要按 `PKG_CANDIDATES` 用 `--pkg` 指定发布包 |
| `commits-truncated` | 变更说明超过 300 条，需要时给 `changelog.sh` 加 `--max` |

### 1. 唯一一次确认（计划卡 + 选项）

```
发布计划
  版本源   <manifest: commands-dsh/package.json | tag>
  版本     <PKG_VERSION 或 --tag>（自 <LATEST_TAG> 起 N 个提交：feat a / fix b / breaking c）
  tag      <TARGET_TAG> @ <BASE_REF> 的 <sha>（注记 tag，正文见下方变更说明）
  说明     变更说明全文（进 tag 注记，也是 Release body 的来源）
  Release  <github|gitlab>：<将由本流程创建 | 由 CI 创建后校验 | 无法自动创建：<原因>>
           title = <TARGET_TAG>；body = 上方说明；预发布：<是|否>
  CHANGELOG <有：<文件>，已记录/未记录 | 无此文件> → 作为下文第 ② 题的选项呈现
  后效     workflow: <TAG_WORKFLOWS 或「未检测到」>
           npm: <包名 或「未检测到」>
  校验     逐个后效给结论；未检测到的不猜
```

变更说明由 `scripts/changelog.sh`（与 `tag` 共用）从 Conventional Commits 生成，**必须在打 tag 前展示给用户过目**——注记正文推送后不可修改。生成后**立刻落盘冻结**，后续不再重新生成（否则步骤 2 的 CHANGELOG 合并提交会混进正文，与 `CHANGELOG.md` 也对不上）。正文拆两份：

```bash
BODY="$(mktemp)"       # 纯变更说明：tag 注记正文 + Release body
TAG_MSG="$(mktemp)"    # tag 注记：首行 release: <tag> + 空行 + BODY
bash scripts/changelog.sh --from "${LATEST_TAG}" --to "${BASE_REF}" --link-to "${TARGET_TAG}" > "$BODY"
if [ -s "$BODY" ]; then
  { echo "release: ${TARGET_TAG}"; echo; cat "$BODY"; } > "$TAG_MSG"
else
  # 无用户可感知变更：正文仍要有一行，Release body 才不会为空
  printf 'release: %s\n' "${TARGET_TAG}" | tee "$TAG_MSG" > "$BODY"
fi
cat "$BODY"            # 作为计划卡正文展示；决策走下面的选项
```

首个版本去掉 `--from`。**`--link-to` 不可省**：`--to` 是 `origin/main` 这类远端跟踪名，直接塞进 compare 链接会得到 404；`--link-to` 指向即将打的 tag，推送后链接即有效。compare 链接按平台生成（GitHub/Gitea `/compare/`、GitLab `/-/compare/`；平台未知则不生成链接）。

计划卡只是**告知**（版本源、tag、sha、注记正文、Release 计划、探测到的其他后效）。紧接着必须**把这一阶段所有待决事项并进同一次选项式提问**（`references/ask-options.md`）——不要打印完计划卡就停下来等用户回一句「可以」。长内容留在计划卡正文里，选项只写短标签 + 后果：

| STATE / 能力 | 同一次提问里的题 | 选项（推荐项在前） |
|---|---|---|
| `READY` 且 Release 可自动创建 | ① 是否按此发版（tag + Release） | `按此发版（tag + Release）`（推荐）/ `只打 tag，不建 Release` / `取消` / `改 tag 名或说明` |
| `READY` 但 Release 无法自动创建 | ① 同上 | `按此发版（tag，附手动创建命令）`（推荐）/ `停止，先处理 CLI/登录` / `取消` / `改 tag 名或说明` |
| `READY` | ② 是否写 `CHANGELOG.md` | `不写，直接打 tag`（推荐，零副作用）/ `写，并走一次分支 + PR` |
| `NEEDS_TAG` | 目标 tag | `v0.1.0`（推荐，首个版本）/ `v1.0.0` / `自定义` |
| `TAGGED` | 无需提问（只补建/校验 Release + 跟踪，重跑幂等） | — |

- `EFFECT_RELEASE=workflow` 时**不问也不建**：由仓库 CI 创建，本流程只校验 notes 非空；若流水失败导致 Release 缺失，在步骤 4 跟踪完再给「补建」选项（见 4.1）。
- 第 ② 题选「写」才进步骤 2；选「不写」则全程不碰工作区。
- **不再有「Release 谁创建」这一题**：默认由本流程创建，只有无法创建时才在题面写明手动命令。

`BLOCKED` 时同样不是「逐条说明就结束」，而是按 `BLOCKERS` 给选项：

| `BLOCKERS` | 选项（推荐项在前） |
|---|---|
| `version-not-ahead-of-tag` | `升 patch 到 <下一版>`（推荐）/ `升 minor 到 <y>` / `升 major 到 <z>` / `只跟踪现有 tag，不发新版本` |
| `tag-not-on-base` | `停止`（推荐）/ `授权删 tag 重打`（不可逆：正文与目标 sha 都无法改） |
| `tag-version-mismatch` | `先升版本到 <tag 版本>`（推荐）/ `改用清单版本 <PKG_VERSION> 作 tag` / `停止` |

除「只跟踪现有 tag」外，升版本都要走 `commit-push` → `pr-create` → `pr-merge`，合并后重新预检（**本流程不改版本号**）。

用户选完后**不再中途询问**；后续唯一会再提问的场合是步骤 4 出现失败/超时（见 4.1/4.3/4.4）。

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

   确认 `STATE` 仍为 `READY`、`TAG_EXISTS=no`、`CHANGELOG_HAS_VERSION=yes`（记录已在主干上），再进步骤 3。**注意：主干前移不影响已确认的正文**——步骤 3 仍用步骤 1 那份 `${TAG_MSG}` / `${BODY}`，不重新生成（重新生成会把刚合入的 `docs(changelog)` 提交算进正文）。

失败即停：CHANGELOG PR 没合进来之前**不打 tag**。已打 tag 才发现漏记 → 不改 tag，改为在下一个版本补记，或经用户明确授权后删 tag 重打（见「失败与重跑」）。

### 3. 打 tag

按 `references/tag.md`：注记 tag、指向 `<BASE_REF>` 最新提交、推送前核对版本一致。**注记正文用步骤 1 已让用户确认的 `${TAG_MSG}`**（首行 `release: <tag>` + 空行 + `${BODY}`）：

```bash
git fetch ${REMOTE} --tags
git tag -a --cleanup=verbatim "${TARGET_TAG}" -F "$TAG_MSG" "${BASE_REF}"
git push ${REMOTE} "${TARGET_TAG}"
echo "TAG_PUSH_OK"
```

**`--cleanup=verbatim` 不可省**：`git tag -F` 默认按 `strip` 清理，会把 `### Features` 这类以 `#` 开头的行当注释整行删掉（`changelog.sh` 输出的正是 Markdown 小标题，已在临时仓库复现）。少了这个参数，注记正文会丢结构，即使正文文件本身完好。

`STATE=TAGGED` 时不重复打，直接进步骤 4。若这次是重跑、本会话没有 `${BODY}`，先按步骤 1 的命令现生成一份（`--to` 用当前的 `BASE_REF`，不需要 `TAG_MSG`），否则 Release body 会是空的。

### 4. 创建/校验 Release，再跟踪其他后效

#### 4.1 Release（默认交付物）

先按状态决定动作，再执行：

| 条件 | 动作 |
|---|---|
| `RELEASE_EXISTS=yes` | **只校验**：读取 tag/body，确认 notes 非空；不覆盖、不 update |
| `EFFECT_RELEASE=workflow` | 先不建；等 4.3/4.4 的流水结束后校验；缺失时给「补建」选项 |
| `EFFECT_RELEASE=none` + 平台 ∈ {github,gitlab} + `RELEASE_CLI_READY=yes` +（`READY` 或 `TAGGED` 且 `RELEASE_EXISTS=no`） | **创建** |
| `TAGGED` + `RELEASE_EXISTS=unknown` | 不建（标签可能存在人工补过的 Release）；回执标「状态未知」+ 手动命令 |
| 平台未知 / Gitea / CLI 缺失或未登录 | 不建；回执写原因 + 手动命令 |
| 用户选了「只打 tag」 | 不建；回执记 `⏭ 已跳过（用户选择）` |

**创建前必须先确认 tag 已在远端**——两个 CLI 都有「tag 不存在就从默认分支自动造一个轻量 tag」的行为，越过这一步会悄悄毁掉注记 tag：

```bash
# 0) tag 必须在远端；没有就停，不进入创建
git ls-remote --tags "${REMOTE}" "${TARGET_TAG}" | grep -q . || echo "TAG_MISSING_ON_REMOTE"
```

GitHub：

```bash
# 已存在 → 只校验；不存在 → 创建（--verify-tag 双保险）
if gh release view "${TARGET_TAG}" --repo "${REPO_ID}" >/dev/null 2>&1; then
  RELEASE_ACTION=exists
else
  if [ "${RELEASE_PRERELEASE}" = yes ]; then
    gh release create "${TARGET_TAG}" --repo "${REPO_ID}" --verify-tag \
      --prerelease --title "${TARGET_TAG}" --notes-file "$BODY"
  else
    gh release create "${TARGET_TAG}" --repo "${REPO_ID}" --verify-tag \
      --title "${TARGET_TAG}" --notes-file "$BODY"
  fi
  RELEASE_ACTION=created
fi
# 回读：notes 必须非空
gh release view "${TARGET_TAG}" --repo "${REPO_ID}" --json tagName,url,body \
  --jq '{tag:.tagName,url:.url,body_len:(.body|length)}'
```

GitLab（`glab release create` 对已存在的 Release 是**更新**语义，所以必须先 view 判存在，避免覆盖人工补的 notes）：

```bash
if glab release view "${TARGET_TAG}" -R "${REPO_ID}" >/dev/null 2>&1; then
  RELEASE_ACTION=exists
else
  glab release create "${TARGET_TAG}" -R "${REPO_ID}" \
    --name "${TARGET_TAG}" --notes-file "$BODY"
  RELEASE_ACTION=created
fi
# 回读（文本即可；确认 tag 与 notes 非空）
glab release view "${TARGET_TAG}" -R "${REPO_ID}"
```

- GitLab 没有预发布标记：`RELEASE_PRERELEASE=yes` 时照建，回执注明「GitLab 无 prerelease 概念」，不伪造标记。
- 自建实例带端口时，`gh`/`glab` 可能不认 `${REPO_ID}` 的 `HOST:PORT/...` 形式：仅当 `${REMOTE}` 是 `origin` 时，先在仓库目录内省略 `--repo`/`-R` 重试；仍不行就按「无法自动创建」处理，不猜 API。
- **创建失败不重试、不删已有 Release**：记录 `RELEASE_ACTION=failed` 与原始报错，回执标 ⚠️，给选项 `只报告`（推荐）/ `重试` / `跳过`。tag 已推送是既成事实，Release 失败不改变它。
- `EFFECT_RELEASE=workflow` 但流水失败/未建 Release：在 4.2/4.3 跟踪完之后给选项 `由本流程补建 Release`（推荐）/ `只报告`；选补建时仍走上面的创建命令（用 `${BODY}`）。
- 无法自动创建时，在回执里给可复制命令：
  - GitHub：`gh release create "<tag>" --verify-tag --title "<tag>" --notes-file <正文文件>`
  - GitLab：`glab release create "<tag>" --name "<tag>" --notes-file <正文文件>`
  - Gitea/未知平台：在网页上创建，不猜 API。

#### 4.2 一次校验（推荐：`release-verify.sh`）

Release 建好/校验后，用一条命令把流水、Release、npm 三件事一次做完（对应 4.3–4.5），**一次出 KEY=VALUE 回执**。首次查询立即执行；流水一到终态就停，不做固定轮次空转。

```bash
bash scripts/release-verify.sh \
  --platform "${RELEASE_PLATFORM}" \
  --tag "${TARGET_TAG}" \
  --repo "${REPO_ID}" \
  --timeout 180 --interval 5
# 只有 EFFECT_NPM=yes 时才加：--npm-pkg "${PKG_NAME}"
# GitHub 已知 run id 时加 --run-id <id>；GitLab 已知 pipeline 时加 --pipeline <id>
```

- 默认 `--timeout 180`（3 分钟）、`--interval 5`（5 秒）；不再固定 15 秒轮询 10 分钟。GitHub 优先 `gh run watch <id> --exit-status`，结束即返回；GitLab 没有 watch 等价物，按 5 秒轮询。
- `--no-ci` / `--no-release` / `--no-npm` 可单项跳过；不传 `--npm-pkg` 时 npm 记 `skipped`（不猜包名），所以只在 `EFFECT_NPM=yes` 时传。
- 自动发现取该 tag 最近一次 run（`--workflow` 可限定）；仓库有多个 tag workflow 时，逐个 workflow 各跑一次，或分别传 `--run-id`。
- 退出码：`0` 全部通过 / `2` 有失败项 / `3` 有查不了的项 / `1` 参数或环境错误。`VERIFY_RESULT` 与 `VERIFY_REASONS` 给出结论。
- **脚本只读**：Release 只 `view`，不创建、不改 notes；npm 只读 registry；不改 tag。创建/补建仍走 4.1。
- stdout 只有 `KEY=VALUE`，进度与诊断走 stderr；可直接贴进步骤 5 的回执。

回执字段：

| KEY | 取值 |
|---|---|
| `VERIFY_PLATFORM` / `VERIFY_TAG` / `VERIFY_REPO` | 平台 / tag / repo-id |
| `CI_STATUS` | `success` / `failure` / `timeout` / `missing` / `unknown` / `skipped` |
| `CI_CONCLUSION` / `CI_ID` / `CI_URL` / `CI_WORKFLOW` / `CI_DURATION_S` | 流水细节；GitLab 的 `CI_CONCLUSION` 即 pipeline `status` |
| `RELEASE_STATUS` | `exists` / `missing` / `unknown` / `skipped` |
| `RELEASE_TAG` / `RELEASE_URL` / `RELEASE_NOTES_LEN` / `RELEASE_NOTES` | Release 细节；`RELEASE_NOTES=empty` 视为失败 |
| `NPM_PKG` / `NPM_VERSION` / `NPM_STATUS` / `NPM_SOURCE` | npm 结果；`NPM_SOURCE=registry` 优先，失败回退 `npm-cli` |
| `VERIFY_RESULT` / `VERIFY_REASONS` | `pass` / `fail` / `unknown`；原因用逗号分隔 |

`RELEASE_STATUS=missing` 时回到 4.1 的「补建」选项；`CI_STATUS=missing` 只表示没查到 tag 触发的 run，**不判成功**。脚本不可用（缺少 `gh`/`glab`、未登录、自建 host）时按 4.3–4.5 手工执行，结论仍保持成功 / 失败 / 未知三档。

离线回归：`bash scripts/tests/release-verify-test.sh`（用桩代替 `gh`/`glab`/`curl`/`npm`，覆盖两平台成功、失败、watch、回退与降级路径）。

#### 4.3 GitHub workflow 跟踪

对 `TAG_WORKFLOWS` 里的**每一个** workflow：先**立即**查一次，按 `headBranch == <TARGET_TAG>` 匹配最近一次 run；拿到 run id 后优先 `gh run watch --exit-status`，结束即返回。

```bash
# 首次立即查（<TARGET_TAG> 替换成实际 tag）
gh run list --branch "${TARGET_TAG}" --limit 20 \
  --json databaseId,headBranch,status,conclusion,url,workflowName \
  --jq 'map(select(.headBranch == "<TARGET_TAG>")) | .[0] | select(. != null) | [.databaseId, .status, .conclusion, .url, .workflowName] | @tsv'

# 已知 run id：watch 到结束；--exit-status 在失败时返回非 0
gh run watch <id> --repo "${REPO_ID}" --exit-status --interval 5
```

`gh run watch` 不可用/报错时，退化为每 **5 秒**一次 `gh run view <id> --json status,conclusion,url,workflowName`，总预算 **3 分钟**（`--timeout 180`），到点即停。逐个给结论：

| workflow 结论 | 报告 |
|---|---|
| `success` | ✅ 耗时 t |
| `failure` | ❌ 给 run 链接与失败步骤 |
| 超时未结束 | ⏳ 给 run 链接与当前状态 |
| 匹配不到 run | ⚠️ 说明「该 workflow 未见 tag 触发记录」，不判成功 |

首次查询立即执行；流水结束即返回，不轮满固定次数。

出现 `failure` / 超时 / 匹配不到 run 时，报告完给**一题选项**（`references/ask-options.md`）：`只报告`（推荐）/ `gh run rerun <id>`（仅 failure）/ `下个版本再发`。不自行 rerun，也不因为「重跑一下可能就好了」替用户决定。

#### 4.4 GitLab pipeline 跟踪

`GITLAB_TAG_CI=yes`（`.gitlab-ci.yml` 由 `CI_COMMIT_TAG` 触发）时：首次立即查，之后每 **5 秒**一次，总预算 **3 分钟**。`glab` 没有 `gh run watch` 的等价命令（1.121 实测 `glab ci list` 无 watch 参数），只能轮询。

```bash
glab ci list --ref "${TARGET_TAG}" -R "${REPO_ID}" --output json --per-page 20 \
  --jq '[.[] | select(.ref == "<TARGET_TAG>")] | .[0] | select(. != null) | {id, status, web_url, duration}'
```

用 `--jq` 直接解析 JSON（取 `id` / `status` / `web_url` / `duration`），不要拿文本表格再 `grep`。超时到点即停，给当前 `status`，不判成功。

| status | 报告 |
|---|---|
| `success` | ✅ 耗时 t |
| `failed` / `canceled` | ❌ 给 pipeline 链接 |
| `running` / `pending` / `created` / `waiting_for_resource` / `preparing` | ⏳ 每 5 秒重查、最多 3 分钟 |
| `skipped` / `manual` | ⏭ 如实说明，不判成功 |
| 查不到任何 pipeline | ⚠️ 「未见 tag 触发的 pipeline」，不判成功 |

失败/超时/查不到时给选项：`只报告`（推荐）/ `下个版本再发`（不做 `glab` 重跑）。

`GITLAB_TAG_CI=no` 时报告「本仓未检测到 tag 触发的 GitLab CI 流水」，不猜。

#### 4.5 npm 与其他产物

- `EFFECT_NPM=yes`：**优先 registry 单版本端点**（HTTP 状态即可判定，通常约 1 秒）：

  ```bash
  NAME_ENC="$(printf '%s' "${PKG_NAME}" | sed 's#/#%2F#g')"   # @scope/name → @scope%2Fname
  curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    "https://registry.npmjs.org/${NAME_ENC}/${PKG_VERSION}"
  ```

  `200` → 可见；`404` → 不可见；其他状态/网络错误 → 回退 `npm` CLI：

  ```bash
  npm view "${PKG_NAME}@${PKG_VERSION}" version \
    --registry https://registry.npmjs.org --cache "$(mktemp -d)"
  ```

  **`--cache` 不可省**：本机 `~/.npm` 可能被 root 占用（EPERM），那不是「版本不存在」，不能误判成 `no`。回退仍失败记 `unknown`。
- npm 结论三档：可见 / 不可见 / 查不了（查不了既不算失败也不算成功）。
- `EFFECT_RELEASE` 已在 4.1 校验，不重复
- 两者皆 `none` 且 `TAG_WORKFLOWS=<none>`、`GITLAB_TAG_CI=no`：明确写「本仓未检测到 tag 触发的发布流水；tag 与 Release 即交付物」，不做任何成功断言
- 镜像 / 文档站 / 部署：未探测到就写「未检测到」；确需跟踪时用选项问「继续（推荐）/ 指定产物与校验方式」，不猜

GitHub 之外的平台不会出现 `gh run list`：GitLab 走 4.4；Gitea/未知平台明确写「流水状态未知」，并给选项 `继续按可得信息出回执`（推荐）/ `停止，人工核对后再跑`。

### 5. 回执

```
✅ release v1.1.0（tag 已推送）
  tag       v1.1.0 → 3f9c2a1（main 上）              ✅
  Release   GitHub v1.1.0                            ✅ 已创建（notes 复用 tag 正文）
  workflow  release.yml                              ✅ success 2m13s
  npm       @morehao/dsh-commands@1.1.0              ✅ 可见
  changelog CHANGELOG.md                             ✅ 已记录 v1.1.0
```

回执里的 workflow / Release / npm 三行直接取 4.2 脚本的 `CI_STATUS`、`RELEASE_STATUS`、`NPM_STATUS`（细节用 `CI_DURATION_S` / `RELEASE_URL` / `NPM_SOURCE` / `VERIFY_REASONS`），不必再手工拼。

Release 行的其他形态，各自独立、不合并成一句「发布成功」：

| 情形 | 回执 |
|---|---|
| 已存在 | `✅ 已存在（未覆盖）` |
| 由 CI 创建 | `✅ 由 release.yml 创建` |
| 用户选择只打 tag | `⏭ 已跳过（用户选择）` |
| CLI 缺失/未登录/平台未知 | `⚠️ 未创建（<原因>）` + 手动命令 |
| 状态未知（`TAGGED` 且查不了） | `⚠️ 状态未知（无法确认是否已存在）` + 手动命令 |
| 创建失败 | `❌ 创建失败：<原始报错>` |

任一 ❌ 时回执顶部改成 `⚠️` 并列出失败项；每个后效独立一行、独立结论。

## 失败与重跑

| 情况 | 处理 |
|---|---|
| workflow / pipeline 失败 | **不删 tag 重打**（tag 不可变）；给链接 + 选项 `只报告`（推荐）/ 重跑（仅 GitHub）/ 下个版本 |
| 仍在跑 | 可中止；重跑本流程会从 `TAGGED` 继续跟踪，不会重复打 tag |
| 已全部通过 | 重跑同样给出一致回执（幂等；Release 已存在则只校验） |
| `TAGGED` + Release 缺失 | **补建**（默认，幂等）；补建前仍要先确认 tag 在远端 |
| `TAGGED` + Release 状态未知 | 不建；报告 + 手动命令，避免覆盖人工补的 notes |
| Release 创建失败 | 不重试、不删；⚠️ + 原始报错 + 选项 `只报告`（推荐）/ `重试` / `跳过` |
| CI 声称会建 Release 但缺失 | 跟踪完给选项 `由本流程补建 Release`（推荐）/ `只报告` |
| 平台未知 / CLI 缺失 / 未登录 | 不建；打 tag 照常完成，回执给手动命令与选项 `停止，先处理 CLI/登录`（仅 READY 阶段） |
| 版本没领先 tag | `STATE=BLOCKED`，给选项 `升 patch`（推荐）/ `升 minor` / `升 major` / `只跟踪现有 tag`，再走升版本 PR |
| tag 不在主干 | `STATE=BLOCKED` + `BLOCKERS=tag-not-on-base`，多为打错分支；给选项 `停止`（推荐）/ `授权删 tag 重打`（不可逆） |
| `--tag` 与清单版本不一致 | `STATE=BLOCKED` + `BLOCKERS=tag-version-mismatch`，给选项 `先升版本到 <tag 版本>`（推荐）/ `改用清单版本作 tag` / `停止`，**不静默改 tag 目标** |
| 无清单且无 `--tag` | `STATE=NEEDS_TAG`，用选项索取目标 tag（`v0.1.0` / `v1.0.0` / 自定义） |
| CHANGELOG PR 未合并 | 停：不打 tag。先合并 PR 再重新预检（否则 tag 指向的提交没有这条记录） |
| CHANGELOG 已含该版本 | `changelog.sh` 退出码 3，视为完成，不重复写、不重复开 PR |
| 打完 tag 才发现漏记 | 不改 tag；记到下一个版本，或经用户明确授权后删 tag 重打 |

## 边界

- **不做**：改 `package.json`、改代码、删 tag、重打 tag、force push、删 Release、改 Release notes（用户明确要求补 notes 时先问）、`npm` 撤销发布（只能 `deprecate`）、改 workflow、代跑发布脚本
- **两个远端写操作**：推送 tag + 创建 Release。后者只由 4.1 的默认规则触发，不额外越界
- **唯一越界写文件**：用户在选择里明确要写 `CHANGELOG.md` 时，会建**一个** `docs/changelog-<tag>` 分支并走一次 `pr-create` → `pr-merge`。不选则完全不碰工作区；除 `CHANGELOG.md` 外不改任何文件，且必须合进稳定分支后才打 tag
- **不假设**：不内置任何"发版必须发 npm"的判断；npm 只是探测到才校验的一个后效。也不假设"Release 一定由 CI 建"或"一定由本流程建"——按探测结果与用户选择
- **不替代**：`tag`（任意分支打标签）、`pr-merge`（合并本身）

## 验收标准

- 远端存在 `<TARGET_TAG>`，且 `git merge-base --is-ancestor <TARGET_TAG> <BASE_REF>` 成立
- 版本源为 manifest 时：`<BASE_REF>` 的 `package.json.version == <TARGET_TAG>`（去 `v`）
- tag 注记非空且含变更说明（`git for-each-ref --format='%(contents)' refs/tags/<tag>` 可读），首行为 `release: <tag>`
- Release 项有明确结论：已创建 / 已存在 / 由 CI 创建 / 用户跳过 / 无法创建（含原因与手动命令）/ 创建失败；**已创建或已存在时 notes 非空**
- 每个探测到的后效都有独立结论（成功 / 失败 / 未知），没有一个被静默跳过
- 每个需要用户决定的场合都落成了**带选项的提问**（含推荐项与自定义兜底），没有开放式追问、没有「打印现状等人回复」
- 未探测到的后效在回执里显式标注「未检测到」，不说成「无后效」或「已发布」
- 选了写 CHANGELOG 时：合并后重新预检 `CHANGELOG_HAS_VERSION=yes`，且 tag 指向**合并之后**的 `<BASE_REF>`
- 任一步失败 → 停在当前状态，报告「STATE + 已做/未做 + 下一条命令」，不伪造成功
