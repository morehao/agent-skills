#!/usr/bin/env bash
# release 预检（只读）：pr-merge 之后的发布段所需事实。
#
# 起点假设：版本号已经随 PR 合并进稳定分支，工作由「打 tag → 创建/校验 Release → 跟踪发布后效」构成。
#
# 分工原则（本脚本的边界）：
#   - 判断归调用方（skill/模型）：哪个文件是版本源、这版该发什么号、workflow 发布到哪，
#     都由读仓库的人给出。脚本**不内置任何生态知识**（不认 package.json/Cargo.toml/pyproject…）；
#     主流约定的例子见 references/version-conventions.md。
#   - 事实归脚本：远端/平台/CLI、稳定分支、tag 序列与命名样式、CI 触发信号、CHANGELOG、提交统计、
#     Release 存在性。这些与语言无关，且必须可回归。
#   - 校验用通用手段：声明版本是否在该文件里（边界匹配 + 回报行号）、版本是否领先最新 tag（纯 tag 比较）。
#     不解析任何清单格式，也不需要 node/python/jq。
#
# 输入（至少给一个，否则 STATE=NEEDS_TARGET）：
#   --version <v> [--version-file <路径>]   声明「本版版本是 v，它写在这个文件里」
#   --tag <tag>                             直接指定目标 tag（tag 即版本源；裸版本号会补上仓库前缀）
#
# 版本声明只是**可选证据**：「没有字面版本」是一等公民（Go 的 ldflags 注入、Python 的 setuptools-scm、
# Maven 的 ${revision}）。所以回查失败默认只 WARN；仓库确实「字面常量 + CI 硬校验」时才加
# --require-version-match 升为阻断。
#
# 不写文件、不切分支、不打 tag、不创建 Release。默认 fetch 远端分支与 tag；
# Release 存在性查询需要 gh/glab 已登录，查不了记 unknown（不是「不存在」）。
#
# 只读探测仓库是否维护 CHANGELOG（不写）：决定计划卡是否询问「要不要记录变更」。
#
# 退出码：0 可继续 / 2 有阻断项 / 1 环境或参数错误。
#
# bash 3.2 兼容（macOS 自带）：不用 mapfile / 关联数组 / ${var,,}。

set -euo pipefail

usage() {
  cat <<'EOF'
用法: bash release-preflight.sh [选项]
  --version <v>            声明本版版本号（1.2.3 / v1.2.3 / 1.2.3+45 均可）
  --version-file <路径>     版本源文件（仓内相对路径）；给了就回查该文件在 BASE_REF 里是否含该版本
  --tag <tag>              目标 tag；不给 --version 时它本身就是版本源（裸 1.2.3 会补上仓库前缀）
  --require-version-match  回查失败时阻断（用于「tag 版本必须等于清单版本，否则 CI 拒发」的仓库）
  --changelog <路径>        指定 CHANGELOG 文件（默认探测常见文件名）
  --remote <名>             目标远端（默认 upstream → 回退 origin）
  --no-fetch               跳过 fetch
  --no-release-check       跳过远端 Release 存在性查询（RELEASE_EXISTS=unknown）
  --platform <p>           覆盖平台判定：github|gitlab|gitea|unknown（自建域名/夹具用）
  -h, --help
EOF
}

die() { echo "错误：$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/remote.sh
. "${SCRIPT_DIR}/lib/remote.sh"

REMOTE=""
EXPLICIT_VERSION=""
VERSION_FILE=""
EXPLICIT_TAG=""
CHANGELOG_OVERRIDE=""
PLATFORM_OVERRIDE=""
REQUIRE_MATCH=0
DO_FETCH=1
DO_RELEASE_CHECK=1

while [ $# -gt 0 ]; do
  case "$1" in
    --remote) REMOTE="${2:-}"; shift 2 ;;
    --version) EXPLICIT_VERSION="${2:-}"; shift 2 ;;
    --version-file) VERSION_FILE="${2:-}"; shift 2 ;;
    --tag) EXPLICIT_TAG="${2:-}"; shift 2 ;;
    --require-version-match) REQUIRE_MATCH=1; shift ;;
    --changelog) CHANGELOG_OVERRIDE="${2:-}"; shift 2 ;;
    --platform) PLATFORM_OVERRIDE="${2:-}"; shift 2 ;;
    --no-fetch) DO_FETCH=0; shift ;;
    --no-release-check) DO_RELEASE_CHECK=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数 $1（-h 查看用法）" ;;
  esac
