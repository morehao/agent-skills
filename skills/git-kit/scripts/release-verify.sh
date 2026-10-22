#!/usr/bin/env bash
# release 发布后校验（一次出回执）：等流水 → 验 Release → 验 npm。
#
# 用途：tag 推送、Release 建好/校验之后，把「等 CI + 验 Release + 验 npm」收成一条命令。
# 首次查询立即执行；流水一到终态就停，不做固定 15s × 40 轮的空转。
#
# 只读：不改 tag、不创建/修改 Release、不写仓库文件；npm 只读 registry。
# 创建/补建 Release 仍由 release.md 4.1 负责，本脚本只校验。
#
# 平台（--platform 不给时按远端 URL 判定，规则见 scripts/lib/remote.sh）：
#   github  gh run list/view/watch + gh release view
#   gitlab  glab ci list 轮询（glab 无 watch 等价物）+ glab release view
#   其他    gitea / unknown 不猜 API，CI 与 Release 记 unknown 并给出原因
#
# 退出码：0 全部通过 / 2 有失败项 / 3 有无法判定项（未知）/ 1 参数或环境错误。
# stdout 只有 KEY=VALUE，可直接作为回执；诊断信息只走 stderr。
#
# bash 3.2 兼容（macOS 自带）：不用 mapfile / 关联数组 / ${var,,}。

set -euo pipefail

usage() {
  cat <<'EOF'
用法: bash release-verify.sh --tag <vX.Y.Z> [选项]
  --tag <tag>          要校验的 tag（必需）
  --platform <p>       github|gitlab|gitea|unknown；默认按远端 URL 判定
  --repo <id>          [HOST/]OWNER[/NAMESPACE]/REPO；默认从远端解析
  --remote <名>        解析 repo-id 用的远端（默认 upstream → origin）
  --run-id <id>        GitHub run id；不给则按 tag 查最近一次
  --pipeline <id>      GitLab pipeline id；不给则按 ref 查最近一条
  --workflow <file>    GitHub 只看指定 workflow
  --timeout <秒>       等流水上限（默认 180）
  --interval <秒>      轮询间隔（默认 5）
  --npm-pkg <name>     要校验的 npm 包名；不给则 NPM_STATUS=skipped
  --npm-version <ver>  默认取 tag 去掉前缀 v
  --npm-registry <url> 默认 https://registry.npmjs.org
  --no-ci              跳过流水等待
  --no-release         跳过 Release 校验
  --no-npm             跳过 npm 校验
  -h, --help
EOF
}

die() { echo "错误：$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/remote.sh
. "${SCRIPT_DIR}/lib/remote.sh"

TAG=""
PLATFORM_OVERRIDE=""
REPO_OVERRIDE=""
REMOTE=""
RUN_ID=""
PIPELINE_ID=""
WORKFLOW=""
TIMEOUT=180
INTERVAL=5
NPM_PKG=""
NPM_VERSION=""
NPM_REGISTRY="https://registry.npmjs.org"
DO_CI=1
DO_RELEASE=1
DO_NPM=1

need() { [ $# -ge 2 ] || die "$1 需要一个值"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) need "$@"; TAG="$2"; shift 2 ;;
    --platform) need "$@"; PLATFORM_OVERRIDE="$2"; shift 2 ;;
    --repo) need "$@"; REPO_OVERRIDE="$2"; shift 2 ;;
    --remote) need "$@"; REMOTE="$2"; shift 2 ;;
    --run-id) need "$@"; RUN_ID="$2"; shift 2 ;;
    --pipeline) need "$@"; PIPELINE_ID="$2"; shift 2 ;;
    --workflow) need "$@"; WORKFLOW="$2"; shift 2 ;;
    --timeout) need "$@"; TIMEOUT="$2"; shift 2 ;;
    --interval) need "$@"; INTERVAL="$2"; shift 2 ;;
    --npm-pkg) need "$@"; NPM_PKG="$2"; shift 2 ;;
    --npm-version) need "$@"; NPM_VERSION="$2"; shift 2 ;;
    --npm-registry) need "$@"; NPM_REGISTRY="$2"; shift 2 ;;
    --no-ci) DO_CI=0; shift ;;
    --no-release) DO_RELEASE=0; shift ;;
    --no-npm) DO_NPM=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数 $1（-h 查看用法）" ;;
  esac
done

[ -n "$TAG" ] || die "--tag 必需（例如 v1.2.3；-h 查看用法）"

