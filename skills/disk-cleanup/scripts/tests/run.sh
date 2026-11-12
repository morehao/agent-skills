#!/usr/bin/env bash
# disk-cleanup v2 测试入口：纯 bash，无 bats / 无第三方框架，Linux 与 macOS 都能跑。
#
# 安全红线：
#   - 进程一启动就把 HOME 指到 `mktemp -d` 的假目录，所有用例只在假 HOME 下删除；
#   - 退出时只清理「带固定前缀」的那个临时目录（先校验前缀再删），不碰真实数据；
#   - 用例里禁止 stat -f / gdate / md5 这类 macOS 专有写法，只用两边都有的命令。
#
# 本文件里的 rm 只用于清理自己创建的临时目录；运行期脚本的删除必须走
# lib/safety.sh 的 dc_funnel_rm（由 scripts/check-disk-cleanup-safety.mjs 门禁）。
#
# 用法：bash skills/disk-cleanup/scripts/tests/run.sh
# 退出码：0 全绿 / 1 有断言失败

set -uo pipefail

DC_TESTS_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DC_SKILL_DIR=$(cd -P -- "$DC_TESTS_DIR/../.." && pwd -P)
DC_SCRIPTS_DIR="$DC_SKILL_DIR/scripts"
DC_CASES_DIR="$DC_TESTS_DIR/cases"
DC_SCRIPT="$DC_SCRIPTS_DIR/mac_cleanup.sh"
DC_CODES_TSV="$DC_SCRIPTS_DIR/data/codes.tsv"
DC_PROTECT_TSV="$DC_SCRIPTS_DIR/data/protect.tsv"

# lib 里的函数按 DC_SCRIPT_DIR 找 data/，必须导出，子进程（bash -c）也要能拿到
DC_SCRIPT_DIR="$DC_SCRIPTS_DIR"
export DC_SCRIPT_DIR

DC_ORIG_HOME="${HOME:-}"
DC_TMPHOME=$(mktemp -d "${TMPDIR:-/tmp}/dc-cleanup-tests.XXXXXX") || {
    printf '无法创建测试用临时目录（mktemp -d 失败）\n' >&2
    exit 1
}

# 先挡真实 HOME：任何用例都不许触碰用户数据
export HOME="$DC_TMPHOME"
export DC_AUDIT_LOG="$DC_TMPHOME/.dc-test-audit.log"

dc_tests_cleanup() {
    if [[ -n "${DC_TMPHOME:-}" && -d "${DC_TMPHOME:-}" ]]; then
        case "$DC_TMPHOME" in
            "${TMPDIR:-/tmp}"/dc-cleanup-tests.*|/tmp/dc-cleanup-tests.*)
                rm -rf -- "$DC_TMPHOME"
                ;;
            *)
                printf '警告：临时目录前缀不符，拒绝清理：%s\n' "$DC_TMPHOME" >&2
                ;;
        esac
    fi
}
trap dc_tests_cleanup EXIT
# 被中断/超时杀掉时也把假 HOME 收掉（EXIT trap 不会因 SIGTERM 自动执行）
trap 'dc_tests_cleanup; exit 1' INT TERM

# ---------- 载入内核（与 mac_cleanup.sh 相同的顺序，但不跑主流程） ----------
for _dc_lib in timeout core probe safety audit report; do
    _dc_lib_file="$DC_SCRIPTS_DIR/lib/${_dc_lib}.sh"
    if [[ ! -r "$_dc_lib_file" ]]; then
        printf '缺少内核文件：%s\n' "$_dc_lib_file" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    . "$_dc_lib_file"
done
unset _dc_lib _dc_lib_file