done

case "$PLATFORM_OVERRIDE" in
  ''|github|gitlab|gitea|unknown) ;;
  *) die "--platform 只接受 github|gitlab|gitea|unknown（当前：${PLATFORM_OVERRIDE}）" ;;
esac

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "当前目录不在 git 仓库内"
cd "$ROOT"

# --version-file 必须是仓内相对路径（绝对路径与 ../ 一律拒绝，避免回查到仓库外）。
if [ -n "$VERSION_FILE" ]; then
  case "$VERSION_FILE" in
    /*) die "--version-file 必须是仓内相对路径（当前：${VERSION_FILE}）" ;;
    ..|../*|*/../*|*/..) die "--version-file 不能跳出仓库（当前：${VERSION_FILE}）" ;;
    ./*) VERSION_FILE="${VERSION_FILE#./}" ;;
  esac
fi

# ---------- 远端与稳定分支 ----------
if [ -z "$REMOTE" ]; then
  if git remote get-url upstream >/dev/null 2>&1; then REMOTE=upstream; else REMOTE=origin; fi
fi
git remote get-url "$REMOTE" >/dev/null 2>&1 || die "远端 ${REMOTE} 不存在（release 需要可推送的远端）"

# ---------- 平台与 Release 能力（host 解析的唯一真源：scripts/lib/remote.sh） ----------
REMOTE_URL="$(git remote get-url "$REMOTE")"
HOST="$(git_remote_host "$REMOTE_URL")"
if [ -n "$HOST" ]; then
  REPO_ID="$(git_remote_slug "$REMOTE_URL")"
else
  # 本地/无 host 远端没有 repo-id（gh/glab 都喂不了），留空由调用方降级。
  REPO_ID=""
fi
if [ -n "$PLATFORM_OVERRIDE" ]; then
  RELEASE_PLATFORM="$PLATFORM_OVERRIDE"
else
  RELEASE_PLATFORM="$(git_remote_platform "$HOST")"
fi

# 按平台选 CLI，不跨平台混用：GitHub 只认 gh、GitLab 只认 glab。
RELEASE_CLI=none
case "$RELEASE_PLATFORM" in
  github) if command -v gh >/dev/null 2>&1; then RELEASE_CLI=gh; fi ;;
  gitlab) if command -v glab >/dev/null 2>&1; then RELEASE_CLI=glab; fi ;;
esac

# 认证状态决定「能否查询/创建 Release」；查不了记 unknown，不当成「不存在」。
RELEASE_CLI_READY=no
if [ "$RELEASE_CLI" = gh ]; then
  if gh auth status --hostname "$HOST" >/dev/null 2>&1; then RELEASE_CLI_READY=yes; fi
elif [ "$RELEASE_CLI" = glab ]; then
  if glab auth status --hostname "$HOST" >/dev/null 2>&1; then RELEASE_CLI_READY=yes; fi
fi

if [ "$DO_FETCH" -eq 1 ]; then
  git fetch --quiet "$REMOTE" --tags --prune || die "fetch ${REMOTE} 失败（网络/权限），可加 --no-fetch 用本地引用继续"
fi

BASE=""
BASE="$(git symbolic-ref -q "refs/remotes/${REMOTE}/HEAD" 2>/dev/null | sed "s#^refs/remotes/${REMOTE}/##")" || true
if [ -z "$BASE" ]; then
  if git rev-parse --verify -q "${REMOTE}/main" >/dev/null; then BASE=main
  elif git rev-parse --verify -q "${REMOTE}/master" >/dev/null; then BASE=master
  else die "无法确定默认分支（${REMOTE}/HEAD 不存在，且无 main/master）"
  fi
fi
BASE_REF="${REMOTE}/${BASE}"
git rev-parse --verify -q "$BASE_REF" >/dev/null || die "${BASE_REF} 不存在"

# ---------- tag 形状：只从 tag 自身推断，不预设任何版本方案 ----------
# version_core_of <tag>：取 tag 里的版本内核（数字段 + 可选 -pre/+build），至少要有 X.Y 两段。
#   v1.2.3 → 1.2.3 ; demo-1.0.0 → 1.0.0 ; sub/v1.2.3 → 1.2.3 ; 1.2.3+45 → 1.2.3+45 ; nightly-2026-10-01 → 空
version_core_of() {
  printf '%s' "${1:-}" | awk '
    {
      s = $0
      sub(/^[^0-9]*/, "", s)
      if (match(s, /^[0-9][0-9]*(\.[0-9][0-9]*)+([-+][0-9A-Za-z][-0-9A-Za-z.]*)?/))
        printf "%s", substr(s, 1, RLENGTH)
    }'
}