# 预检输出用 <none> 表示「没有」；直接复制过来时按空值处理，避免拿 <none> 去查 API。
case "$REPO_OVERRIDE" in '<none>') REPO_OVERRIDE="" ;; esac
case "$WORKFLOW" in '<none>') WORKFLOW="" ;; esac
case "$RUN_ID" in '<none>') RUN_ID="" ;; esac
case "$PIPELINE_ID" in '<none>') PIPELINE_ID="" ;; esac
case "$NPM_PKG" in '<none>') NPM_PKG="" ;; esac
case "$NPM_VERSION" in '<none>') NPM_VERSION="" ;; esac
case "$TIMEOUT" in ''|*[!0-9]*|0) die "--timeout 必须是正整数（当前：${TIMEOUT}）" ;; esac
case "$INTERVAL" in ''|*[!0-9]*|0) die "--interval 必须是正整数（当前：${INTERVAL}）" ;; esac
case "$PLATFORM_OVERRIDE" in
  ''|github|gitlab|gitea|unknown) ;;
  *) die "--platform 只接受 github|gitlab|gitea|unknown（当前：${PLATFORM_OVERRIDE}）" ;;
esac
if [ -n "$PIPELINE_ID" ]; then
  case "$PIPELINE_ID" in *[!0-9]*) die "--pipeline 必须是数字（当前：${PIPELINE_ID}）" ;; esac
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "当前目录不在 git 仓库内"
cd "$ROOT"

