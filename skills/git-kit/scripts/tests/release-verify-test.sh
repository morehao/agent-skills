#!/usr/bin/env bash
# release-verify.sh 夹具回归：不访问 GitHub / GitLab / npm，全部由 PATH 里的桩代替。
#
# 覆盖：GitHub 完成/失败、`gh run watch` 路径、Release 缺失、npm 200/404/回退、
#       GitLab 成功/失败/无 pipeline/超时、CLI 缺失、无 host、平台 unknown、npm URL 编码。
#
# 用法：bash skills/git-kit/scripts/tests/release-verify-test.sh
# 退出码：0 全部通过 / 1 有失败断言。

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="${TESTS_DIR}/../release-verify.sh"
[ -f "$VERIFY" ] || { echo "找不到 ${VERIFY}" >&2; exit 1; }

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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
git -C "$REPO" remote add origin git@github.com:example/repo.git

BIN="$TMP/bin"
mkdir -p "$BIN"
TEST_PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
NO_CLI_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# ---------- 桩：gh ----------
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
jq_expr=""
prev=""
for a in "$@"; do
  [ "$prev" = "--jq" ] && jq_expr="$a"
  prev="$a"
done
apply() { /usr/bin/jq -r "$jq_expr"; }

case "$1 $2" in
  "run list")
    if [ -n "${GH_LIST_FAIL:-}" ]; then echo "$GH_LIST_FAIL" >&2; exit 1; fi
    printf '%s' "${GH_RUN_LIST_JSON:-[]}" | apply
    ;;
  "run view")
    n=0
    [ -f "${GH_VIEW_COUNTER:-}" ] && n="$(cat "$GH_VIEW_COUNTER")"
    n=$((n + 1))
    [ -n "${GH_VIEW_COUNTER:-}" ] && echo "$n" > "$GH_VIEW_COUNTER"
    if [ "${GH_VIEW_RUNNING_FIRST:-0}" = 1 ] && [ "$n" -eq 1 ]; then
      printf '%s' "${GH_RUN_VIEW_RUNNING_JSON:-}" | apply
    else
      printf '%s' "${GH_RUN_VIEW_JSON:-}" | apply
    fi
    ;;
  "run watch")
    [ -n "${GH_WATCH_LOG:-}" ] && echo "$*" >> "$GH_WATCH_LOG"
    [ -n "${GH_WATCH_FAIL:-}" ] && exit 1
    exit 0
    ;;
  "release view")
    if [ "${GH_RELEASE_MISSING:-0}" = 1 ]; then echo "release not found" >&2; exit 1; fi
    printf '%s' "${GH_RELEASE_JSON:-}" | apply
    ;;
  *)
    echo "stub gh: unsupported $*" >&2
    exit 99
    ;;
esac
STUB
chmod +x "$BIN/gh"

# ---------- 桩：glab ----------
cat > "$BIN/glab" <<'STUB'
#!/usr/bin/env bash
jq_expr=""
prev=""
for a in "$@"; do
  [ "$prev" = "--jq" ] && jq_expr="$a"
  prev="$a"
done
apply() { /usr/bin/jq -r "$jq_expr"; }

case "$1 $2" in
  "ci list")
    n=0
    [ -f "${GL_VIEW_COUNTER:-}" ] && n="$(cat "$GL_VIEW_COUNTER")"
    n=$((n + 1))
    [ -n "${GL_VIEW_COUNTER:-}" ] && echo "$n" > "$GL_VIEW_COUNTER"
    if [ "${GL_RUNNING_FIRST:-0}" = 1 ] && [ "$n" -eq 1 ]; then
      printf '%s' "${GL_CI_RUNNING_JSON:-}" | apply
    else
      printf '%s' "${GL_CI_JSON:-[]}" | apply
    fi
    ;;
  "release view")
    if [ "${GL_RELEASE_MISSING:-0}" = 1 ]; then echo "404 Not Found" >&2; exit 1; fi
    printf '%s' "${GL_RELEASE_JSON:-}" | apply
    ;;
  *)
    echo "stub glab: unsupported $*" >&2
    exit 99
    ;;
esac
STUB
chmod +x "$BIN/glab"

# ---------- 桩：curl ----------
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
out=""
url=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
[ -n "${CURL_LOG:-}" ] && printf '%s\n' "$url" >> "$CURL_LOG"
code="${CURL_CODE:-200}"
case "$code" in
  200)
    [ -n "$out" ] && printf '{"name":"pkg","version":"1.2.3"}' > "$out"
    printf '200'
    ;;
  404)
    [ -n "$out" ] && printf '{"error":"Not found"}' > "$out"
    printf '404'
    ;;
  *)
    exit 7
    ;;
