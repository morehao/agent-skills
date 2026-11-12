#!/usr/bin/env bash
# 用例 06：I8 dry-run 等价性 —— 同一份假缓存目录，dry-run 与 clean 的 deletable_kb 必须一致。
# 只在 $HOME=$(mktemp -d) 的假目录里跑；clean 真删也只删假目录。目标未实现时跳过。

# 从 schema 2 的 JSON 里取 codes[] 中某编码的整数字段（不引 jq）
dc_json_code_kb() {
    printf '%s' "$1" | tr '{' '\n' \
        | grep -F "\"id\":\"$2\"" | head -1 \
        | grep -o "\"$3\":[0-9]*" | head -1 | cut -d: -f2
}

dc_case_dryrun_matches_clean() {
    if ! declare -F target_caches >/dev/null 2>&1; then
        dc_skip 'targets 里还没有 caches 的实现（队友并行开发中），跳过 dry-run/clean 一致性'
        return 0
    fi

    local cache="$HOME/Library/Caches"
    mkdir -p -- "$cache/fakeapp-old" "$cache/Google/Chrome/Cache" || {
        dc_fail '无法创建假缓存目录'
        return 1
    }
    printf 'blob' >"$cache/fakeapp-old/blob"
    printf 'blob' >"$cache/Google/Chrome/Cache/data"
    # 2020 年的 mtime：1 天阈值一定判为「过期可删」
    touch -t 202001010000 -- "$cache/fakeapp-old/blob" "$cache/Google/Chrome/Cache/data"

    local dry clean rc=0 kb_dry kb_clean
    dry=$(run_timeout 120 bash "$DC_SCRIPT" --clean --dry-run --only caches --json 2>/dev/null) || rc=$?
    dc_assert_eq 0 "$rc" '--clean --dry-run --only caches 应 exit 0'
    rc=0
    clean=$(run_timeout 120 bash "$DC_SCRIPT" --clean --only caches --json 2>/dev/null) || rc=$?
    dc_assert_eq 0 "$rc" '--clean --only caches 应 exit 0（只在假 HOME 下删）'

    dc_assert_contains "$dry" '"schema":2' 'dry-run 的 JSON 应带 schema 2'
    dc_assert_contains "$dry" '"mode":"dry-run"' 'dry-run 的 mode 应为 dry-run'
    dc_assert_contains "$clean" '"mode":"clean"' 'clean 的 mode 应为 clean'
    dc_assert_contains "$dry" '"freed_kb":0' 'dry-run 的 freed_kb 应为 0'

    kb_dry=$(dc_json_code_kb "$dry" caches deletable_kb)
    kb_clean=$(dc_json_code_kb "$clean" caches deletable_kb)
    dc_assert_gt 0 "${kb_dry:-0}" '假缓存目录应测出 >0 的可删量（否则这个用例没有意义）'
    dc_assert_eq "$kb_dry" "$kb_clean" 'dry-run 与 clean 的 caches.deletable_kb 应一致（I8：同一计数路径）'

    dc_assert_begin
    if [[ -e "$cache/Google/Chrome/Cache/data" ]]; then
        dc_fail 'clean 之后纯缓存目标应已被删除（证明删除确实发生在假 HOME 里）'
    fi
}

DC_CASES+=(
    dc_case_dryrun_matches_clean
)
