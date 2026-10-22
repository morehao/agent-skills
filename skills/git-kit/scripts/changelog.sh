#!/usr/bin/env bash
# 生成本次发布的变更说明（Markdown）：release 与 tag 共用的唯一真源。
#
# 数据源是 Conventional Commits：按 type 分组、按 scope 标注、breaking 单独成组。
# 不做主观改写（不编取舍说明），只做归类与措辞收敛；原始 subject 是唯一事实。
#
# 用法：
#   bash changelog.sh --to <ref>                      # 首个版本（无基线）
#   bash changelog.sh --from <tag> --to <ref>         # 常规：上一个 tag 到目标
#   bash changelog.sh --from v1.0.0 --to origin/main --all --no-link
#
# 输出为 Markdown 片段，直接用于：annotated tag 的注记正文、GitHub Release notes、PR body。
#
# 写进 CHANGELOG.md（可选，由 release 的「是否记录 CHANGELOG」分支调用）：
#   bash changelog.sh --from <tag> --to <ref> --version v1.1.0 --write CHANGELOG.md
#   - 标题行格式：## [v1.1.0] - 2026-10-22
#   - 文件不存在则新建（带 `# Changelog` 抬头）
#   - 已含该版本小节 → 不重复写入，退出码 3（幂等）
#
# bash 3.2 兼容（macOS 自带）：不用 mapfile / 关联数组 / ${var,,}。

set -euo pipefail

FROM=""
TO=""
MAX=300
INCLUDE_MINOR=0
WITH_LINK=1
REMOTE=""
LINK_TO=""
VERSION=""
WRITE=""
DATE=""

usage() {
  cat <<'EOF'
用法: bash changelog.sh --to <ref> [选项]
  --from <ref>     基线（上一个 tag）；省略则视为首个版本
  --to <ref>       目标（通常是 <remote>/<base> 或 tag）
  --max <n>        最多收录提交数（默认 300；区间更长会在 stderr 告警）
  --all            额外收录 chore/ci/build/test/style 类提交（默认只收用户可感知的变更）
  --no-link        不追加 compare 链接
  --link-to <ref>  compare 链接右端（默认把 --to 的 <远端>/ 前缀剥掉）
  --remote <名>    用于生成 compare 链接的远端（默认 upstream → origin）
  --version <v>    版本号；用于 CHANGELOG 小节标题（与 --write 搭配）
  --write <path>   把结果写进 CHANGELOG 文件（插入到首个 `## ` 小节之前）
  --date <Y-M-D>   标题里的日期（默认今天，便于测试）
  -h, --help
EOF
}

die() { echo "错误：$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:-}"; shift 2 ;;
    --to) TO="${2:-}"; shift 2 ;;
    --max) MAX="${2:-}"; shift 2 ;;
    --all) INCLUDE_MINOR=1; shift ;;
    --no-link) WITH_LINK=0; shift ;;
    --link-to) LINK_TO="${2:-}"; shift 2 ;;
    --remote) REMOTE="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --write) WRITE="${2:-}"; shift 2 ;;
    --date) DATE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数 $1（-h 查看用法）" ;;
  esac
done

[ -n "$TO" ] || die "缺少 --to <ref>"
case "$MAX" in ''|*[!0-9]*) die "--max 需要正整数（当前：${MAX}）" ;; esac
[ "$MAX" -gt 0 ] || die "--max 需要正整数（当前：${MAX}）"
if [ -n "$WRITE" ] && [ -z "$VERSION" ]; then die "--write 需要同时给 --version（用作小节标题）"; fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "当前目录不在 git 仓库内"
cd "$ROOT"

git rev-parse --verify -q "$TO" >/dev/null || die "目标 ref 不存在：${TO}"
if [ -n "$FROM" ]; then
  git rev-parse --verify -q "$FROM" >/dev/null || die "基线 ref 不存在：${FROM}"
  RANGE="${FROM}..${TO}"
else
  RANGE="$TO"
fi

# 静默截断是最坏的一种「看起来完整」：超限时告警到 stderr（不污染正文）
TOTAL="$(git rev-list --count "$RANGE" 2>/dev/null || echo 0)"
if [ "${TOTAL:-0}" -gt "$MAX" ]; then
  echo "⚠️  只收录最近 ${MAX} 条提交（区间共 ${TOTAL} 条）；要完整正文请加 --max ${TOTAL}" >&2
fi