esac
STUB
chmod +x "$BIN/curl"

# ---------- 桩：npm ----------
cat > "$BIN/npm" <<'STUB'
#!/usr/bin/env bash
[ -n "${NPM_LOG:-}" ] && echo "$*" >> "$NPM_LOG"
if [ "${NPM_RC:-0}" -ne 0 ]; then
  echo "npm ERR! code E404" >&2
  exit "${NPM_RC}"
fi
echo "1.2.3"
STUB
chmod +x "$BIN/npm"

OUT=""
RC=0
run_verify() {
  OUT="$(cd "$REPO" && PATH="$1" bash "$VERIFY" "${@:2}" 2>&1)"
  RC=$?
}

reset_state() {
  rm -rf "$TMP/state"
  mkdir -p "$TMP/state"
  export GH_VIEW_COUNTER="$TMP/state/gh-views"
  export GL_VIEW_COUNTER="$TMP/state/gl-views"
  export GH_WATCH_LOG="$TMP/state/watch.log"
  export CURL_LOG="$TMP/state/curl.log"
  export NPM_LOG="$TMP/state/npm.log"
  unset GH_LIST_FAIL GH_VIEW_RUNNING_FIRST GH_WATCH_FAIL GH_RELEASE_MISSING
  unset GL_RUNNING_FIRST GL_RELEASE_MISSING CURL_CODE NPM_RC 2>/dev/null || true
  export GH_RUN_LIST_JSON='[]'
  export GH_RUN_VIEW_JSON='{}'
  export GL_CI_JSON='[]'
  export GL_RELEASE_JSON='{}'
  export GH_RELEASE_JSON='{}'
}

GH_OK_LIST='[{"databaseId":101,"headBranch":"v1.2.3","status":"completed","conclusion":"success","url":"https://github.com/example/repo/actions/runs/101","workflowName":"release.yml"}]'
GH_RUNNING='{"status":"in_progress","conclusion":"","url":"https://github.com/example/repo/actions/runs/101","workflowName":"release.yml","createdAt":"2026-10-22T08:13:38Z","updatedAt":"2026-10-22T08:13:40Z"}'
GH_DONE='{"status":"completed","conclusion":"success","url":"https://github.com/example/repo/actions/runs/101","workflowName":"release.yml","createdAt":"2026-10-22T08:13:38Z","updatedAt":"2026-10-22T08:14:01Z"}'
GH_DONE_FAIL='{"status":"completed","conclusion":"failure","url":"https://github.com/example/repo/actions/runs/101","workflowName":"release.yml","createdAt":"2026-10-22T08:13:38Z","updatedAt":"2026-10-22T08:13:55Z"}'
GH_REL='{"tagName":"v1.2.3","url":"https://github.com/example/repo/releases/tag/v1.2.3","body":"notes here","isDraft":false,"isPrerelease":false}'

echo "== release-verify.sh 夹具回归 =="

# 1. GitHub 全绿（已完成 → 首查即回执，不 watch）
reset_state
export GH_RUN_LIST_JSON="$GH_OK_LIST"
export GH_RUN_VIEW_JSON="$GH_DONE"
export GH_RELEASE_JSON="$GH_REL"
export CURL_CODE=200
run_verify "$TEST_PATH" --platform github --tag v1.2.3 --repo example/repo --npm-pkg @scope/pkg --timeout 5 --interval 1
assert_rc 0 "GitHub 全绿"
assert_kv "$OUT" "CI_STATUS=success" "GitHub CI success"
assert_kv "$OUT" "CI_WORKFLOW=release.yml" "GitHub workflow 名"
assert_kv "$OUT" "CI_DURATION_S=23" "GitHub 耗时"
assert_kv "$OUT" "RELEASE_STATUS=exists" "GitHub Release exists"
assert_kv "$OUT" "RELEASE_NOTES=nonempty" "GitHub notes 非空"
assert_kv "$OUT" "NPM_STATUS=visible" "npm 可见"
assert_kv "$OUT" "NPM_SOURCE=registry" "npm 走 registry"
assert_kv "$OUT" "VERIFY_RESULT=pass" "结论 pass"
assert_contains "$(cat "$CURL_LOG" 2>/dev/null)" "@scope%2Fpkg/1.2.3" "scoped 包名按 %2F 编码"
[ -f "$GH_WATCH_LOG" ] && bad "已完成不应再 watch" "watch 被调用了" || ok "已完成不 watch"

