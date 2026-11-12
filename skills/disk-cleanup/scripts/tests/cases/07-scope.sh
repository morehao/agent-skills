#!/usr/bin/env bash
# 用例 07：场景聚焦（--only / --skip / --group 在查询与执行两侧都生效）。
# 用户的典型问法是「我只想看看/清理 docker」，范围必须同时约束测量、报告与执行。

# 取一段 JSON 里 items 的 id 列表（空格分隔）
dc_scope_item_ids() {
    local json="$1" body
    # 只取 items[] 段（codes[] 里也有 id，混在一起会重复计数）
    body=$(printf '%s' "$json" | sed -e 's/^.*"items":\[//' -e 's/\],"audit":.*$//')
    printf '%s' "$body" | awk 'BEGIN{RS="{"} {
        match($0, /"id":"[^"]*"/);
        if (RSTART > 0) printf "%s ", substr($0, RSTART+6, RLENGTH-7)
    }'
}

dc_scope_json() {
    bash "$DC_SCRIPT" "$@" --json 2>/dev/null
}

dc_case_scope_only_query() {
    local out items scope_ok
    out=$(dc_scope_json --only docker)
    items=$(dc_scope_item_ids "$out")
    dc_assert_eq "docker " "$items" "查询侧 --only docker 只应产出 docker 一项"
    case "$out" in
        *'"scope":{"active":true,"only":"docker","skip":""}'*) scope_ok=1 ;;
        *) scope_ok=0 ;;
    esac
    dc_assert_eq 1 "$scope_ok" "JSON 应声明本次范围（scope.active/only）"
}

dc_case_scope_group_query() {
    local out items n
    out=$(dc_scope_json --group containers)
    items=$(dc_scope_item_ids "$out")
    dc_assert_eq "docker " "$items" "--group containers 应展开为 docker"

    out=$(dc_scope_json --group ios)
    items=$(dc_scope_item_ids "$out")
    n=$(printf '%s' "$items" | tr ' ' '\n' | grep -c . || true)
    dc_assert_eq 3 "$n" "--group ios 应展开为 3 个编码（xcode/cocoapods/xcode-ios）"
    case "$items" in
        *"xcode "*"cocoapods "*"xcode-ios "*) ;;
        *) dc_fail "--group ios 展开结果不对：${items}" ;;
    esac
}

dc_case_scope_group_unknown() {
    dc_assert_exit 2 '未知场景组应 exit 2' bash "$DC_SCRIPT" --group no-such-group
    dc_assert_exit 2 '未知场景组（带 --clean）应 exit 2' \
        bash "$DC_SCRIPT" --clean --group no-such-group
    dc_assert_exit 0 '--groups 应正常退出' bash "$DC_SCRIPT" --groups
    dc_assert_exit 0 '--list 应带出场景组' bash "$DC_SCRIPT" --list
}

dc_case_scope_skip_query() {
    local out
    out=$(dc_scope_json --skip docker)
    case "$out" in
        *'"id":"docker"'*) dc_fail "查询侧 --skip docker 仍出现了 docker 项" ;;
        *) dc_assert_begin ;;
    esac
    case "$out" in
        *'"active":true,"only":"","skip":"docker"'*) dc_assert_begin ;;
        *) dc_fail "scope.skip 未声明为 docker" ;;
    esac
}

dc_case_scope_clean_unselected() {
    local out
    # --clean --dry-run 下范围外编码应记 skipped-unselected，而不是被当成「没找到目标」
    out=$(dc_scope_json --clean --dry-run --only docker)
    case "$out" in
        *'"id":"caches","label":"用户缓存 ~/Library/Caches","status":"skipped-unselected","reason":"unselected"'*)
            dc_assert_begin ;;
        *) dc_fail "范围外编码应记 skipped-unselected/reason=unselected" ;;
    esac
    case "$out" in
        *'"id":"docker","label"'*'"status":"dry-run"'*) dc_assert_begin ;;
        *) dc_fail "范围内编码应是 dry-run" ;;
    esac
}

# 场景聚焦的收益：查询时间不该再被无关大目录拉长（宽阈值，避免 CI 抖动）
dc_case_scope_is_cheap() {
    local t0 t1 dt
    t0=$(date +%s)
    bash "$DC_SCRIPT" --only docker --json >/dev/null 2>&1
    t1=$(date +%s)
    dt=$((t1 - t0))
    dc_assert_begin
    if [[ "$dt" -le 30 ]]; then return 0; fi
    dc_fail "只查 docker 用了 ${dt}s（>30s），说明仍在测量范围外的编码"
}

DC_CASES+=(
    dc_case_scope_only_query
    dc_case_scope_group_query
    dc_case_scope_group_unknown
    dc_case_scope_skip_query
    dc_case_scope_clean_unselected
    dc_case_scope_is_cheap
)