# tag_prefix_of <tag>：数字段之前的一切（v / demo- / sub/v / core-v / 空）。不猜新样式。
tag_prefix_of() {
  printf '%s' "${1:-}" | awk '{ sub(/[0-9].*$/, ""); printf "%s", $0 }'
}

# is_version_core <core>：去掉 -pre/+build 后必须是「数字.数字…」且至少一个点。
is_version_core() {
  local base="$1"
  base="${base%%-*}"
  base="${base%%+*}"
  case "$base" in
    ''|.*|*.|*..*|*[!0-9.]*) return 1 ;;
    *.*) return 0 ;;
    *) return 1 ;;
  esac
}

base_of() {
  local b="$1"
  b="${b%%-*}"
  b="${b%%+*}"
  printf '%s' "$b"
}

ver_gt() {
  # 1) 数字段逐段比较；2) 数字相同则「无预发布后缀」更大；3) 仍相同则比 +build（Dart 的 build 号）
  local base_a base_b ap bp ab bb cmp
  base_a="$(base_of "$1")"
  base_b="$(base_of "$2")"
  ap=0; bp=0
  case "$1" in *-*) ap=1 ;; esac
  case "$2" in *-*) bp=1 ;; esac
  cmp="$(awk -v a="$base_a" -v b="$base_b" 'BEGIN{n=split(a,x,".");m=split(b,y,".");k=(n>m?n:m);
    for(i=1;i<=k;i++){p=(i<=n?x[i]+0:0);q=(i<=m?y[i]+0:0);
      if(p>q){print "gt"; exit} if(p<q){print "lt"; exit}} print "eq"}')"
  case "$cmp" in
    gt) return 0 ;;
    lt) return 1 ;;
  esac
  if [ "$ap" -ne "$bp" ]; then
    [ "$bp" -eq 1 ] && return 0
    return 1
  fi
  ab=""; bb=""
  case "$1" in *+*) ab="${1#*+}"; ab="${ab%%-*}" ;; esac
  case "$2" in *+*) bb="${2#*+}"; bb="${bb%%-*}" ;; esac
  case "${ab}${bb}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$ab" -gt "$bb" ]
}

# 扫一遍 tag：取版本号最大者（不信排序，直接比大小），同时收集前缀样式与「按时间最新」的 tag。
LATEST_TAG=""
LATEST_CORE=""
LATEST_SEMVER=no
TAG_STYLE=non-semver
PREFIX_LIST=""
VERSION_TAG_COUNT=0
while IFS= read -r t; do
  [ -n "$t" ] || continue
  core="$(version_core_of "$t")"
  is_version_core "$core" || continue
  VERSION_TAG_COUNT=$((VERSION_TAG_COUNT + 1))
  pfx="$(tag_prefix_of "$t")"
  [ -n "$pfx" ] || pfx="(none)"
  case " ${PREFIX_LIST} " in
    *" ${pfx} "*) ;;
    *) PREFIX_LIST="${PREFIX_LIST}${PREFIX_LIST:+ }${pfx}" ;;
  esac
  if [ -z "$LATEST_TAG" ] || ver_gt "$core" "$LATEST_CORE"; then
    LATEST_TAG="$t"
    LATEST_CORE="$core"
    LATEST_SEMVER=yes
    TAG_STYLE=semver
  fi
done <<EOF
$(git tag 2>/dev/null || true)
EOF

LATEST_TAG_BY_DATE="$(git tag --sort=-creatordate 2>/dev/null | head -n1 || true)"