# 2. GitHub 首查 running → 走 watch → 完成即停
reset_state
export GH_RUN_LIST_JSON="$GH_OK_LIST"
export GH_VIEW_RUNNING_FIRST=1
export GH_RUN_VIEW_RUNNING_JSON="$GH_RUNNING"
export GH_RUN_VIEW_JSON="$GH_DONE"
export GH_RELEASE_JSON="$GH_REL"
run_verify "$TEST_PATH" --platform github --tag v1.2.3 --run-id 101 --no-npm --timeout 5 --interval 1
assert_rc 0 "GitHub watch 路径"
assert_kv "$OUT" "CI_STATUS=success" "watch 后 success"
[ -s "$GH_WATCH_LOG" ] && ok "调用了 gh run watch" || bad "调用了 gh run watch" "没有 watch 日志"

# 3. GitHub CI 失败
reset_state
export GH_RUN_LIST_JSON="$GH_OK_LIST"
export GH_RUN_VIEW_JSON="$GH_DONE_FAIL"
export GH_RELEASE_JSON="$GH_REL"
run_verify "$TEST_PATH" --platform github --tag v1.2.3 --no-npm --timeout 5 --interval 1
assert_rc 2 "GitHub CI 失败"
assert_kv "$OUT" "CI_STATUS=failure" "CI failure"
assert_kv "$OUT" "VERIFY_RESULT=fail" "结论 fail"

# 4. Release 缺失 + npm 404
reset_state
export GH_RUN_LIST_JSON="$GH_OK_LIST"
export GH_RUN_VIEW_JSON="$GH_DONE"
export GH_RELEASE_MISSING=1
export CURL_CODE=404
run_verify "$TEST_PATH" --platform github --tag v1.2.3 --npm-pkg pkg --timeout 5 --interval 1
assert_rc 2 "Release 缺失 + npm 404"
assert_kv "$OUT" "RELEASE_STATUS=missing" "Release missing"
assert_kv "$OUT" "NPM_STATUS=missing" "npm missing"
assert_contains "$(printf '%s\n' "$OUT" | grep '^VERIFY_REASONS=')" "release-missing" "原因含 release-missing"
assert_contains "$(printf '%s\n' "$OUT" | grep '^VERIFY_REASONS=')" "npm-missing" "原因含 npm-missing"

# 5. npm registry 失败 → 回退 npm CLI（隔离 cache）
reset_state
export GH_RUN_LIST_JSON="$GH_OK_LIST"
export GH_RUN_VIEW_JSON="$GH_DONE"
export GH_RELEASE_JSON="$GH_REL"
export CURL_CODE=500
export NPM_RC=0
run_verify "$TEST_PATH" --platform github --tag v1.2.3 --npm-pkg pkg --timeout 5 --interval 1
assert_rc 0 "npm 回退 npm CLI"
assert_kv "$OUT" "NPM_STATUS=visible" "回退后 visible"
assert_kv "$OUT" "NPM_SOURCE=npm-cli" "来源 npm-cli"
assert_contains "$(cat "$NPM_LOG" 2>/dev/null)" "--cache" "npm 回退带隔离 --cache"

# 6. CLI 缺失（PATH 无 gh/glab）
reset_state
run_verify "$NO_CLI_PATH" --platform github --tag v1.2.3 --repo example/repo --no-npm
assert_rc 3 "CLI 缺失"
assert_kv "$OUT" "CI_STATUS=unknown" "CLI 缺失 CI unknown"
assert_kv "$OUT" "RELEASE_STATUS=unknown" "CLI 缺失 Release unknown"
assert_contains "$(printf '%s\n' "$OUT" | grep '^VERIFY_REASONS=')" "cli-missing" "原因含 cli-missing"

# 7. 无 host / 平台 unknown
reset_state
git -C "$REPO" remote set-url origin file:///srv/git/repo.git
run_verify "$TEST_PATH" --tag v1.2.3 --no-npm
assert_rc 3 "无 host"
assert_kv "$OUT" "VERIFY_PLATFORM=unknown" "无 host → platform unknown"
assert_contains "$(printf '%s\n' "$OUT" | grep '^VERIFY_REASONS=')" "platform-unsupported" "原因含 platform-unsupported"
git -C "$REPO" remote set-url origin git@github.com:example/repo.git

# 8. GitLab 全绿
reset_state
export GL_CI_JSON='[{"id":42,"status":"success","web_url":"https://gitlab.com/example/repo/-/pipelines/42","duration":95,"ref":"v1.2.3"}]'
export GL_RELEASE_JSON='{"tag_name":"v1.2.3","name":"v1.2.3","description":"notes here"}'
export CURL_CODE=200
run_verify "$TEST_PATH" --platform gitlab --tag v1.2.3 --repo example/repo --npm-pkg pkg --timeout 5 --interval 1
assert_rc 0 "GitLab 全绿"
assert_kv "$OUT" "CI_STATUS=success" "GitLab success"
assert_kv "$OUT" "CI_ID=42" "GitLab pipeline id"
assert_kv "$OUT" "CI_DURATION_S=95" "GitLab 耗时"
assert_kv "$OUT" "RELEASE_STATUS=exists" "GitLab Release exists"
assert_kv "$OUT" "NPM_STATUS=visible" "GitLab npm visible"

