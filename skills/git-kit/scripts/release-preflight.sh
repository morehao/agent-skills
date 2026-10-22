#!/usr/bin/env bash
# release 预检（只读）：pr-merge 之后的发布段所需事实。
#
# 起点假设：版本号已经随 PR 合并进稳定分支，工作由「打 tag → 跟踪发布后效」构成。
#
# 两条设计前提（避免把某个仓库的习惯当成通用规律）：
#   1. 版本来源因仓而异：Node 包读 package.json；Go/Rust/无清单仓库以 tag 本身为准。
#   2. tag 之后的后效因仓而异：npm 包、容器镜像、文档站、GitHub Release，或什么都不做。
#      本脚本只**探测**后效，不假设；探测不到一律写「未检测到」，不当成「没有后效」。
#
# 不写文件、不切分支、不打 tag。默认 fetch 远端分支与 tag。
#
# 另探测仓库是否维护 CHANGELOG.md（只读判断，不写）：决定计划卡里是否询问「要不要记录变更」。
#
# 退出码：0 可继续 / 2 有阻断项 / 1 环境或参数错误。
#
# bash 3.2 兼容（macOS 自带）：不用 mapfile / 关联数组 / ${var,,}。

set -euo pipefail

usage() {
  cat <<'EOF'
用法: bash release-preflight.sh [选项]
  --remote <名>    目标远端（默认 upstream → 回退 origin）
  --pkg <目录>     发布包目录（默认按 workspaces 识别唯一非私有包）
  --tag <vX.Y.Z>   目标 tag；仓库没有可读的版本清单时**必需**（Go/Rust 等以 tag 为版本源）
  --no-fetch       跳过 fetch
  --no-npm         跳过 npm 已发布校验（结果记 unknown）
  -h, --help
EOF
}

die() { echo "错误：$*" >&2; exit 1; }

REMOTE=""
PKG_DIR=""
EXPLICIT_TAG=""
DO_FETCH=1
DO_NPM=1

while [ $# -gt 0 ]; do
  case "$1" in
    --remote) REMOTE="${2:-}"; shift 2 ;;
    --pkg) PKG_DIR="${2:-}"; shift 2 ;;
    --tag) EXPLICIT_TAG="${2:-}"; shift 2 ;;
    --no-fetch) DO_FETCH=0; shift ;;
    --no-npm) DO_NPM=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数 $1（-h 查看用法）" ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "当前目录不在 git 仓库内"
cd "$ROOT"