TAG_PREFIX="v"
if [ -n "$LATEST_TAG" ]; then
  TAG_PREFIX="$(tag_prefix_of "$LATEST_TAG")"
fi

# 多个不同前缀 = 多版本线 / monorepo 多包：不猜打哪条线。
TAG_PREFIX_COUNT=0
if [ -n "$PREFIX_LIST" ]; then
  TAG_PREFIX_COUNT="$(printf '%s\n' "$PREFIX_LIST" | tr ' ' '\n' | grep -c . || true)"
fi

# ---------- 版本与目标 tag（至少一个输入；不判断「仓库有没有版本信息」） ----------
VERSION=""
if [ -n "$EXPLICIT_VERSION" ]; then
  VERSION="$(version_core_of "$EXPLICIT_VERSION")"
  [ -n "$VERSION" ] || die "--version 需要可解析的版本号（如 1.2.3 / v1.2.3 / 1.2.3+45）"
fi

EXP_TAG=""
if [ -n "$EXPLICIT_TAG" ]; then
  case "$EXPLICIT_TAG" in
    # 裸版本号才补后缀；手写的完整 tag（v1.2.3 / demo-1.0.0 / sub/v1.2.3）原样使用
    [0-9]*) EXP_TAG="${TAG_PREFIX}${EXPLICIT_TAG}" ;;
    *) EXP_TAG="$EXPLICIT_TAG" ;;
  esac
fi

if [ -n "$EXPLICIT_VERSION" ]; then
  VERSION_ORIGIN=declared
  TARGET_TAG="${TAG_PREFIX}${VERSION}"
elif [ -n "$EXPLICIT_TAG" ]; then
  VERSION_ORIGIN=tag
  TARGET_TAG="$EXP_TAG"
  [ -n "$VERSION" ] || VERSION="$(version_core_of "$TARGET_TAG")"
else
  VERSION_ORIGIN=none
  TARGET_TAG=""
fi

# ---------- 声明回查（可选证据）：边界匹配 + 回报行号；找不到时回显「该文件里实际是什么」 ----------
VERSION_IN_FILE=na
VERSION_FILE_LINE=""
VERSION_FILE_TEXT=""
VERSION_FILE_HINT=""
if [ -n "$VERSION_FILE" ] && [ -n "$VERSION" ]; then
  git cat-file -e "${BASE_REF}:${VERSION_FILE}" 2>/dev/null \
    || die "--version-file ${VERSION_FILE} 在 ${BASE_REF} 上不存在（版本源必须是已合并进稳定分支的文件）"
  VER_ESC="$(printf '%s' "$VERSION" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
  MATCH="$(git show "${BASE_REF}:${VERSION_FILE}" 2>/dev/null \
    | grep -nE "(^|[^0-9A-Za-z._+-])v?${VER_ESC}([^0-9A-Za-z._+-]|$)" \
    | head -n1 || true)"
  if [ -n "$MATCH" ]; then
    VERSION_IN_FILE=yes
    VERSION_FILE_LINE="${MATCH%%:*}"
    VERSION_FILE_TEXT="$(printf '%s' "$MATCH" | cut -d: -f2- | sed 's/^[[:space:]]*//' | cut -c1-100)"
  else
    VERSION_IN_FILE=no
    VERSION_FILE_HINT="$(git show "${BASE_REF}:${VERSION_FILE}" 2>/dev/null \
      | grep -oE '[0-9][0-9]*(\.[0-9][0-9]*)+' | head -n1 || true)"
  fi
fi

TAG_EXISTS=no
TAG_ON_BASE=no
if [ -n "$TARGET_TAG" ] && git rev-parse -q --verify "refs/tags/${TARGET_TAG}" >/dev/null 2>&1; then
  TAG_EXISTS=yes
  if git merge-base --is-ancestor "refs/tags/${TARGET_TAG}" "$BASE_REF" 2>/dev/null; then TAG_ON_BASE=yes; fi
fi

# 版本号含 `-` 视为预发布（v1.0.0-rc.1）；GitHub Release 用 --prerelease，GitLab 无对应概念。
RELEASE_PRERELEASE=no
case "$TARGET_TAG" in *-*) RELEASE_PRERELEASE=yes ;; esac