# 目标实现（队友并行开发，可能只到一半）：载入后用于「未实现的 target 跳过而不是失败」的判定
for _dc_target in "$DC_SCRIPTS_DIR"/lib/targets/*.sh; do
    [[ -f "$_dc_target" ]] || continue
    # shellcheck disable=SC1090
    . "$_dc_target"
done
unset _dc_target

if ! dc_codes_load; then
    printf '无法加载 %s\n' "$DC_CODES_TSV" >&2
    exit 1
fi
dc_protect_load

# ---------- 断言 ----------
DC_ASSERT_COUNT=0
DC_FAIL_COUNT=0
DC_CASE_ASSERTS=0
DC_CASE_FAILS=0
DC_SKIP_COUNT=0
DC_CASES=()
DC_CURRENT_CASE=""

dc_assert_begin() {
    DC_ASSERT_COUNT=$((DC_ASSERT_COUNT + 1))
    DC_CASE_ASSERTS=$((DC_CASE_ASSERTS + 1))
}

dc_fail() {
    DC_FAIL_COUNT=$((DC_FAIL_COUNT + 1))
    DC_CASE_FAILS=$((DC_CASE_FAILS + 1))
    printf '      ✗ %s\n' "$*"
}

# dc_assert_eq <期望> <实际> <说明>
dc_assert_eq() {
    dc_assert_begin
    if [[ "${1-}" == "${2-}" ]]; then return 0; fi
    dc_fail "${3-}：期望 [${1-}]，实际 [${2-}]"
    return 1
}

# dc_assert_ok <说明> <命令...>
dc_assert_ok() {
    local msg="$1" out rc=0
    shift
    out=$("$@" 2>&1) || rc=$?
    dc_assert_begin
    if [[ "$rc" -eq 0 ]]; then return 0; fi
    dc_fail "${msg}：期望成功，实际 exit ${rc}${out:+｜输出：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)}"
    return 1
}

# dc_assert_exit <期望退出码> <说明> <命令...>
dc_assert_exit() {
    local want="$1" msg="$2" out rc=0
    shift 2
    out=$("$@" 2>&1) || rc=$?
    dc_assert_begin
    if [[ "$rc" -eq "$want" ]]; then return 0; fi
    dc_fail "${msg}：期望 exit ${want}，实际 ${rc}${out:+｜输出：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)}"
    return 1
}

# dc_assert_nonzero <说明> <命令...>
dc_assert_nonzero() {
    local msg="$1" out rc=0
    shift
    out=$("$@" 2>&1) || rc=$?
    dc_assert_begin
    if [[ "$rc" -ne 0 ]]; then return 0; fi
    dc_fail "${msg}：期望非 0 退出，实际 exit 0${out:+｜输出：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)}"
    return 1
}

# dc_assert_rc_zero <实际退出码> <说明>
dc_assert_rc_zero() {
    dc_assert_begin
    if [[ "${1-0}" -eq 0 ]]; then return 0; fi
    dc_fail "${2-}：期望 exit 0，实际 ${1-0}"
    return 1
}

# dc_assert_rc_nonzero <实际退出码> <说明>
dc_assert_rc_nonzero() {
    dc_assert_begin
    if [[ "${1-0}" -ne 0 ]]; then return 0; fi
    dc_fail "${2-}：期望非 0 退出，实际 0"
    return 1
}

# dc_assert_le <上限> <实际> <说明>
dc_assert_le() {
    dc_assert_begin
    if [[ "${2-0}" -le "${1-0}" ]]; then return 0; fi
    dc_fail "${3-}：期望 ≤ ${1-0}，实际 ${2-0}"
    return 1
}

# dc_assert_gt <下限> <实际> <说明>
dc_assert_gt() {
    dc_assert_begin
    if [[ "${2-0}" -gt "${1-0}" ]]; then return 0; fi
    dc_fail "${3-}：期望 > ${1-0}，实际 ${2-0}"
    return 1
}

# dc_assert_contains <文本> <子串> <说明>
dc_assert_contains() {
    dc_assert_begin
    case "${1-}" in
        *"${2-}"*) return 0 ;;
    esac
    dc_fail "${3-}：没找到 [${2-}]"
    return 1
}

# dc_skip <说明>：容忍未实现的 target，跳过而不判失败
dc_skip() {
    DC_SKIP_COUNT=$((DC_SKIP_COUNT + 1))
    printf '      - 跳过：%s\n' "$*"
}

# ---------- 用例装载与执行 ----------
for _dc_case_file in "$DC_CASES_DIR"/*.sh; do
    [[ -r "$_dc_case_file" ]] || continue
    # shellcheck disable=SC1090
    . "$_dc_case_file"
done
unset _dc_case_file

if [[ ${#DC_CASES[@]} -eq 0 ]]; then
    printf '没有找到任何用例（%s/*.sh）\n' "$DC_CASES_DIR" >&2
    exit 1
fi

printf 'disk-cleanup v2 测试\n'
printf '  假 HOME=%s（真实 HOME=%s 未使用）\n' "$DC_TMPHOME" "${DC_ORIG_HOME:-<未设置>}"
printf '  用例目录=%s\n\n' "$DC_CASES_DIR"

for _dc_case in "${DC_CASES[@]}"; do
    DC_CURRENT_CASE="$_dc_case"
    DC_CASE_ASSERTS=0
    DC_CASE_FAILS=0
    printf '  ▸ %s\n' "$_dc_case"
    if ! declare -F "$_dc_case" >/dev/null 2>&1; then
        dc_fail "用例函数 ${_dc_case} 未定义"
        continue
    fi
    "$_dc_case"
    if [[ "$DC_CASE_FAILS" -eq 0 ]]; then
        printf '      ✓ %d 条断言\n' "$DC_CASE_ASSERTS"
    else
        printf '      ✗ %d/%d 条断言失败\n' "$DC_CASE_FAILS" "$DC_CASE_ASSERTS"
    fi
done
unset _dc_case

printf '\n断言 %d 条：失败 %d 条，跳过 %d 项\n' "$DC_ASSERT_COUNT" "$DC_FAIL_COUNT" "$DC_SKIP_COUNT"
if [[ "$DC_FAIL_COUNT" -ne 0 ]]; then
    printf 'FAIL（假 HOME=%s）\n' "$DC_TMPHOME"
    exit 1
fi
printf '全部通过\n'
exit 0
