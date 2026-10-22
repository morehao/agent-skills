#!/usr/bin/env bash
# 远端 URL 解析：host / repo-id / 平台判定的**唯一真源**。
# release-preflight.sh 与 changelog.sh 共用；`references/repo-id.md` 描述的就是这里的规则。
#
# 只做纯文本解析，不联网、不读 git 配置、不退出：
# 解析不出来就返回空串，由调用方决定降级（RELEASE_PLATFORM=unknown / 不生成链接）。
#
# 支持的形式：
#   git@github.com:owner/repo.git
#   https://github.com/owner/repo.git
#   ssh://git@gitlab.com/group/sub/repo.git
#   https://gitlab.example.com:8443/group/sub/repo.git（自建 + 端口）
#   git@gitlab.example.com:group/sub/repo.git（scp-like）
#   /srv/git/repo.git / file:///srv/git/repo.git（本地远端 → host 为空）
#
# bash 3.2 兼容（macOS 自带）：不用 mapfile / 关联数组 / ${var,,}。

# 把任意远端 URL 归一化成 `host[:port]/path`（无 scheme、无 user@、无 .git 后缀、无首斜杠）。
_git_remote_norm() {
  local url="${1:-}"
  url="${url%.git}"
  case "$url" in
    *://*)
      url="${url#*://}"
      case "$url" in *@*) url="${url#*@}" ;; esac
      ;;
    *@*) url="${url#*@}" ;;
  esac
  # scp-like `host:path` 与带端口的 `host:8443/path` 都含冒号
  case "$url" in
    *:*)
      local head="${url%%:*}" rest="${url#*:}"
      case "$rest" in
        [0-9]*/*)
          # 端口形式：head 是 host，rest 的首段是端口
          _GIT_REMOTE_HOST="${head}:${rest%%/*}"
          _GIT_REMOTE_PATH="${rest#*/}"
          ;;
        *)
          _GIT_REMOTE_HOST="$head"
          _GIT_REMOTE_PATH="$rest"
          ;;
      esac
      ;;
    */*)
      _GIT_REMOTE_HOST="${url%%/*}"
      _GIT_REMOTE_PATH="${url#*/}"
      ;;
    *)
      _GIT_REMOTE_HOST=""
      _GIT_REMOTE_PATH=""
      ;;
  esac
  # 去掉 path 首尾斜杠、折叠重复斜杠（本地绝对路径会以 / 开头）
  while :; do
    case "$_GIT_REMOTE_PATH" in
      /*) _GIT_REMOTE_PATH="${_GIT_REMOTE_PATH#/}" ;;
      *) break ;;
    esac
  done
  _GIT_REMOTE_PATH="$(printf '%s' "$_GIT_REMOTE_PATH" | sed 's#//*#/#g; s#/$##')"
  _GIT_REMOTE_HOST="$(printf '%s' "$_GIT_REMOTE_HOST" | tr '[:upper:]' '[:lower:]')"
}

# host（小写、含端口时保留）。本地路径 / 无法识别 → 空串。
git_remote_host() {
  _git_remote_norm "${1:-}"
  printf '%s' "$_GIT_REMOTE_HOST"
}

# path（owner/repo；GitLab 子组保留为 group/sub/repo）。本地路径 / 无法识别 → 空串。
git_remote_path() {
  _git_remote_norm "${1:-}"
  printf '%s' "$_GIT_REMOTE_PATH"
}

# `<repo-id>`：`[HOST/]OWNER[/NAMESPACE]/REPO`，直接喂 gh --repo / glab -R。
# 本地路径（无 host）退化为纯 path，调用方应优先省略仓库参数。
git_remote_slug() {
  _git_remote_norm "${1:-}"
  if [ -n "$_GIT_REMOTE_HOST" ] && [ -n "$_GIT_REMOTE_PATH" ]; then
    printf '%s/%s' "$_GIT_REMOTE_HOST" "$_GIT_REMOTE_PATH"
  else
    printf '%s' "$_GIT_REMOTE_PATH"
  fi
}

# 平台判定。只认域名特征，不猜自建服务的真实产品：
#   github.com / *.github.com / *.github.* / github.* → github（自定义域名的 Enterprise 会落到 unknown，用 --platform 覆盖）
#   gitlab.com / *.gitlab.com / *.gitlab.* / gitlab.* → gitlab
#   gitea.* / gogs.* → gitea
#   其余 → unknown（不猜测，宁可让流程问用户）
git_remote_platform() {
  local host
  host="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$host" in
    '') printf 'unknown' ;;
    github.com|*.github.com|*.github.*|github.*) printf 'github' ;;
    gitlab.com|*.gitlab.com|*.gitlab.*|gitlab.*) printf 'gitlab' ;;
    gitea.*|*.gitea.*|gogs.*|*.gogs.*) printf 'gitea' ;;
    *) printf 'unknown' ;;
  esac
}