TMP_DIR="$(mktemp -d 2>/dev/null || true)"
[ -n "$TMP_DIR" ] || die "无法创建临时目录"
cleanup() { [ -d "${TMP_DIR:-}" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

SEP="$(printf '\037')"

# ---------- 平台 / repo-id / CLI ----------
if [ -z "$REMOTE" ]; then
  if git remote get-url upstream >/dev/null 2>&1; then REMOTE=upstream; else REMOTE=origin; fi
fi
REMOTE_URL=""
if git remote get-url "$REMOTE" >/dev/null 2>&1; then
  REMOTE_URL="$(git remote get-url "$REMOTE")"
fi
HOST="$(git_remote_host "$REMOTE_URL")"
if [ -n "$REPO_OVERRIDE" ]; then
  REPO_ID="$REPO_OVERRIDE"
else
  REPO_ID="$(git_remote_slug "$REMOTE_URL")"
fi
if [ -n "$PLATFORM_OVERRIDE" ]; then
  PLATFORM="$PLATFORM_OVERRIDE"
else
  PLATFORM="$(git_remote_platform "$HOST")"
fi

REPO_PATH=""
if [ -n "$REMOTE_URL" ]; then REPO_PATH="$(git_remote_path "$REMOTE_URL")"; fi
if [ -z "$REPO_PATH" ] && [ -n "$REPO_ID" ]; then
  if [ -n "$HOST" ]; then
    case "$REPO_ID" in
      "$HOST"/*) REPO_PATH="${REPO_ID#"$HOST"/}" ;;
      *) REPO_PATH="$REPO_ID" ;;
    esac
  else
    REPO_PATH="$REPO_ID"
  fi
fi

CLI=none
case "$PLATFORM" in
  github) if command -v gh >/dev/null 2>&1; then CLI=gh; fi ;;
  gitlab) if command -v glab >/dev/null 2>&1; then CLI=glab; fi ;;
esac

[ -n "$NPM_VERSION" ] || NPM_VERSION="${TAG#v}"
NPM_REGISTRY="$(printf '%s' "$NPM_REGISTRY" | sed 's#/*$##')"

# 无法调用 API 的统一前置原因；按检查项各自落成 unknown，不互相污染。
BLOCK_REASON=""
if [ "$PLATFORM" = unknown ] || [ "$PLATFORM" = gitea ]; then
  BLOCK_REASON=platform-unsupported
elif [ -z "$REPO_ID" ]; then
  BLOCK_REASON=no-repo-id
elif [ "$CLI" = none ]; then
  BLOCK_REASON=cli-missing
fi

# ---------- 回执字段与原因聚合 ----------
CI_STATUS=skipped
CI_CONCLUSION="<none>"
CI_ID="<none>"
CI_URL="<none>"
CI_WORKFLOW="<none>"
CI_DURATION_S=unknown
RELEASE_STATUS=skipped
RELEASE_TAG="<none>"
RELEASE_URL="<none>"
RELEASE_NOTES_LEN=unknown
RELEASE_NOTES=unknown
NPM_STATUS=skipped
NPM_SOURCE=none
REASONS=""

add_reason() {
  local r="$1"
  [ -n "$r" ] || return 0
  case ",${REASONS}," in
    *",${r},"*) return 0 ;;
  esac
  if [ -z "$REASONS" ]; then REASONS="$r"; else REASONS="${REASONS},${r}"; fi
}

# ---------- 时间 / 超时 ----------
iso_epoch() {
  [ -n "${1:-}" ] || return 1
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null && return 0
  date -u -d "$1" +%s 2>/dev/null
}

duration_from() {
  local a b
  a="$(iso_epoch "${1:-}" 2>/dev/null || true)"
  b="$(iso_epoch "${2:-}" 2>/dev/null || true)"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$b" -ge "$a" ]; then
    printf '%s' "$((b - a))"
  else
    printf 'unknown'
  fi
}

# macOS 没有 timeout(1)：自己计秒，超时先 TERM 再 KILL。
run_with_timeout() {
  local secs="$1" pid waited
  shift
  [ "$secs" -gt 0 ] || return 124
  "$@" &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

jq_str() { printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ---------- GitHub ----------
GH_ERR=""
GH_STATUS=""
GH_CONCLUSION=""
GH_URL=""
GH_WORKFLOW=""
GH_CREATED=""
GH_UPDATED=""

gh_fetch_run() {
  local out
  if out="$(gh run view "$RUN_ID" --repo "$REPO_ID" \
      --json status,conclusion,url,workflowName,createdAt,updatedAt \
      --jq '[.status, (.conclusion // ""), (.url // ""), (.workflowName // ""), (.createdAt // ""), (.updatedAt // "")] | join("\u001f")' 2>&1)"; then
    IFS="$SEP" read -r GH_STATUS GH_CONCLUSION GH_URL GH_WORKFLOW GH_CREATED GH_UPDATED <<EOF || true
$out
EOF
    return 0
  fi
  GH_ERR="$out"
  return 1
}

gh_discover_run() {
  local jq_tag expr out
  jq_tag="$(jq_str "$TAG")"
  expr="map(select(.headBranch == \"${jq_tag}\")) | .[0] | select(. != null) | [.databaseId, .status, .conclusion, .url, .workflowName] | map(tostring) | join(\"\u001f\")"
  if [ -n "$WORKFLOW" ]; then
    if ! out="$(gh run list --workflow "$WORKFLOW" --branch "$TAG" --limit 20 \
        --json databaseId,headBranch,status,conclusion,url,workflowName --jq "$expr" 2>&1)"; then
      GH_ERR="$out"; return 1
    fi
  else
    if ! out="$(gh run list --branch "$TAG" --limit 20 \
        --json databaseId,headBranch,status,conclusion,url,workflowName --jq "$expr" 2>&1)"; then
      GH_ERR="$out"; return 1
    fi
  fi
  [ -n "$out" ] || return 0
  IFS="$SEP" read -r RUN_ID GH_STATUS GH_CONCLUSION GH_URL GH_WORKFLOW <<EOF || true
$out
EOF
  return 0
}

gh_classify() {
  if [ "$GH_STATUS" = "completed" ]; then
    if [ "$GH_CONCLUSION" = "success" ]; then
      CI_STATUS=success
    else
      CI_STATUS=failure
      add_reason ci-failure
    fi
  else
    CI_STATUS=running
  fi
}

ci_github() {
  local deadline now remaining
  if [ -z "$RUN_ID" ]; then
    if ! gh_discover_run; then
      case "$GH_ERR" in
        *"command not found"*) add_reason cli-missing ;;
        *auth*|*Auth*|*login*|*Login*|*401*|*403*) add_reason ci-auth ;;
        *"not found"*|*"Not Found"*|*404*) add_reason ci-missing ;;
        *) add_reason ci-query-failed ;;
      esac
      CI_STATUS=unknown
      return
    fi
  fi
  if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "null" ]; then
    CI_STATUS=missing
    add_reason ci-missing
    return
  fi
  CI_ID="$RUN_ID"

  if ! gh_fetch_run; then
    case "$GH_ERR" in
      *"command not found"*) add_reason cli-missing ;;
      *auth*|*Auth*|*login*|*Login*|*401*|*403*) add_reason ci-auth ;;
      *) add_reason ci-query-failed ;;
    esac
    CI_STATUS=unknown
    return
  fi
  CI_WORKFLOW="${GH_WORKFLOW:-<none>}"
  CI_URL="${GH_URL:-<none>}"

  deadline=$(( $(date +%s) + TIMEOUT ))
  gh_classify

  if [ "$CI_STATUS" = running ]; then
    now="$(date +%s)"
    remaining=$((deadline - now))
    if [ "$remaining" -gt 0 ]; then
      # 优先 watch（结束即返回）；不支持/报错时下面的轮询兜底。
      set +e
      run_with_timeout "$remaining" gh run watch "$RUN_ID" --repo "$REPO_ID" \
        --interval "$INTERVAL" --exit-status >/dev/null 2>&1
      set -e
      if ! gh_fetch_run; then
        CI_STATUS=unknown
        add_reason ci-query-failed
      else
        gh_classify
      fi
    fi
  fi

  while [ "$CI_STATUS" = running ]; do
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      CI_STATUS=timeout
      add_reason ci-timeout
      break
    fi
    sleep "$INTERVAL"
    if ! gh_fetch_run; then
      CI_STATUS=unknown
      add_reason ci-query-failed
      break
    fi
    gh_classify
  done

  if [ "$CI_STATUS" = success ] || [ "$CI_STATUS" = failure ]; then
    CI_CONCLUSION="${GH_CONCLUSION:-<none>}"
    CI_DURATION_S="$(duration_from "$GH_CREATED" "$GH_UPDATED")"
  elif [ "$CI_STATUS" = timeout ]; then
    CI_CONCLUSION="${GH_STATUS:-running}"
  fi
}

# ---------- GitLab ----------
GL_ERR=""
GL_EMPTY=no
GL_ID=""
GL_STATUS=""
GL_URL=""
GL_DURATION=""
GL_REF=""
GL_EXPR=""

gl_fetch() {
  local out
  GL_EMPTY=no
  if out="$(glab ci list --ref "$TAG" -R "$REPO_ID" --output json --jq "$GL_EXPR" 2>&1)"; then
    if [ -z "$out" ]; then
      GL_EMPTY=yes
      return 0
    fi
    IFS="$SEP" read -r GL_ID GL_STATUS GL_URL GL_DURATION GL_REF <<EOF || true
$out
EOF
    return 0
  fi
  GL_ERR="$out"
  return 1
}

gl_classify() {
  case "$GL_STATUS" in
    success) CI_STATUS=success ;;
    failed|canceled) CI_STATUS=failure; add_reason ci-failure ;;
    skipped|manual) CI_STATUS=skipped; add_reason "ci-${GL_STATUS}" ;;
    running|pending|created|waiting_for_resource|preparing|scheduled|waiting) CI_STATUS=running ;;
    *) CI_STATUS=unknown; add_reason ci-unknown ;;
  esac
}

ci_gitlab() {
  local deadline now
  if [ -n "$PIPELINE_ID" ]; then
    GL_EXPR="[.[] | select(.id == ${PIPELINE_ID})] | .[0] | select(. != null) | [.id, .status, (.web_url // \"\"), ((.duration // \"\") | tostring), (.ref // \"\")] | map(tostring) | join(\"\u001f\")"
  else
    GL_EXPR="[.[] | select(.ref == \"$(jq_str "$TAG")\")] | .[0] | select(. != null) | [.id, .status, (.web_url // \"\"), ((.duration // \"\") | tostring), (.ref // \"\")] | map(tostring) | join(\"\u001f\")"
  fi

  if ! gl_fetch; then
    case "$GL_ERR" in
      *"command not found"*) add_reason cli-missing ;;
      *auth*|*Auth*|*login*|*Login*|*401*|*403*) add_reason ci-auth ;;
      *) add_reason ci-query-failed ;;
    esac
    CI_STATUS=unknown
    return
  fi
  if [ "$GL_EMPTY" = yes ]; then
    CI_STATUS=missing
    add_reason ci-missing
    return
  fi

  CI_ID="${GL_ID:-<none>}"
  CI_URL="${GL_URL:-<none>}"
  CI_CONCLUSION="${GL_STATUS:-<none>}"
  CI_DURATION_S="${GL_DURATION:-unknown}"
  [ -n "$CI_DURATION_S" ] || CI_DURATION_S=unknown

  deadline=$(( $(date +%s) + TIMEOUT ))
  gl_classify

  while [ "$CI_STATUS" = running ]; do
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      CI_STATUS=timeout
      add_reason ci-timeout
      break
    fi
    sleep "$INTERVAL"
    if ! gl_fetch; then
      CI_STATUS=unknown
      add_reason ci-query-failed
      break
    fi
    if [ "$GL_EMPTY" = yes ]; then
      CI_STATUS=missing
      add_reason ci-missing
      break
    fi
    CI_CONCLUSION="${GL_STATUS:-<none>}"
    gl_classify
  done
}

# ---------- Release ----------
classify_release_err() {
  case "$1" in
    *"command not found"*) RELEASE_STATUS=unknown; add_reason cli-missing ;;
    *"not found"*|*"Not Found"*|*404*) RELEASE_STATUS=missing; add_reason release-missing ;;
    *auth*|*Auth*|*login*|*Login*|*401*|*403*) RELEASE_STATUS=unknown; add_reason release-auth ;;
    *) RELEASE_STATUS=unknown; add_reason release-query-failed ;;
  esac
}

release_notes_check() {
  case "$RELEASE_NOTES_LEN" in ''|*[!0-9]*) RELEASE_NOTES_LEN=0 ;; esac
  if [ "$RELEASE_NOTES_LEN" -gt 0 ]; then
    RELEASE_NOTES=nonempty
  else
    RELEASE_NOTES=empty
    add_reason release-notes-empty
  fi
}

verify_release_gh() {
  local out rc
  set +e
  out="$(gh release view "$TAG" --repo "$REPO_ID" \
    --json tagName,url,body,isDraft,isPrerelease \
    --jq '[.tagName, (.url // ""), ((.body // "") | length)] | map(tostring) | join("\u001f")' 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    RELEASE_STATUS=exists
    IFS="$SEP" read -r RELEASE_TAG RELEASE_URL RELEASE_NOTES_LEN <<EOF || true
$out
EOF
    RELEASE_TAG="${RELEASE_TAG:-$TAG}"
    RELEASE_URL="${RELEASE_URL:-<none>}"
  else
    classify_release_err "$out"
  fi
}

verify_release_gl() {
  local out rc
  set +e
  out="$(glab release view "$TAG" -R "$REPO_ID" --output json \
    --jq '[.tag_name, (.name // ""), ((.description // "") | length)] | map(tostring) | join("\u001f")' 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    RELEASE_STATUS=exists
    IFS="$SEP" read -r RELEASE_TAG REL_NAME RELEASE_NOTES_LEN <<EOF || true
$out
EOF
    [ -n "$REL_NAME" ] || true
    RELEASE_TAG="${RELEASE_TAG:-$TAG}"
    if [ -n "$HOST" ] && [ -n "$REPO_PATH" ]; then
      RELEASE_URL="https://${HOST}/${REPO_PATH}/-/releases/${TAG}"
    else
      RELEASE_URL="<none>"
    fi
  else
    classify_release_err "$out"
  fi
}

# ---------- npm ----------
npm_fallback() {
  local cache out rc
  if ! command -v npm >/dev/null 2>&1; then
    NPM_STATUS=unknown
    NPM_SOURCE=none
    add_reason npm-unknown
    return
  fi
  cache="${TMP_DIR}/npm-cache"
  mkdir -p "$cache"
  set +e
  out="$(npm view "${NPM_PKG}@${NPM_VERSION}" version --registry "$NPM_REGISTRY" --cache "$cache" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    NPM_STATUS=visible
    NPM_SOURCE=npm-cli
  else
    case "$out" in
      *E404*|*"404 Not Found"*|*"404 No match"*) NPM_STATUS=missing; NPM_SOURCE=npm-cli; add_reason npm-missing ;;
      *) NPM_STATUS=unknown; NPM_SOURCE=npm-cli; add_reason npm-unknown ;;
    esac
  fi
}

verify_npm() {
  local enc url body code rc
  if [ -z "$NPM_PKG" ] || [ -z "$NPM_VERSION" ]; then
    NPM_STATUS=skipped
    return
  fi
  enc="$(printf '%s' "$NPM_PKG" | sed 's#/#%2F#g')"
  url="${NPM_REGISTRY}/${enc}/${NPM_VERSION}"
  body="${TMP_DIR}/npm-body.json"

  if command -v curl >/dev/null 2>&1; then
    set +e
    code="$(curl -sS --max-time 10 -o "$body" -w '%{http_code}' "$url" 2>/dev/null)"
    rc=$?
    set -e
    code="${code:-000}"
    if [ "$rc" -eq 0 ] && [ "$code" = "200" ] && grep -q '"version"' "$body" 2>/dev/null; then
      NPM_STATUS=visible
      NPM_SOURCE=registry
      return
    fi
    if [ "$rc" -eq 0 ] && [ "$code" = "404" ]; then
      NPM_STATUS=missing
      NPM_SOURCE=registry
      add_reason npm-missing
      return
    fi
  fi
  # 网络/5xx/非 npmjs registry 的缓存问题：回退到 npm CLI，且用隔离缓存。
  npm_fallback
}

# ---------- 执行 ----------
if [ "$DO_CI" -eq 1 ]; then
  if [ -n "$BLOCK_REASON" ]; then
    CI_STATUS=unknown
    add_reason "$BLOCK_REASON"
  else
    if [ "$PLATFORM" = github ]; then ci_github; else ci_gitlab; fi
  fi
fi

if [ "$DO_RELEASE" -eq 1 ]; then
  if [ -n "$BLOCK_REASON" ]; then
    RELEASE_STATUS=unknown
    add_reason "$BLOCK_REASON"
  else
    if [ "$PLATFORM" = github ]; then verify_release_gh; else verify_release_gl; fi
    if [ "$RELEASE_STATUS" = exists ]; then
      release_notes_check
      if [ "$RELEASE_TAG" != "$TAG" ]; then add_reason release-tag-mismatch; fi
    fi
  fi
fi

if [ "$DO_NPM" -eq 1 ]; then
  verify_npm
fi

# ---------- 结论 ----------
VERIFY_RESULT=pass
if [ "$CI_STATUS" = failure ] || [ "$CI_STATUS" = timeout ]; then
  VERIFY_RESULT=fail
elif [ "$CI_STATUS" = missing ] || [ "$CI_STATUS" = unknown ]; then
  VERIFY_RESULT=unknown
elif [ "$CI_STATUS" = skipped ] && [ "$DO_CI" -eq 1 ]; then
  # pipeline 的 skipped/manual 不是成功；显式 --no-ci 的 skipped 才算通过
  VERIFY_RESULT=unknown
fi

if [ "$RELEASE_STATUS" = missing ]; then
  VERIFY_RESULT=fail
elif [ "$RELEASE_STATUS" = unknown ] && [ "$VERIFY_RESULT" != fail ]; then
  VERIFY_RESULT=unknown
fi

if [ "$RELEASE_NOTES" = empty ]; then VERIFY_RESULT=fail; fi
case ",${REASONS}," in
  *",release-tag-mismatch,"*) VERIFY_RESULT=fail ;;
esac

if [ "$NPM_STATUS" = missing ]; then
  VERIFY_RESULT=fail
elif [ "$NPM_STATUS" = unknown ] && [ "$VERIFY_RESULT" != fail ]; then
  VERIFY_RESULT=unknown
fi

# ---------- 回执（stdout 只有 KEY=VALUE） ----------
echo "VERIFY_PLATFORM=${PLATFORM}"
echo "VERIFY_TAG=${TAG}"
echo "VERIFY_REPO=${REPO_ID:-<none>}"
echo "CI_STATUS=${CI_STATUS}"
echo "CI_CONCLUSION=${CI_CONCLUSION:-<none>}"
echo "CI_ID=${CI_ID:-<none>}"
echo "CI_URL=${CI_URL:-<none>}"
echo "CI_WORKFLOW=${CI_WORKFLOW:-<none>}"
echo "CI_DURATION_S=${CI_DURATION_S:-unknown}"
echo "RELEASE_STATUS=${RELEASE_STATUS}"
echo "RELEASE_TAG=${RELEASE_TAG:-<none>}"
echo "RELEASE_URL=${RELEASE_URL:-<none>}"
echo "RELEASE_NOTES_LEN=${RELEASE_NOTES_LEN}"
echo "RELEASE_NOTES=${RELEASE_NOTES}"
echo "NPM_PKG=${NPM_PKG:-<none>}"
echo "NPM_VERSION=${NPM_VERSION:-<none>}"
echo "NPM_STATUS=${NPM_STATUS}"
echo "NPM_SOURCE=${NPM_SOURCE}"
echo "VERIFY_RESULT=${VERIFY_RESULT}"
echo "VERIFY_REASONS=${REASONS:-none}"

if [ "$VERIFY_RESULT" = pass ]; then exit 0; fi
if [ "$VERIFY_RESULT" = fail ]; then exit 2; fi
exit 3