# ---------- CHANGELOG 维护情况（只读探测，决定计划卡要不要问） ----------
CHANGELOG_FILE=""
if [ -n "$CHANGELOG_OVERRIDE" ]; then
  if git cat-file -e "${BASE_REF}:${CHANGELOG_OVERRIDE}" 2>/dev/null; then
    CHANGELOG_FILE="$CHANGELOG_OVERRIDE"
  else
    die "--changelog ${CHANGELOG_OVERRIDE} 在 ${BASE_REF} 上不存在"
  fi
else
  # 只认常见文件名（命名约定，不是生态知识），调用方可用 --changelog 覆盖。
  for c in CHANGELOG.md Changelog.md CHANGELOG CHANGELOG.rst NEWS.md HISTORY.md; do
    if git cat-file -e "${BASE_REF}:${c}" 2>/dev/null; then CHANGELOG_FILE="$c"; break; fi
  done
fi

# 小节匹配放宽到「版本号出现过」：`## [v1.1.0]` / `## 1.1.0` / `## v1.1.0 - 2026-10-22` 都算，
# 且用数字边界避免 1.1.0 命中 11.1.0。与 changelog.sh 的写入判定保持同一语义。
#
# 注意：本文件里的管道匹配一律用 `grep -c … >/dev/null` 而不是 `grep -q`。脚本开了 pipefail，
# 上游（git show / awk / grep）输出较大时，`grep -q` 命中即退出会让上游收到 SIGPIPE，
# 整条管道被判为失败（macOS 实测：CHANGELOG 稍大就会让这里出现 CHANGELOG_HAS_VERSION 假阴性）。
CHANGELOG_HAS_VERSION=na
if [ -n "$CHANGELOG_FILE" ] && [ -n "$VERSION" ]; then
  VER_ESC_CL="$(printf '%s' "$VERSION" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
  if git show "${BASE_REF}:${CHANGELOG_FILE}" 2>/dev/null \
     | grep -Eci "(^|[^0-9])(v)?${VER_ESC_CL}([^0-9]|$)" >/dev/null; then
    CHANGELOG_HAS_VERSION=yes
  else
    CHANGELOG_HAS_VERSION=no
  fi
fi

# ---------- 自最新 tag 起的变更（用于发布说明与回执） ----------
if [ -n "$LATEST_TAG" ]; then RANGE="${LATEST_TAG}..${BASE_REF}"; else RANGE="${BASE_REF}"; fi
TOTAL_COMMITS="$(git rev-list --count "$RANGE" 2>/dev/null || echo 0)"
SUBJECTS="$(git log --format='%s' --max-count=300 "$RANGE")"
FULL="$(git log --format='%s%n%b' --max-count=300 "$RANGE")"
COMMITS="$(printf '%s\n' "$SUBJECTS" | grep -c . || true)"
FEAT="$(printf '%s\n' "$SUBJECTS" | grep -cE '^feat(\([^)]*\))?!?:' || true)"
FIX="$(printf '%s\n' "$SUBJECTS" | grep -cE '^fix(\([^)]*\))?!?:' || true)"
BANG="$(printf '%s\n' "$SUBJECTS" | grep -cE '^[A-Za-z]+(\([^)]*\))?!:' || true)"
BREAKING="$(printf '%s\n' "$FULL" | grep -c 'BREAKING[ -]CHANGE' || true)"
BREAKING=$((BREAKING + BANG))

# ---------- tag 触发的后效：只给信号，不给结论 ----------
# 只看未注释的行：workflow 头部注释里常出现 `tags:` / `publish` 这类字样，误报会让回执凭空多出后效。
TAG_WORKFLOWS=""
if [ -d "${ROOT}/.github/workflows" ]; then
  for f in "${ROOT}"/.github/workflows/*.yml "${ROOT}"/.github/workflows/*.yaml; do
    [ -f "$f" ] || continue
    if awk '/^jobs:/{exit} {print}' "$f" | grep -vE '^[[:space:]]*#' | grep -cE '(^|[[:space:]])tags:' >/dev/null; then
      TAG_WORKFLOWS="${TAG_WORKFLOWS}${f##*/} "
    fi
  done
fi
TAG_WORKFLOWS="$(printf '%s' "$TAG_WORKFLOWS" | sed 's/ *$//')"