NOTES="$(
  git log --no-merges --format='%x1f%s%x1f%b%x1e' --max-count="$MAX" "$RANGE" | \
  awk -v include_minor="$INCLUDE_MINOR" '
    BEGIN { RS = "\036"; FS = "\037" }
    function sec_of(t) {
      if (t == "feat") return "Features";
      if (t == "fix") return "Fixes";
      if (t == "perf") return "Performance";
      if (t == "refactor") return "Refactors";
      if (t == "docs") return "Docs";
      return "Other Changes";
    }
    {
      if (NF < 3) next
      subj = $2; body = $3
      gsub(/^[ \t\n]+|[ \t\n]+$/, "", subj)
      if (subj == "") next
      # 版本记录提交本身不进说明（release 的 CHANGELOG PR 也会产生一条）
      if (subj ~ /^(chore\(release\)|release:|docs\(changelog\))/) next
      type = ""; scope = ""; desc = subj; has_bang = 0
      if (match(subj, /^[A-Za-z]+(\([^)]*\))?!?:[ \t]*/)) {
        prefix = substr(subj, 1, RLENGTH)
        desc = substr(subj, RLENGTH + 1)
        match(prefix, /^[A-Za-z]+/)
        type = substr(prefix, 1, RLENGTH)
        if (match(prefix, /\([^)]*\)/)) scope = substr(prefix, RSTART + 1, RLENGTH - 2)
        if (prefix ~ /!:/) has_bang = 1
      }
      line = "- "
      if (scope != "") line = line "**" scope "**: "
      line = line desc
      # breaking 优先判定：chore!/ci! 之类默认被过滤的 type 也必须进 Breaking 组
      if (has_bang || body ~ /BREAKING[ -]CHANGE/) {
        # breaking 单独成组，避免同一提交出现两次
        if (!(line in seen)) { brk[++bn] = line; seen[line] = 1 }
        next
      }
      if (!include_minor && type ~ /^(chore|ci|build|test|style)$/) next
      sec = sec_of(type)
      if (!(sec in buf)) n++
      buf[sec] = buf[sec] line "\n"
    }
    END {
      if (bn > 0) {
        printf "### ⚠️ Breaking Changes\n\n"
        for (i = 1; i <= bn; i++) print brk[i]
        printf "\n"
      }
      # 固定章节顺序，与提交先后无关
      split("Features|Fixes|Performance|Refactors|Docs|Other Changes", canon, "|")
      for (k = 1; k <= 7; k++) {
        sec = canon[k]
        if (sec in buf) printf "### %s\n\n%s\n", sec, buf[sec]
      }
    }
  '
)"

if [ -z "$NOTES" ]; then
  if [ -n "$FROM" ]; then SPAN="${FROM}..${TO}"; else SPAN="${TO}"; fi
  if [ -n "$WRITE" ]; then
    echo "无变更可记录（${SPAN}），未写入 ${WRITE}" >&2
    exit 4
  fi
  # 走 stderr：stdout 是正文，被 `> "$NOTES"` 捕获，不能混入提示语
  echo "无变更（${SPAN} 内没有可记录的提交）" >&2
  exit 0
fi

# 可选：GitHub compare 链接
LINK=""
if [ "$WITH_LINK" -eq 1 ] && [ -n "$FROM" ]; then
  if [ -z "$REMOTE" ]; then
    if git remote get-url upstream >/dev/null 2>&1; then REMOTE=upstream; else REMOTE=origin; fi
  fi
  URL="$(git remote get-url "$REMOTE" 2>/dev/null || true)"
  SLUG=""
  case "$URL" in
    git@github.com:*) SLUG="${URL#git@github.com:}" ;;
    https://github.com/*) SLUG="${URL#https://github.com/}" ;;
    ssh://git@github.com/*) SLUG="${URL#ssh://git@github.com/}" ;;
  esac
  SLUG="${SLUG%.git}"
  # 右端：--link-to 优先；否则剥掉 `<远端>/` 前缀。
  # GitHub compare 不认 `origin/main` 这类远端跟踪名，直接用会把链接打成 404。
  RIGHT="$LINK_TO"
  if [ -z "$RIGHT" ]; then
    RIGHT="$TO"
    for r in $(git remote 2>/dev/null || true); do
      case "$RIGHT" in
        "$r"/*) RIGHT="${RIGHT#$r/}"; break ;;
      esac
    done
  fi
  if [ -n "$SLUG" ] && [ -n "$RIGHT" ]; then
    LINK="

**Full Changelog**: https://github.com/${SLUG}/compare/${FROM}...${RIGHT}"
  fi
fi

BODY="${NOTES}${LINK}"

if [ -z "$WRITE" ]; then
  printf '%s\n' "$BODY"
  exit 0
fi

# ---------- 写入 CHANGELOG 文件 ----------
DATE="${DATE:-$(date +%F)}"
ESC="$(printf '%s' "$VERSION" | sed 's/[][\\.^$*]/\\&/g')"

if [ -s "$WRITE" ] && { grep -qF "## [${VERSION}]" "$WRITE" || grep -qE "^## ${ESC}([[:space:]]|$)" "$WRITE"; }; then
  echo "已记录 ${VERSION}（${WRITE} 已有该小节），跳过写入" >&2
  exit 3
fi

ENTRY="## [${VERSION}] - ${DATE}

${BODY}"

if [ ! -s "$WRITE" ]; then
  printf '# Changelog\n\n%s\n' "$ENTRY" > "$WRITE"
  echo "CREATED ${WRITE}: ${VERSION}"
  exit 0
fi

TMP_WRITE="$(mktemp)"
ENTRY="$ENTRY" awk '
  BEGIN { entry = ENVIRON["ENTRY"]; done = 0 }
  /^## / && !done { printf "%s\n\n", entry; done = 1 }
  { print }
  END { if (!done) printf "\n%s\n", entry }
' "$WRITE" > "$TMP_WRITE"
mv "$TMP_WRITE" "$WRITE"
echo "WROTE ${WRITE}: ${VERSION}"
exit 0