# --pkg 写错不能静默降级成「以 tag 为版本源」：直接报错。
if [ -n "$PKG_DIR" ]; then
  case "$PKG_DIR" in
    /*) PKG_ABS="$PKG_DIR" ;;
    *) PKG_ABS="${ROOT}/${PKG_DIR}" ;;
  esac
  [ -f "${PKG_ABS}/package.json" ] || die "--pkg ${PKG_DIR} 下没有 package.json（相对仓库根传入，如 commands-dsh）"
  case "$PKG_ABS" in
    "$ROOT"/*) PKG_DIR="${PKG_ABS#"$ROOT"/}" ;;
    *) die "--pkg 必须指向仓库内的目录：${PKG_DIR}" ;;
  esac
fi

# ---------- 远端与稳定分支 ----------
if [ -z "$REMOTE" ]; then
  if git remote get-url upstream >/dev/null 2>&1; then REMOTE=upstream; else REMOTE=origin; fi
fi
git remote get-url "$REMOTE" >/dev/null 2>&1 || die "远端 ${REMOTE} 不存在（release 需要可推送的远端）"

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

# ---------- 版本来源：清单优先，没有清单就以 tag 为源 ----------
resolve_pkg_dir() {
  node -e '
const fs = require("fs");
const path = require("path");
const root = process.argv[1];
const readJson = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } };
const rootPkg = readJson(path.join(root, "package.json"));
if (!rootPkg) process.exit(5);
let dirs = [];
const ws = Array.isArray(rootPkg.workspaces) ? rootPkg.workspaces : [];
for (const w of ws) {
  if (w.includes("*")) {
    const base = w.split("*")[0].replace(/\/$/, "");
    const abs = path.join(root, base);
    if (!fs.existsSync(abs)) continue;
    for (const e of fs.readdirSync(abs)) {
      const d = path.join(base, e);
      if (fs.existsSync(path.join(root, d, "package.json"))) dirs.push(d);
    }
  } else dirs.push(w);
}
const found = [];
for (const d of dirs) {
  const p = readJson(path.join(root, d, "package.json"));
  if (p && p.version && !p.private) found.push(d);
}
if (found.length === 1) { console.log(found[0]); process.exit(0); }
if (found.length === 0 && rootPkg.version && !rootPkg.private) { console.log("."); process.exit(0); }
for (const f of found) console.error(f);
process.exit(found.length === 0 ? 5 : 4);
' "$ROOT"
}

PKG_CANDIDATES=""
if [ -z "$PKG_DIR" ] && command -v node >/dev/null 2>&1; then
  PKG_ERR="$(mktemp)"
  set +e
  PKG_DIR="$(resolve_pkg_dir 2>"$PKG_ERR")"
  PKG_RC=$?
  set -e
  PKG_CANDIDATES="$(tr '\n' ' ' < "$PKG_ERR" | sed 's/ *$//')"
  rm -f "$PKG_ERR"
  [ "$PKG_RC" -eq 0 ] || PKG_DIR=""
fi

PKG_NAME=""
PKG_VERSION=""
PUBLISH_CONFIG=no
if [ -n "$PKG_DIR" ] && [ -f "${ROOT}/${PKG_DIR}/package.json" ]; then
  VERSION_SOURCE=manifest
  read_remote_field() {
    git show "${BASE_REF}:${PKG_DIR}/package.json" 2>/dev/null | node -e '
const fs = require("fs");
try {
  const j = JSON.parse(fs.readFileSync(0, "utf8"));
  const v = j[process.argv[1]];
  process.stdout.write(typeof v === "string" ? v : (v ? "yes" : ""));
} catch { process.exit(1); }
' "$1"
  }
  PKG_NAME="$(read_remote_field name)" || PKG_NAME=""
  PKG_VERSION="$(read_remote_field version)" || PKG_VERSION=""
  PUBLISH_CONFIG="$(read_remote_field publishConfig)" || PUBLISH_CONFIG="no"
  [ -n "$PUBLISH_CONFIG" ] || PUBLISH_CONFIG=no
else
  PKG_DIR=""
  VERSION_SOURCE=tag
fi

# ---------- 最新 tag 与目标 tag ----------
LATEST_TAG="$(git tag --list 'v[0-9]*' --sort=-v:refname | head -n1)"
if [ -z "$LATEST_TAG" ]; then
  LATEST_TAG="$(git tag --sort=-creatordate | head -n1)"
  TAG_STYLE="non-semver"
else
  TAG_STYLE="vX.Y.Z"
fi

# 版本比较是否可用：看 tag 的数字内核，而不是「有没有 v 前缀」。
# 只认 v 前缀会让 `1.2.3` / `2026.10` 这类 tag 的仓库整条「版本必须领先」守卫失效。
LATEST_SEMVER=no
if [ -n "$LATEST_TAG" ]; then
  LATEST_CORE="${LATEST_TAG#v}"
  LATEST_CORE="${LATEST_CORE%%-*}"
  case "$LATEST_CORE" in
    ''|*[!0-9.]*|.*|*.|*..*) LATEST_SEMVER=no ;;
    *) LATEST_SEMVER=yes ;;
  esac
fi

TAG_PREFIX="v"
if [ -n "$LATEST_TAG" ]; then
  case "$LATEST_TAG" in
    v*) TAG_PREFIX="v" ;;
    *) TAG_PREFIX="" ;;
  esac
fi

EXP_TAG=""
if [ -n "$EXPLICIT_TAG" ]; then
  case "$EXPLICIT_TAG" in
    v*) EXP_TAG="$EXPLICIT_TAG" ;;
    *) EXP_TAG="${TAG_PREFIX}${EXPLICIT_TAG}" ;;
  esac
fi

CUR="${PKG_VERSION#v}"
if [ "$VERSION_SOURCE" = "manifest" ] && [ -n "$CUR" ]; then
  TARGET_TAG="${TAG_PREFIX}${CUR}"
else
  TARGET_TAG="$EXP_TAG"
fi

TAG_EXISTS=no
TAG_ON_BASE=no
if [ -n "$TARGET_TAG" ] && git rev-parse -q --verify "refs/tags/${TARGET_TAG}" >/dev/null 2>&1; then
  TAG_EXISTS=yes
  if git merge-base --is-ancestor "refs/tags/${TARGET_TAG}" "$BASE_REF" 2>/dev/null; then TAG_ON_BASE=yes; fi
fi

# ---------- CHANGELOG 维护情况（只读探测，决定计划卡要不要问） ----------
CHANGELOG_FILE=""
for c in CHANGELOG.md Changelog.md CHANGELOG CHANGELOG.rst; do
  if git cat-file -e "${BASE_REF}:${c}" 2>/dev/null; then CHANGELOG_FILE="$c"; break; fi
done
CHANGELOG_HAS_VERSION=na
if [ -n "$CHANGELOG_FILE" ] && [ -n "$TARGET_TAG" ]; then
  if git show "${BASE_REF}:${CHANGELOG_FILE}" 2>/dev/null | grep -qF "## [${TARGET_TAG}]"; then
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

# ---------- tag 之后的后效探测（仓库事实，不是 git-kit 的假设） ----------
# 只看未注释的行：workflow 头部注释里常出现 `tags:` / `npm publish` 这类字样，误报会让回执凭空多出后效。
TAG_WORKFLOWS=""
if [ -d "${ROOT}/.github/workflows" ]; then
  for f in "${ROOT}"/.github/workflows/*.yml "${ROOT}"/.github/workflows/*.yaml; do
    [ -f "$f" ] || continue
    if awk '/^jobs:/{exit} {print}' "$f" | grep -vE '^[[:space:]]*#' | grep -qE '(^|[[:space:]])tags:'; then
      TAG_WORKFLOWS="${TAG_WORKFLOWS}${f##*/} "
    fi
  done
