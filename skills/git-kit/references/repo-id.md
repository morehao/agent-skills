# 仓库标识 `<repo-id>`（pr-create / pr-merge 共用）

**远端名只喂 `git`，不喂 `gh`/`glab`。** `gh --repo` 与 `glab -R` 都只接受 `[HOST/]OWNER/[NAMESPACE/]REPO` 形式的**仓库标识**，把 `origin`/`upstream` 这类**远端名**直接传过去会被拒绝：

```
expected the "[HOST/]OWNER/REPO" format, got "origin"                    # gh
Expected the "[HOST/]OWNER/[NAMESPACE/]REPO" format, got "origin".       # glab
```

`gh repo view <远端名>` 更隐蔽：它不报格式错，而是把远端名当**仓库名**去查（`gh repo view origin` → `Could not resolve to a Repository with the name 'morehao/origin'`），看起来像「仓库不存在」，容易误判成权限或网络问题。

## 解析 `<repo-id>`

**唯一实现是 `scripts/lib/remote.sh`**（`git_remote_host` / `git_remote_path` / `git_remote_slug` / `git_remote_platform`），`release-preflight.sh` 与 `changelog.sh` 都 source 它；本文只描述规则，不要在别处再写一套正则。

一次解析，供后续所有 gh/glab 命令复用（`<目标仓库>` 是远端名，如 `origin`/`upstream`）：

```bash
git remote get-url <目标仓库> | sed -E 's#^git@([^:]+):#\1/#; s#^ssh://git@([^/]+)/#\1/#; s#^https?://([^/]+)/#\1/#; s#\.git$##'
```

| 远端 URL | `<repo-id>` |
|---------|------------|
| `git@github.com:morehao/ai-kit.git` | `github.com/morehao/ai-kit` |
| `https://github.com/morehao/ai-kit.git` | `github.com/morehao/ai-kit` |
| `ssh://git@gitlab.com/group/sub/repo.git` | `gitlab.com/group/sub/repo`（子组保留） |

- 用 `git config --get remote.<目标仓库>.url` 交叉确认；存在多个 pushurl 时以 fetch url 为准
- 自建主机带端口（`host:8443/...`）若 CLI 不认，改用不依赖 `--repo` 的路径：默认分支走 `git remote show <目标仓库>` 的 `HEAD branch`（或 `git ls-remote --symref <目标仓库> HEAD`），PR/MR 命令则在仓库目录内省略仓库参数

## 用哪个

| 场景 | gh | glab |
|------|----|------|
| `<目标仓库>` == `origin`（非 fork） | **省略 `--repo`** | **省略 `-R`** |
| `<目标仓库>` == `upstream`（fork，目标为上游） | `--repo <repo-id>` | `-R <repo-id>` |

- 非 fork 时**优先省略**：CLI 会从当前目录的 `origin` 推导，且能顺带避开 host 判别歧义（自建 GitLab / 多 host 时尤其明显）。省略与显式传 `<repo-id>` 等价，需要点名某个具体仓库的单条命令（如 `gh repo view`）显式传也正确
- fork 时**必须显式传**：cwd 推导出的是 fork 自己，不是作为 base 的上游仓库