# 9. GitLab pipeline 失败
reset_state
export GL_CI_JSON='[{"id":42,"status":"failed","web_url":"https://gitlab.com/example/repo/-/pipelines/42","duration":20,"ref":"v1.2.3"}]'
export GL_RELEASE_JSON='{"tag_name":"v1.2.3","name":"v1.2.3","description":"notes"}'
run_verify "$TEST_PATH" --platform gitlab --tag v1.2.3 --no-npm --timeout 5 --interval 1
assert_rc 2 "GitLab pipeline 失败"
assert_kv "$OUT" "CI_STATUS=failure" "GitLab failure"

# 10. GitLab 无 pipeline
reset_state
export GL_CI_JSON='[]'
export GL_RELEASE_JSON='{"tag_name":"v1.2.3","name":"v1.2.3","description":"notes"}'
run_verify "$TEST_PATH" --platform gitlab --tag v1.2.3 --no-npm --timeout 5 --interval 1
assert_rc 3 "GitLab 无 pipeline"
assert_kv "$OUT" "CI_STATUS=missing" "GitLab pipeline missing"

# 11. GitLab 首查 running → 轮询到 success
reset_state
export GL_RUNNING_FIRST=1
export GL_CI_RUNNING_JSON='[{"id":42,"status":"running","web_url":"https://gitlab.com/example/repo/-/pipelines/42","duration":null,"ref":"v1.2.3"}]'
export GL_CI_JSON='[{"id":42,"status":"success","web_url":"https://gitlab.com/example/repo/-/pipelines/42","duration":95,"ref":"v1.2.3"}]'
export GL_RELEASE_JSON='{"tag_name":"v1.2.3","name":"v1.2.3","description":"notes"}'
run_verify "$TEST_PATH" --platform gitlab --tag v1.2.3 --no-npm --timeout 5 --interval 1
assert_rc 0 "GitLab 轮询到 success"
assert_kv "$OUT" "CI_STATUS=success" "GitLab 轮询 success"

# 12. GitLab 超时
reset_state
export GL_CI_JSON='[{"id":42,"status":"running","web_url":"https://gitlab.com/example/repo/-/pipelines/42","duration":null,"ref":"v1.2.3"}]'
export GL_RELEASE_JSON='{"tag_name":"v1.2.3","name":"v1.2.3","description":"notes"}'
run_verify "$TEST_PATH" --platform gitlab --tag v1.2.3 --no-npm --timeout 1 --interval 1
assert_rc 2 "GitLab 超时"
assert_kv "$OUT" "CI_STATUS=timeout" "GitLab timeout"

# 13. GitLab skipped / manual 不判成功
reset_state
export GL_CI_JSON='[{"id":42,"status":"skipped","web_url":"https://gitlab.com/example/repo/-/pipelines/42","duration":0,"ref":"v1.2.3"}]'
export GL_RELEASE_JSON='{"tag_name":"v1.2.3","name":"v1.2.3","description":"notes"}'
run_verify "$TEST_PATH" --platform gitlab --tag v1.2.3 --no-npm --timeout 5 --interval 1
assert_rc 3 "GitLab skipped 不判成功"
assert_kv "$OUT" "CI_STATUS=skipped" "GitLab skipped 状态"
assert_kv "$OUT" "VERIFY_RESULT=unknown" "skipped 结论 unknown"

# 14. Release notes 为空 → 失败
reset_state
export GH_RUN_LIST_JSON="$GH_OK_LIST"
export GH_RUN_VIEW_JSON="$GH_DONE"
export GH_RELEASE_JSON='{"tagName":"v1.2.3","url":"https://github.com/example/repo/releases/tag/v1.2.3","body":"","isDraft":false,"isPrerelease":false}'
run_verify "$TEST_PATH" --platform github --tag v1.2.3 --no-npm --timeout 5 --interval 1
assert_rc 2 "Release notes 为空"
assert_kv "$OUT" "RELEASE_NOTES=empty" "notes empty"
assert_contains "$(printf '%s\n' "$OUT" | grep '^VERIFY_REASONS=')" "release-notes-empty" "原因含 release-notes-empty"

# ---------- 汇总 ----------
echo
if [ "$FAIL" -eq 0 ]; then
  echo "全部通过：${PASS} 条断言"
  exit 0
fi
echo "失败：${FAIL} 条（通过 ${PASS} 条）"
exit 1