fi
TAG_WORKFLOWS="$(printf '%s' "$TAG_WORKFLOWS" | sed 's/ *$//')"

EFFECT_NPM=no
if [ "$PUBLISH_CONFIG" = "yes" ]; then EFFECT_NPM=yes; fi
if grep -rhE 'npm publish' "${ROOT}/.github/workflows" 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -q .; then
  EFFECT_NPM=yes
fi

EFFECT_GH_RELEASE=no
if [ -n "$TAG_WORKFLOWS" ] && grep -rhE 'action-gh-release|gh release create' "${ROOT}/.github/workflows" 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -q .; then
  EFFECT_GH_RELEASE=yes
fi

# npm 后效：只有仓库确实发 npm 且能定位包名时才查。
# 用独立缓存目录：本机 ~/.npm 可能被 root 占用（EPERM），那不是「版本不存在」，不能误判成 no。
NPM_PUBLISHED=skipped
if [ "$EFFECT_NPM" = "yes" ]; then
  if [ "$DO_NPM" -eq 0 ] || [ -z "$PKG_NAME" ] || ! command -v npm >/dev/null 2>&1; then
    NPM_PUBLISHED=unknown
  else
    NPM_CACHE="$(mktemp -d 2>/dev/null || true)"
    if [ -n "$NPM_CACHE" ]; then
      if NPM_OUT="$(npm view "${PKG_NAME}@${CUR}" version --registry https://registry.npmjs.org --cache "$NPM_CACHE" 2>&1)"; then
        NPM_PUBLISHED=yes
      elif printf '%s' "$NPM_OUT" | grep -qE 'E404|404 (No match|Not Found)'; then
        NPM_PUBLISHED=no
      else
        NPM_PUBLISHED=unknown
      fi
      rm -rf "$NPM_CACHE"
    fi
  fi
fi