# EFFECT_HINTS：只摘**可执行行**（`run:` / `uses:`）里像发布的那些，输出 `file:line: 原文`。
# 不摘 job 名 / step 名 / workflow 名（那些多半是命名巧合，噪音大于信息）；也不做类型判定。
EFFECT_HINTS=""
if [ -d "${ROOT}/.github/workflows" ]; then
  EFFECT_HINTS="$(grep -rnE '^[[:space:]]*(-[[:space:]]+)?(run|uses):' "${ROOT}/.github/workflows" 2>/dev/null \
    | grep -E 'publish|upload|release create|action-gh-release' \
    | grep -vE ':[[:space:]]*#' \
    | sed "s#^${ROOT}/##" \
    | cut -c1-120 \
    | head -n8 \
    | tr '\n' ';' | sed 's/;$//; s/;/; /g')" || true
fi
if [ -f "${ROOT}/.gitlab-ci.yml" ]; then
  GL_HINTS="$(grep -nE '^[[:space:]]*(-[[:space:]]+)?(run|script):' "${ROOT}/.gitlab-ci.yml" 2>/dev/null \
    | grep -E 'publish|upload|release create|glab release' \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | cut -c1-120 \
    | head -n8 \
    | sed 's#^#.gitlab-ci.yml:#' \
    | tr '\n' ';' | sed 's/;$//; s/;/; /g')" || true
  if [ -n "$GL_HINTS" ]; then
    if [ -z "$EFFECT_HINTS" ]; then EFFECT_HINTS="$GL_HINTS"; else EFFECT_HINTS="${EFFECT_HINTS}; ${GL_HINTS}"; fi
  fi
fi

# Release 是否由 CI 负责创建：探测依据按平台分叉，只看未注释的行。
#   GitHub：tag workflow 里出现 action-gh-release / gh release create
#   GitLab：.gitlab-ci.yml 由 CI_COMMIT_TAG 触发，且含 release: 或 glab release create
EFFECT_RELEASE=none
if [ "$RELEASE_PLATFORM" = github ]; then
  if [ -n "$TAG_WORKFLOWS" ] && grep -rhE 'action-gh-release|gh release create' "${ROOT}/.github/workflows" 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -c . >/dev/null; then
    EFFECT_RELEASE=workflow
  fi
elif [ "$RELEASE_PLATFORM" = gitlab ]; then
  if [ -f "${ROOT}/.gitlab-ci.yml" ] \
     && grep -vE '^[[:space:]]*#' "${ROOT}/.gitlab-ci.yml" | grep -c 'CI_COMMIT_TAG' >/dev/null \
     && grep -vE '^[[:space:]]*#' "${ROOT}/.gitlab-ci.yml" | grep -cE '^[[:space:]]*release:[[:space:]]*$|glab release create' >/dev/null; then
    EFFECT_RELEASE=workflow
  fi
fi

# CI 体系与 GitLab 的 tag 流水信号（供步骤 4 决定怎么跟踪）
CI_SYSTEM=""
if [ -d "${ROOT}/.github/workflows" ]; then CI_SYSTEM=github; fi
if [ -f "${ROOT}/.gitlab-ci.yml" ]; then
  if [ -z "$CI_SYSTEM" ]; then CI_SYSTEM=gitlab; else CI_SYSTEM="${CI_SYSTEM},gitlab"; fi
fi
[ -n "$CI_SYSTEM" ] || CI_SYSTEM=none
GITLAB_TAG_CI=no
if [ -f "${ROOT}/.gitlab-ci.yml" ] && grep -vE '^[[:space:]]*#' "${ROOT}/.gitlab-ci.yml" | grep -c 'CI_COMMIT_TAG' >/dev/null; then
  GITLAB_TAG_CI=yes
fi

