#!/usr/bin/env bash
# release-preflight.sh 夹具回归：全部本地临时仓，不访问网络、不需要 gh/glab/node。
#
# 断言的都是「与语言/生态无关」的通用行为：
#   目标版本由调用方给定（--version / --tag）、声明值只做可选回查（边界匹配 + 回报行号）、
#   tag 命名样式从已有 tag 推断（v / demo- / sub/v / core-v / +build）、版本必须领先最新 tag、
#   多版本线拒绝猜、CHANGELOG 任意标题格式、EFFECT_HINTS 只摘可执行行、无 node 时行为一致。
#
# 夹具里出现的文件名（VERSION、RELEASE_NOTES.txt、Chart.yaml、pubspec.yaml…）只是「任意文本 + 数字」，
# 以证明脚本不认识任何清单格式：换任何文件都成立。
#
# 用法：bash skills/git-kit/scripts/tests/release-preflight-test.sh
# 退出码：0 全部通过 / 1 有失败断言。

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRE="${TESTS_DIR}/../release-preflight.sh"
[ -f "$PRE" ] || { echo "找不到 ${PRE}" >&2; exit 1; }

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL %s\n' "$1"
  [ $# -ge 2 ] && printf '     %s\n' "$2"
}

assert_rc() {
  if [ "$RC" -eq "$1" ]; then ok "$2（exit ${RC}）"; else bad "$2" "期望 exit ${1}，实际 ${RC}"; fi
}
assert_kv() {
  if printf '%s\n' "$OUT" | grep -qx -- "$2"; then
    ok "$3"
  else
    bad "$3" "缺少行 ${2}"
  fi
}
assert_contains() {
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) bad "$3" "输出里没有 ${2}" ;;
  esac
}
assert_not_contains() {
  case "$1" in
    *"$2"*) bad "$3" "输出里不应出现 ${2}" ;;
    *) ok "$3" ;;
  esac
}
kv() { printf '%s\n' "$OUT" | grep "^$1=" || true; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# 所有夹具都建在 $TMP 下；先切进去，避免任何相对路径写到调用者工作区。
cd "$TMP" || exit 1

N=0
new_repo() {
  N=$((N + 1))
  REPO="$TMP/repo-${N}"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name test
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
}
# w <相对路径>：把 stdin 写进夹具仓（自动建父目录）。夹具文件只允许落在 $TMP 内。
w() {
  case "$1" in
    /*|..*) echo "夹具路径必须是 $TMP 内的相对路径：$1" >&2; exit 1 ;;
  esac
  mkdir -p "$REPO/$(dirname "$1")"
  cat > "$REPO/$1"
}
commit_all() {
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "${1:-init}"
}
# 本地伪造远端跟踪（避免 fetch）：origin/main 指向当前 HEAD。
# 用不可解析的 host，让平台判定为 unknown —— 被测的不是平台能力，而是版本与 tag 事实。
wire_remote() {
  git -C "$REPO" remote add origin https://example.invalid/example/demo.git
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}
tag() { git -C "$REPO" tag -a "$1" -m "release: $1"; }

run_pre() {
  OUT="$(cd "$REPO" && PATH="$1" bash "$PRE" --no-fetch --no-release-check "${@:2}" 2>&1)"
  RC=$?
}

REAL_PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
command -v git >/dev/null 2>&1 || { echo "找不到 git，无法跑夹具" >&2; exit 1; }

echo "== release-preflight.sh 夹具回归 =="

# 1. 什么都不给 → 要的是「目标版本」，不是「证明仓库有版本信息」
new_repo
printf '1.2.3\n' | w VERSION
commit_all
tag v1.2.2
wire_remote
run_pre "$REAL_PATH"
assert_rc 2 "未给目标版本"
assert_kv "$OUT" "STATE=NEEDS_TARGET" "STATE=NEEDS_TARGET"
assert_kv "$OUT" "BLOCKERS=target-version-unset" "BLOCKERS=target-version-unset"
assert_kv "$OUT" "VERSION_ORIGIN=none" "VERSION_ORIGIN=none"

# 2. 声明版本 + 任意文本文件一致 → READY，并回报命中的行号与原文
new_repo
printf '# note\nversion: 1.2.3\n' | w RELEASE_NOTES.txt
commit_all
tag v1.2.2
wire_remote
run_pre "$REAL_PATH" --version 1.2.3 --version-file RELEASE_NOTES.txt
assert_rc 0 "声明一致"
assert_kv "$OUT" "STATE=READY" "STATE=READY"
assert_kv "$OUT" "VERSION_ORIGIN=declared" "VERSION_ORIGIN=declared"
assert_kv "$OUT" "VERSION=1.2.3" "VERSION 去前缀"
assert_kv "$OUT" "VERSION_IN_FILE=yes" "VERSION_IN_FILE=yes"
assert_kv "$OUT" "VERSION_FILE_LINE=2" "回报命中行号"
assert_contains "$(kv VERSION_FILE_TEXT)" "version: 1.2.3" "回报命中原文"
assert_kv "$OUT" "TARGET_TAG=v1.2.3" "TARGET_TAG 沿用 v 前缀"

# 3. 声明值与文件不符 → 默认只提醒（派生/注入型仓库的常态），严格模式才阻断
new_repo
printf 'version: 1.9.9\n' | w RELEASE_NOTES.txt
commit_all
tag v1.2.2
wire_remote
run_pre "$REAL_PATH" --version 1.2.3 --version-file RELEASE_NOTES.txt
assert_rc 0 "回查不符但默认不阻断"
assert_kv "$OUT" "STATE=READY" "回查不符默认 READY"
assert_kv "$OUT" "VERSION_IN_FILE=no" "VERSION_IN_FILE=no"
assert_kv "$OUT" "VERSION_FILE_HINT=1.9.9" "HINT 回显文件里的真实版本"
assert_contains "$(kv WARN)" "version-declaration-unverified" "WARN 含 version-declaration-unverified"

run_pre "$REAL_PATH" --version 1.2.3 --version-file RELEASE_NOTES.txt --require-version-match
assert_rc 2 "严格模式回查不符即阻断"
assert_kv "$OUT" "STATE=BLOCKED" "严格模式 STATE=BLOCKED"
assert_kv "$OUT" "BLOCKERS=version-not-in-declared-file" "BLOCKERS=version-not-in-declared-file"

# 4. 声明了版本但没给文件 → 不阻断，但如实告警
new_repo
printf 'x\n' | w a.txt
commit_all
tag v1.2.2
wire_remote
run_pre "$REAL_PATH" --version 1.2.3
assert_rc 0 "缺 --version-file"
assert_kv "$OUT" "STATE=READY" "缺 --version-file 仍 READY"
assert_kv "$OUT" "VERSION_IN_FILE=na" "VERSION_IN_FILE=na"
assert_contains "$(kv WARN)" "version-file-undeclared" "WARN 含 version-file-undeclared"

# 5. 版本以 tag 为源时，倒退同样被拦
new_repo
printf 'x\n' | w a.txt
commit_all
tag v3.0.0
wire_remote
run_pre "$REAL_PATH" --tag v1.0.0
assert_rc 2 "tag 为源但倒退"
assert_kv "$OUT" "VERSION_ORIGIN=tag" "VERSION_ORIGIN=tag"
assert_kv "$OUT" "STATE=BLOCKED" "tag 倒退 STATE=BLOCKED"
assert_kv "$OUT" "BLOCKERS=version-not-ahead-of-tag" "BLOCKERS=version-not-ahead-of-tag"
assert_contains "$(kv WARN)" "version-origin-tag" "WARN 含 version-origin-tag"

# 6. tag 已存在 → TAGGED（重跑幂等）
new_repo
printf 'x\n' | w a.txt
commit_all
tag v1.2.3
wire_remote
run_pre "$REAL_PATH" --tag v1.2.3
assert_rc 0 "tag 已存在"
assert_kv "$OUT" "STATE=TAGGED" "STATE=TAGGED"
assert_kv "$OUT" "TAG_EXISTS=yes" "TAG_EXISTS=yes"

# 7. tag 不在稳定分支历史 → BLOCKED
new_repo
printf 'x\n' | w a.txt
commit_all
tag v1.2.3
git -C "$REPO" checkout -q --orphan other
git -C "$REPO" rm -rq --cached . 2>/dev/null || true
printf 'y\n' | w b.txt
commit_all "feat: later"
wire_remote
run_pre "$REAL_PATH" --tag v1.2.3
assert_rc 2 "tag 不在主干"
assert_kv "$OUT" "STATE=BLOCKED" "tag 不在主干 STATE=BLOCKED"
assert_contains "$(kv BLOCKERS)" "tag-not-on-base" "BLOCKERS 含 tag-not-on-base"

# 8. --tag 与 --version 同时给出且不一致 → BLOCKED
new_repo
printf 'version: 1.2.3\n' | w RELEASE_NOTES.txt
commit_all
tag v1.1.0
wire_remote
run_pre "$REAL_PATH" --version 1.2.3 --version-file RELEASE_NOTES.txt --tag v1.4.0
assert_rc 2 "tag 与版本不一致"
assert_contains "$(kv BLOCKERS)" "tag-version-mismatch" "BLOCKERS 含 tag-version-mismatch"

# 9/10. --version-file 参数边界
new_repo
printf 'x\n' | w a.txt
commit_all
wire_remote
run_pre "$REAL_PATH" --version 1.0.0 --version-file nope.txt
assert_rc 1 "版本源文件不存在"
assert_contains "$OUT" "不存在" "报错说明版本源文件不存在"
run_pre "$REAL_PATH" --version 1.0.0 --version-file ../outside.txt
assert_rc 1 "版本源文件跳出仓库"

# 11. <pkg>-v 风格前缀（core-v1.2.3）
new_repo
printf 'x\n' | w a.txt
commit_all
tag core-v1.2.3
wire_remote
run_pre "$REAL_PATH" --version 1.3.0
assert_kv "$OUT" "TAG_PREFIX=core-v" "TAG_PREFIX=core-v"
assert_kv "$OUT" "TARGET_TAG=core-v1.3.0" "TARGET_TAG 沿用 core-v"
assert_kv "$OUT" "STATE=READY" "前缀 tag 下版本领先判定正确"

# 12. <prefix>-N 风格前缀（Helm 的 demo-1.0.0）
new_repo
printf 'apiVersion: v2\nversion: 1.0.0\nappVersion: "2.5.0"\n' | w Chart.yaml
commit_all
tag demo-1.0.0
wire_remote
run_pre "$REAL_PATH" --version 1.1.0 --version-file Chart.yaml
assert_kv "$OUT" "TAG_PREFIX=demo-" "TAG_PREFIX=demo-"
assert_kv "$OUT" "TARGET_TAG=demo-1.1.0" "TARGET_TAG 沿用 demo-"
assert_kv "$OUT" "LATEST_SEMVER=yes" "demo-1.0.0 被视为可比较版本"
assert_kv "$OUT" "VERSION_FILE_HINT=1.0.0" "HINT 给出 chart 自身的 1.0.0"
assert_kv "$OUT" "STATE=READY" "Helm 风格可发"

# 12b. 双版本文件（version / appVersion）：回查命中不等于语义正确 → 必须能看到命中的是哪一行
new_repo
printf 'apiVersion: v2\nversion: 1.0.0\nappVersion: "2.5.0"\n' | w Chart.yaml
commit_all
tag demo-1.0.0
wire_remote
run_pre "$REAL_PATH" --version 2.5.0 --version-file Chart.yaml
assert_kv "$OUT" "VERSION_IN_FILE=yes" "双版本文件里 2.5.0 命中（appVersion）"
assert_kv "$OUT" "VERSION_FILE_LINE=3" "命中行号指出是第 3 行（appVersion）"
assert_contains "$(kv VERSION_FILE_TEXT)" "appVersion" "原文让调用方看出命中的是 appVersion"

# 13. +build（Dart 的 1.2.3+45）：内核可解析、可比较，不被静默跳过
new_repo
printf 'name: demo\nversion: 1.2.3+45\n' | w pubspec.yaml
commit_all
tag v1.2.2
tag v1.2.3+45
wire_remote
run_pre "$REAL_PATH" --version 1.2.3+45 --version-file pubspec.yaml
assert_kv "$OUT" "VERSION=1.2.3+45" "保留 +build"
assert_kv "$OUT" "VERSION_IN_FILE=yes" "边界匹配命中完整 token"
assert_kv "$OUT" "LATEST_TAG=v1.2.3+45" "+build 的 tag 被认成版本 tag"
assert_kv "$OUT" "STATE=TAGGED" "同名 tag 已存在 → TAGGED"

# 14. 非版本 tag 仓 → LATEST_SEMVER=no + 告警
new_repo
printf 'x\n' | w a.txt
commit_all
tag nightly-2026-10-01
wire_remote
run_pre "$REAL_PATH" --tag v1.0.0
assert_kv "$OUT" "LATEST_SEMVER=no" "LATEST_SEMVER=no"
assert_kv "$OUT" "LATEST_TAG=<none>" "没有可解析的版本 tag"
assert_contains "$(kv WARN)" "no-version-like-tags" "WARN 含 no-version-like-tags"

# 15. 多版本线：--version 推不出打哪条线 → 拒绝猜；显式 --tag 放行
new_repo
printf '1.4.0\n' | w a/VERSION
printf '0.9.2\n' | w b/VERSION
commit_all
tag a-v1.3.0
tag b-v0.9.1
wire_remote
run_pre "$REAL_PATH" --version 1.4.0 --version-file a/VERSION
assert_rc 2 "多线 + --version"
assert_kv "$OUT" "STATE=BLOCKED" "多线 STATE=BLOCKED"
assert_kv "$OUT" "BLOCKERS=target-tag-ambiguous" "BLOCKERS=target-tag-ambiguous"
assert_contains "$(kv WARN)" "mixed-tag-prefixes" "WARN 含 mixed-tag-prefixes"
run_pre "$REAL_PATH" --version 1.4.0 --version-file a/VERSION --tag a-v1.4.0
assert_rc 0 "显式 tag 放行"
assert_kv "$OUT" "TARGET_TAG=a-v1.4.0" "显式 tag 原样使用"
assert_kv "$OUT" "STATE=READY" "显式 tag 后 READY"

# 16-18. CHANGELOG 任意标题格式都认；不能被更大版本号误命中；可自定义路径
new_repo
printf 'version: 1.2.3\n' | w RELEASE_NOTES.txt
printf '# Changelog\n\n## 1.2.3\n\n- done\n' | w CHANGELOG.md
commit_all
tag v1.2.2
wire_remote
run_pre "$REAL_PATH" --version 1.2.3 --version-file RELEASE_NOTES.txt
assert_kv "$OUT" "CHANGELOG=CHANGELOG.md" "CHANGELOG 被探测到"
assert_kv "$OUT" "CHANGELOG_HAS_VERSION=yes" "无方括号/无 v 的标题也认"

new_repo
printf 'version: 1.2.3\n' | w RELEASE_NOTES.txt
printf '# Changelog\n\n## [v11.2.3] - 2026-10-22\n' | w CHANGELOG.md
commit_all
tag v1.2.2
wire_remote
run_pre "$REAL_PATH" --version 1.2.3 --version-file RELEASE_NOTES.txt
assert_kv "$OUT" "CHANGELOG_HAS_VERSION=no" "11.2.3 不误命中 1.2.3"

new_repo
printf 'version: 1.2.3\n' | w RELEASE_NOTES.txt
printf '## v1.2.3 - 2026-10-22\n' | w docs/history.md
commit_all
tag v1.2.2
wire_remote
run_pre "$REAL_PATH" --version 1.2.3 --version-file RELEASE_NOTES.txt --changelog docs/history.md
assert_kv "$OUT" "CHANGELOG=docs/history.md" "--changelog 覆盖生效"
assert_kv "$OUT" "CHANGELOG_HAS_VERSION=yes" "v 前缀 + 日期后缀的标题也认"

# 19. EFFECT_HINTS 只摘可执行行（run:/uses:），不摘 job/step 名
new_repo
printf 'x\n' | w a.txt
w .github/workflows/release.yml <<'YML'
name: release
on:
  push:
    tags: ['v*']
jobs:
  publish:
    name: Pre-publish checks
    runs-on: ubuntu-latest
    steps:
      - run: ./tool publish --channel beta
YML
commit_all
wire_remote
run_pre "$REAL_PATH" --tag v1.0.0
assert_kv "$OUT" "TAG_WORKFLOWS=release.yml" "TAG_WORKFLOWS 识别 tags:"
assert_contains "$(kv EFFECT_HINTS)" "release.yml:10:" "EFFECT_HINTS 带 file:line"
assert_contains "$(kv EFFECT_HINTS)" "publish --channel beta" "EFFECT_HINTS 摘到发布命令原文"
assert_not_contains "$(kv EFFECT_HINTS)" "Pre-publish checks" "step 名不进 EFFECT_HINTS"
assert_not_contains "$(kv EFFECT_HINTS)" "publish:" "job 键不进 EFFECT_HINTS"

# 20. CI 负责建 Release 的信号仍然只探测、不建
new_repo
printf 'x\n' | w a.txt
w .github/workflows/release.yml <<'YML'
on:
  push:
    tags: ['v*']
jobs:
  rel:
    runs-on: ubuntu-latest
    steps:
      - uses: softprops/action-gh-release@v2
YML
commit_all
wire_remote
run_pre "$REAL_PATH" --tag v1.0.0 --platform github
assert_kv "$OUT" "EFFECT_RELEASE=workflow" "EFFECT_RELEASE=workflow"
assert_kv "$OUT" "CI_SYSTEM=github" "CI_SYSTEM=github"

# 21. 零 node 依赖
new_repo
printf 'version: 1.2.3\n' | w RELEASE_NOTES.txt
commit_all
tag v1.2.2
wire_remote
NO_NODE_BIN="$TMP/no-node-bin"
mkdir -p "$NO_NODE_BIN"
for c in git awk sed grep tr head cut mktemp rm cat date sort dirname env bash sh uname id; do
  p="$(command -v "$c" 2>/dev/null || true)"
  [ -n "$p" ] && ln -sf "$p" "$NO_NODE_BIN/$c"
done
run_pre "$NO_NODE_BIN" --version 1.2.3 --version-file RELEASE_NOTES.txt
assert_rc 0 "无 node 也能跑"
assert_kv "$OUT" "STATE=READY" "无 node 时 STATE=READY"
assert_kv "$OUT" "VERSION=1.2.3" "无 node 时仍读到声明版本"

# 22. 脏工作区只告警
new_repo
printf 'version: 1.2.3\n' | w RELEASE_NOTES.txt
printf 'x\n' | w a.txt
commit_all
tag v1.2.2
wire_remote
printf 'dirty\n' >> "$REPO/a.txt"
run_pre "$REAL_PATH" --version 1.2.3 --version-file RELEASE_NOTES.txt
assert_rc 0 "脏工作区不阻断"
assert_contains "$(kv WARN)" "dirty-worktree" "WARN 含 dirty-worktree"

# 23. 首个版本（还没任何 tag）
new_repo
printf 'version: 0.1.0\n' | w VERSION
commit_all
wire_remote
run_pre "$REAL_PATH" --version 0.1.0 --version-file VERSION
assert_rc 0 "首个版本"
assert_kv "$OUT" "STATE=READY" "首个版本 STATE=READY"
assert_kv "$OUT" "LATEST_TAG=<none>" "无 tag 时 LATEST_TAG=<none>"
assert_kv "$OUT" "TARGET_TAG=v0.1.0" "首个版本默认 v 前缀"

# 24. 输入归一化：--version 带 v 前缀、--tag 只给裸数字
new_repo
printf 'version: 1.2.3\n' | w VERSION
commit_all
tag v1.2.2
wire_remote
run_pre "$REAL_PATH" --version v1.2.3 --version-file VERSION
assert_kv "$OUT" "VERSION=1.2.3" "--version v 前缀被归一化"
assert_kv "$OUT" "TARGET_TAG=v1.2.3" "tag 不出现双 v"
run_pre "$REAL_PATH" --tag 1.2.4
assert_kv "$OUT" "TARGET_TAG=v1.2.4" "--tag 裸数字补前缀"

# 25. 注入型版本（Go 的 dev 占位）：默认不阻断，严格模式才阻断
new_repo
printf 'package version\n\nvar Version = "dev"\n' | w internal/version.go
commit_all
tag v1.2.2
wire_remote
run_pre "$REAL_PATH" --version 1.2.3 --version-file internal/version.go
assert_rc 0 "注入型版本不阻断"
assert_kv "$OUT" "STATE=READY" "注入型 STATE=READY"
assert_contains "$(kv WARN)" "version-declaration-unverified" "WARN 提示未回查通过"
run_pre "$REAL_PATH" --version 1.2.3 --version-file internal/version.go --require-version-match
assert_rc 2 "严格模式下注入型阻断"
assert_kv "$OUT" "BLOCKERS=version-not-in-declared-file" "严格模式 BLOCKERS"

# ---------- 汇总 ----------
echo
if [ "$FAIL" -eq 0 ]; then
  echo "全部通过：${PASS} 条断言"
  exit 0
fi
echo "失败：${FAIL} 条（通过 ${PASS} 条）"
exit 1