# ---------- 状态 ----------
ver_gt() {
  # 数字部分按段比较；数字相等时「无预发布后缀」的一方更大（1.0.1 > 1.0.1-beta.1）
  local a="${1%%-*}" b="${2%%-*}"
  local ap=0 bp=0 cmp
  case "$1" in *-*) ap=1 ;; esac
  case "$2" in *-*) bp=1 ;; esac
  cmp="$(awk -v a="$a" -v b="$b" 'BEGIN{n=split(a,x,".");m=split(b,y,".");k=(n>m?n:m);
    for(i=1;i<=k;i++){p=(i<=n?x[i]+0:0);q=(i<=m?y[i]+0:0);
      if(p>q){print "gt"; exit} if(p<q){print "lt"; exit}} print "eq"}')"
  case "$cmp" in
    gt) return 0 ;;
    lt) return 1 ;;
    *) [ "$bp" -eq 1 ] && [ "$ap" -eq 0 ] && return 0; return 1 ;;
  esac
}

STATE=READY
if [ -z "$TARGET_TAG" ]; then
  STATE=NEEDS_TAG
elif [ "$TAG_EXISTS" = "yes" ]; then
  STATE=TAGGED
elif [ "$VERSION_SOURCE" = "manifest" ] && [ "$LATEST_SEMVER" = "yes" ] && [ -n "$LATEST_TAG" ] && ! ver_gt "$CUR" "${LATEST_TAG#v}"; then
  STATE=BLOCKED
fi

BLOCKERS=""
add_blocker() { if [ -z "$BLOCKERS" ]; then BLOCKERS="$1"; else BLOCKERS="${BLOCKERS}, $1"; fi; }
WARN=""
add_warn() { if [ -z "$WARN" ]; then WARN="$1"; else WARN="${WARN}, $1"; fi; }

if [ "$STATE" = "NEEDS_TAG" ]; then add_blocker "no-version-source"; fi
if [ "$STATE" = "BLOCKED" ]; then add_blocker "version-not-ahead-of-tag"; fi
# 阻断项必须同时反映到 STATE：STATE 才是流程的驱动量，只看 BLOCKERS 会被 READY 带走
if [ "$TAG_EXISTS" = "yes" ] && [ "$TAG_ON_BASE" = "no" ]; then
  add_blocker "tag-not-on-base"
  STATE=BLOCKED
fi
if [ -n "$EXP_TAG" ] && [ "$VERSION_SOURCE" = "manifest" ] && [ "$EXP_TAG" != "$TARGET_TAG" ]; then
  add_blocker "tag-version-mismatch"
  STATE=BLOCKED
fi
if [ "$VERSION_SOURCE" = "manifest" ] && [ -n "$LATEST_TAG" ] && [ "$LATEST_SEMVER" = "no" ]; then
  add_warn "latest-tag-not-semver"
fi
if [ -n "$PKG_CANDIDATES" ]; then add_warn "multiple-publish-packages"; fi
if [ "${TOTAL_COMMITS:-0}" -gt 300 ]; then add_warn "commits-truncated"; fi
if [ "$NPM_PUBLISHED" = "unknown" ]; then add_warn "npm-unknown"; fi
if ! command -v gh >/dev/null 2>&1; then add_warn "gh-missing"; fi
if [ -n "$(git status --porcelain)" ]; then add_warn "dirty-worktree"; fi

# ---------- 输出 ----------
echo "ROOT=${ROOT}"
echo "REMOTE=${REMOTE}"
echo "BASE=${BASE}"
echo "BASE_REF=${BASE_REF}"
echo "VERSION_SOURCE=${VERSION_SOURCE}"
echo "PKG_DIR=${PKG_DIR:-<none>}"
echo "PKG_NAME=${PKG_NAME:-<none>}"
echo "PKG_VERSION=${CUR:-<none>}"
echo "PKG_CANDIDATES=${PKG_CANDIDATES:-<none>}"
echo "LATEST_TAG=${LATEST_TAG:-<none>}"
echo "TAG_STYLE=${TAG_STYLE}"
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
echo "EFFECT_NPM=${EFFECT_NPM}"
echo "EFFECT_GH_RELEASE=${EFFECT_GH_RELEASE}"
echo "NPM_PUBLISHED=${NPM_PUBLISHED}"
echo "STATE=${STATE}"
echo "WARN=${WARN:-none}"
echo "BLOCKERS=${BLOCKERS:-none}"

if [ -n "$BLOCKERS" ]; then exit 2; fi
exit 0