# Release 现在到底存不存在：能查就查，查不了记 unknown（不是「不存在」）。
# 未认证/CLI 缺失时绝不查询，避免把权限错误当成「要新建」。
RELEASE_EXISTS=unknown
if [ "$DO_RELEASE_CHECK" -eq 1 ] && [ -n "$TARGET_TAG" ] && [ "$RELEASE_CLI_READY" = yes ]; then
  if [ "$RELEASE_CLI" = gh ]; then
    if REL_OUT="$(gh release view "$TARGET_TAG" --repo "$REPO_ID" 2>&1)"; then
      RELEASE_EXISTS=yes
    else
      case "$REL_OUT" in
        *"not found"*|*"Not Found"*|*404*) RELEASE_EXISTS=no ;;
        *) RELEASE_EXISTS=unknown ;;
      esac
    fi
  elif [ "$RELEASE_CLI" = glab ]; then
    if REL_OUT="$(glab release view "$TARGET_TAG" -R "$REPO_ID" 2>&1)"; then
      RELEASE_EXISTS=yes
    else
      case "$REL_OUT" in
        *"not found"*|*"Not Found"*|*404*) RELEASE_EXISTS=no ;;
        *) RELEASE_EXISTS=unknown ;;
      esac
    fi
  fi
fi

# ---------- 状态 ----------
STATE=READY
if [ -z "$TARGET_TAG" ]; then
  STATE=NEEDS_TARGET
elif [ "$TAG_EXISTS" = yes ]; then
  STATE=TAGGED
fi

BLOCKERS=""
add_blocker() { if [ -z "$BLOCKERS" ]; then BLOCKERS="$1"; else BLOCKERS="${BLOCKERS}, $1"; fi; }
WARN=""
add_warn() { if [ -z "$WARN" ]; then WARN="$1"; else WARN="${WARN}, $1"; fi; }

if [ "$STATE" = NEEDS_TARGET ]; then add_blocker "target-version-unset"; fi
# 阻断项必须同时反映到 STATE：STATE 才是流程的驱动量，只看 BLOCKERS 会被 READY 带走
if [ "$TAG_EXISTS" = yes ] && [ "$TAG_ON_BASE" = no ]; then
  add_blocker "tag-not-on-base"
  STATE=BLOCKED
fi
# 多版本线/多包：用 --version 推不出「哪条线的 tag」，必须显式 --tag。不猜。
if [ "$TAG_PREFIX_COUNT" -gt 1 ] && [ "$VERSION_ORIGIN" = declared ] && [ -z "$EXPLICIT_TAG" ]; then
  add_blocker "target-tag-ambiguous"
  STATE=BLOCKED
fi
# 声明版本是否真在该文件里：默认只提醒（派生/注入型仓库本来就没有字面版本），严格模式才阻断。
if [ "$VERSION_IN_FILE" = no ]; then
  if [ "$REQUIRE_MATCH" -eq 1 ]; then
    add_blocker "version-not-in-declared-file"
    STATE=BLOCKED
  else
    add_warn "version-declaration-unverified"
  fi
fi
# --tag 与 --version 同时给出时必须一致（比版本内核，不比前缀风格）
if [ "$VERSION_ORIGIN" = declared ] && [ -n "$EXP_TAG" ]; then
  EXP_CORE="$(version_core_of "$EXP_TAG")"
  if [ -z "$EXP_CORE" ] || [ "$EXP_CORE" != "$VERSION" ]; then
    add_blocker "tag-version-mismatch"
    STATE=BLOCKED
  fi
fi
# 「版本必须领先最新 tag」与版本源无关，纯 tag 比较
if [ "$TAG_EXISTS" = no ] && [ -n "$LATEST_TAG" ] && [ -n "$VERSION" ]; then
  if ! ver_gt "$VERSION" "$LATEST_CORE"; then
    add_blocker "version-not-ahead-of-tag"
    STATE=BLOCKED
  fi
fi

