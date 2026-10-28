# checkout-tag 分支：切换到当前仓库的最新 tag

把工作区切到本仓库的**目标 tag**：用户**指定了 tag 名就切那个**，没指定则切**最新 tag**（默认按版本号取最高，非 semver 时退化为最近创建）。这是**只读浏览/对齐版本**的操作：默认切到 `<tag>` 的 **detached HEAD**，**不新建分支、不提交、不推送**。若要基于该 tag 继续开发，需由用户确认后另建分支（见步骤 5）。

## 执行流程

1. **定位目标仓库**：默认就是当前仓库（`git rev-parse --show-toplevel`）。读取远端 `git remote -v` 找到可用的远端（优先 `upstream`，其次 `origin`），用于步骤 2 拉取最新 tag；无远端时只用本地已有 tag，并在报告里注明「未 fetch，tag 可能不是最新」。
2. **拉取最新 tag**：`git fetch <远端> --tags`（成功后再选 tag；失败则如实报告，退回用本地 tag）。
3. **确定目标 tag**（用户指定优先）：
   - **用户指定了 tag 名** → 切那个。先校验存在性（步骤 2 已 fetch）：
     ```bash
     git rev-parse -q --verify "refs/tags/<指定tag>" >/dev/null \
       || git ls-remote --tags "<远端>" "refs/tags/<指定tag>" | grep -q . \
       && echo "TAG_EXISTS" || echo "TAG_MISSING"
     ```
     - `TAG_MISSING`（本地和远端都没有）→ **停**，报告「tag `<指定tag>` 不存在」，并列出最近 5 个可用 tag（`git tag --sort=-v:refname | head -5`）供用户改选，**不静默失败、不自行换成最新 tag**。
     - 本地没有但远端有 → 先 `git fetch <远端> "refs/tags/<指定tag>:refs/tags/<指定tag>"` 拉下来再切。
     - **不擅自改写/猜测 tag 名**（如补 `v` 前缀）；不确定就停并列出候选。
   - **未指定**（无参数）→ 探测最新 tag：
     - 主判定：`git tag --sort=-v:refname | head -1`（按版本号取最高）
     - 若最新 tag 不是 semver 形状（`v?X.Y.Z`），改用 `git tag --sort=-creatordate | head -1`（最近创建）
     - **无 tag** → 如实报告「仓库尚无 tag」，结束，不切任何东西。
   - 展示选定 tag 及 `git log -1 --format='%h %s' <tag>` 指向的提交。
4. **冲突预检（不擅自丢弃本地改动）**：
   - `git status --porcelain` 非空（工作区/暂存区有改动）→ **停**，如实报告有未提交改动，用选项式提问（`references/ask-options.md`）让用户决定：
     - `stash 后切换（推荐）` / `直接切换（git 有冲突会失败，改动保留）` / `取消`
     - 选 `stash` 时执行 `git stash push -u -m "git-kit checkout-tag"` 再切；报告里给出恢复命令 `git stash pop`。
   - 已在目标 tag 的 detached HEAD 上（`git describe --tags --exact-match HEAD` 等于该 tag）→ 直接报告「已在该 tag」，无需切换。
5. **切换**：
   - 默认：`git switch --detach <tag>`（或 `git checkout --detach <tag>`），detached HEAD 只读浏览。
   - 若用户明确说「要基于这个 tag 开发/改东西」→ 用选项式提问选分支名（默认候选 `<tag>` 清理后的 `release/<tag>` 或用户自定），`git switch -c <新分支> <tag>`；**不替用户决定**，用户没要求就保持 detached。
6. **验证**：输出出现 `CHECKOUT_OK`，且 `git describe --tags --exact-match HEAD` 等于目标 tag、`git rev-parse --short HEAD` 与步骤 3 展示的提交一致。

## 注意事项

- 优先用 tag 名切，不用裸 sha，避免「看着是 tag 其实是随手切的提交」。
- **用户指定的 tag 不存在就停**，列出候选让用户改选；不静默切到最新 tag，也不擅自补前缀猜名字。
- **不删 tag、不改 tag、不打新 tag**：本分支只做「切过去」。要打标签走 `tag` 分支，要发布走 `release` 分支。
- 工作区有未提交改动时**绝不 `git checkout -f` / `git switch --discard-changes`**，必须走 stash 或让用户取消。
- 子模块/稀疏检出等特殊仓库若 `git switch` 报错 → 停并完整报告原始报错，不伪造成功。
- 只切换当前本地仓库；这是本地只读动作，**不 push、不 fetch 分支**，不影响远端。

## 验收标准

- 输出 `CHECKOUT_OK`，`git describe --tags --exact-match HEAD` 为选定的 tag（用户指定的或探测到的最新 tag）
- 未真正切换（只列 tag / 只给文字）即失败，继续执行
- 用户指定的 tag 不存在时如实报告并列出候选，不静默改用最新 tag
- 有未提交改动但未经用户确认就被改动/丢弃 → 失败
- 任一步报错（fetch 失败、无 tag、切到一半失败）→ 停并完整报告原始报错，不伪造成功
- 默认结束时处于目标 tag 的 detached HEAD（或用户明确要求时的新分支），不擅自新建分支/提交/推送
