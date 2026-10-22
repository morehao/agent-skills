# tag 分支：基于分支打版本标签并推送

给选定分支的**远端最新提交**打注记 tag（annotated）并推送到远端。不切换分支、不修改工作区。仓库尚无 tag 时如实报告并走「首个版本」流程。

## 执行流程

1. **目标仓库**：同 pr-create/pr-merge，优先 `upstream`，回退 `origin`；`git remote get-url <目标仓库>` 确认存在可访问
2. **拉取最新**：`git fetch <目标仓库> --tags`（分支与 tag 都要最新）
3. **探测最新 tag 与来源分支**：
   - 最新 tag：`git tag --sort=-v:refname | head -1`（按版本号取最高）；tag 非版本号命名时退化为 `git tag --sort=-creatordate | head -1`（最近创建）
   - 来源分支：`git log -1 --format='%h %s' <tag>` 看 tag 指向的提交；`git branch -r --contains <tag>` 看哪些远端分支包含它，优先展示与 tag 提交同步（HEAD 指向同一提交）的分支，无则展示全部包含它的分支
   - **无 tag** → 如实报告「仓库尚无 tag」，按下方「无 tag」规则继续
4. **候选分支（让用户选）**：
   - 稳定分支优先：按 `references/stable-branch.md` 的**唯一定义**（主干/集成分支、发布/稳定/维护分支、版本线分支）。此处是**偏好而非禁止**——非稳定分支若比最新 tag 更新也照常列入候选
   - 其余：`<目标仓库>/<branch>` 中 `git log <latest-tag>..<目标仓库>/<branch>` 有提交的分支（比最新 tag 新、值得打 tag）；无 tag 时列出全部远端分支
   - 展示编号让用户选（1/2/3…），也允许用户直接输入分支名；**用选项式提问呈现**（`references/ask-options.md`），不要只列编号等用户回一句话
5. **候选 tag（让用户选）**：
   - **先核对发布包版本**：读发布包的 `package.json` 的 `version`（本仓 `commands-dsh/package.json`），候选 tag 须与其一致，详见下方「发版约束」
   - 有最新 tag 且为 semver（`v?X.Y.Z`）：按递增档提议 3 个候选 patch/minor/major（如 `v1.2.3` → `v1.2.4` / `v1.3.0` / `v2.0.0`），沿用现有 tag 的 `v` 前缀风格
   - **无 tag**：提议首个版本 `v0.1.0` 与 `v1.0.0`（默认 `v` 前缀）
   - 选择含 `release` 的分支且分支名带版本号时，候选 tag 优先从分支名推断（如 `release/2.0.0`、`release-v2.0` → `v2.0.0`），作为第 1 个候选
   - 用户可选候选或自定义（如 `v1.3.0-beta.1`）
   - **校验不冲突**：`git tag -l <tag>` 与 `git ls-remote --tags <目标仓库> <tag>` 均须无输出；冲突则提示换名，不覆盖已有 tag
6. **生成注记正文并确认**：用 `scripts/changelog.sh`（与 `release` 共用同一实现）从上一个 tag 汇总变更，作为注记正文。下文用 `PREV_TAG`（上一个 tag；首个 tag 时为空）、`REMOTE`、`BRANCH`、`TAG` 指代已确认的值：

   ```bash
   bash scripts/changelog.sh --from "${PREV_TAG}" --to "${REMOTE}/${BRANCH}" --link-to "${TAG}"   # 首个 tag 省略 --from
   ```

   `--link-to` 让 compare 链接右端指向**即将打的 tag**；`--to` 是 `origin/main` 这类远端跟踪名，直接塞进链接会得到 404。

   展示 `<tag>` @ `<branch>` @ `<sha> <subject>` **和完整注记正文**让用户确认——tag 一旦推送就不能改正文，必须在推送前定稿。用户可改写、精简，或只要首行 `release: <tag>`。若还要把变更写进 `CHANGELOG.md`，那是 `release` 分支的可选动作（本分支不写文件）。
7. **构建并推送**（同一 bash 链式，防半途）：

   ```bash
   NOTES="$(mktemp)"
   { echo "release: ${TAG}"; echo; bash scripts/changelog.sh --from "${PREV_TAG}" --to "${REMOTE}/${BRANCH}" --link-to "${TAG}"; } > "$NOTES"
   git fetch ${REMOTE} --tags && git tag -a "${TAG}" -F "$NOTES" "${REMOTE}/${BRANCH}" && git push ${REMOTE} "${TAG}" && echo "TAG_PUSH_OK"
   ```
8. **验证**：输出出现 `TAG_PUSH_OK`，且 `git ls-remote --tags <目标仓库> <tag>` 与本地 `git tag -l <tag>` 均可见

## 发版约束（目标仓库的 `v*` tag 会触发发布时必读）

若打了 `v*` tag 会触发发布工作流（本仓：`.github/workflows/release.yml` → `scripts/ci-publish.sh`），打 tag 前必须先对齐版本号：

- **硬守卫**：tag 版本（去掉 `v` 前缀）必须等于发布包 `package.json` 的 `version`（本仓 `commands-dsh/package.json`），否则发布脚本直接 `exit 1` 拒绝发布。不一致的 tag **不会误发**，但会白占一个 tag 名 + 留一条失败 run（tag 已推送，改名须删除重打）。
- **顺序**：候选 tag 与当前版本不一致时 → **先升版本**：改 `package.json` 的 `version` → 走 `commit-push`（起点是稳定分支时自动建分支）→ 走 `pr-create` 建 PR → 合并 `main`，**合并后**才在本流程打 tag（tag 指向 `main` 的最新提交，即含升版本的那次合并提交）。完整手册见 `PUBLISHING.md`「日常发新版」。
- 升版本提交**不得**直接落在稳定分支上——发版不构成例外（`references/stable-branch.md`）。
- **不得**为绕过守卫擅自打不一致的 tag；用户明确要求「只打 tag、不管发布」时才照办，并在报告中写明发布工作流预期会失败。
- 幂等：npmjs 已存在该版本 → 工作流跳过（exit 0），重复打 tag 不会重复发布。

## 注意事项

- 只打**注记 tag**（`-a` 带消息/作者/日期）；轻量 tag 无这些信息，不适合发版
- 注记正文是「这版改了什么」的唯一机读载体，由 `scripts/changelog.sh` 从 Conventional Commits 汇总，**推送前必须确认**（tag 不可改）
- tag 指向 `<目标仓库>/<branch>` 的远端最新提交，不受本地分支状态影响
- 打 tag 不改任何文件/提交，**不切换当前分支**，无需工作区干净
- tag 已存在（本地或远端）→ 停并报告，`git tag` 默认拒绝覆盖、`git push` 也会被拒，不伪造成功

## 验收标准

- 本地与远端均可见新 tag，输出 `TAG_PUSH_OK`
- 未真正创建/推送（只列候选/只给文字）即失败，继续执行
- 任一步报错（网络/权限/tag 冲突/分支不存在）→ 停并完整报告原始报错，不伪造成功
- 当前分支与工作区保持不变（打 tag 不改文件；升版本属前置的 `commit-push` + `pr-create` 流程，不在本分支内做）
- 有发布工作流时：tag 版本 == 发布包 `package.json` 版本，或有用户明确的「只打 tag 不发布」授权（见「发版约束」）