# 有 tag 但没有任何可解析的版本 tag → 版本比较守卫失效，必须说出来（不许静默跳过）
if [ -z "$LATEST_TAG" ] && [ -n "$LATEST_TAG_BY_DATE" ]; then add_warn "no-version-like-tags"; fi
# 版本号最大者不是时间最新者 → 可能在新线上发旧版 / 或在旧线上补丁，如实报出来
if [ -n "$LATEST_TAG_BY_DATE" ] && [ "$LATEST_TAG_BY_DATE" != "$LATEST_TAG" ]; then add_warn "latest-tag-order-conflict"; fi
if [ "$TAG_PREFIX_COUNT" -gt 1 ]; then add_warn "mixed-tag-prefixes"; fi
if [ "${TOTAL_COMMITS:-0}" -gt 300 ]; then add_warn "commits-truncated"; fi
if [ "$VERSION_ORIGIN" = declared ] && [ -z "$VERSION_FILE" ]; then add_warn "version-file-undeclared"; fi
if [ "$VERSION_ORIGIN" = tag ]; then add_warn "version-origin-tag"; fi
# Release 能力相关提醒：都不阻断，只影响「建 / 校验 / 手动」的选择。
if [ "$RELEASE_PLATFORM" = unknown ]; then add_warn "release-host-unknown"; fi
if [ "$RELEASE_PLATFORM" != unknown ] && [ "$RELEASE_CLI" = none ]; then add_warn "release-cli-missing"; fi
if [ "$RELEASE_CLI" != none ] && [ "$RELEASE_CLI_READY" = no ]; then add_warn "release-auth-missing"; fi
if [ "$DO_RELEASE_CHECK" -eq 1 ] && [ "$RELEASE_CLI_READY" = yes ] && [ "$RELEASE_EXISTS" = unknown ]; then
  add_warn "release-check-unknown"
fi
if [ -n "$(git status --porcelain)" ]; then add_warn "dirty-worktree"; fi

# ---------- 输出 ----------
echo "ROOT=${ROOT}"
echo "REMOTE=${REMOTE}"
echo "REMOTE_URL=${REMOTE_URL}"
echo "HOST=${HOST:-<none>}"
echo "REPO_ID=${REPO_ID:-<none>}"
echo "RELEASE_PLATFORM=${RELEASE_PLATFORM}"
echo "RELEASE_CLI=${RELEASE_CLI}"
echo "RELEASE_CLI_READY=${RELEASE_CLI_READY}"
echo "EFFECT_RELEASE=${EFFECT_RELEASE}"
echo "RELEASE_EXISTS=${RELEASE_EXISTS}"
echo "RELEASE_PRERELEASE=${RELEASE_PRERELEASE}"
echo "CI_SYSTEM=${CI_SYSTEM}"
echo "GITLAB_TAG_CI=${GITLAB_TAG_CI}"
echo "BASE=${BASE}"
echo "BASE_REF=${BASE_REF}"
echo "VERSION_ORIGIN=${VERSION_ORIGIN}"
echo "VERSION=${VERSION:-<none>}"
echo "VERSION_FILE=${VERSION_FILE:-<none>}"
echo "VERSION_IN_FILE=${VERSION_IN_FILE}"
echo "VERSION_FILE_LINE=${VERSION_FILE_LINE:-<none>}"
echo "VERSION_FILE_TEXT=${VERSION_FILE_TEXT:-<none>}"
echo "VERSION_FILE_HINT=${VERSION_FILE_HINT:-<none>}"
echo "LATEST_TAG=${LATEST_TAG:-<none>}"
echo "LATEST_TAG_BY_DATE=${LATEST_TAG_BY_DATE:-<none>}"
echo "TAG_STYLE=${TAG_STYLE}"
echo "TAG_PREFIX=${TAG_PREFIX:-<none>}"
echo "TAG_PREFIX_COUNT=${TAG_PREFIX_COUNT}"
echo "LATEST_SEMVER=${LATEST_SEMVER}"
echo "TARGET_TAG=${TARGET_TAG:-<none>}"
echo "TAG_EXISTS=${TAG_EXISTS}"
echo "TAG_ON_BASE=${TAG_ON_BASE}"
echo "CHANGELOG=${CHANGELOG_FILE:-<none>}"
echo "CHANGELOG_HAS_VERSION=${CHANGELOG_HAS_VERSION}"
echo "COMMITS=${COMMITS}"
echo "TOTAL_COMMITS=${TOTAL_COMMITS}"
echo "FEAT=${FEAT}"
echo "FIX=${FIX}"
echo "BREAKING=${BREAKING}"
echo "TAG_WORKFLOWS=${TAG_WORKFLOWS:-<none>}"
echo "EFFECT_HINTS=${EFFECT_HINTS:-<none>}"
echo "STATE=${STATE}"
echo "WARN=${WARN:-none}"
echo "BLOCKERS=${BLOCKERS:-none}"

if [ -n "$BLOCKERS" ]; then exit 2; fi
exit 0
