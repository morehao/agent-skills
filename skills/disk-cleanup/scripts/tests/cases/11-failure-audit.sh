#!/usr/bin/env bash
# 用例 11：失败路径必须可复盘。
#
# 批量删除整批失败会回退逐条；以前只汇总一个 failed 计数，事后查不到是哪几条。
# 现在失败的路径单独落一行台账（action=failed），不受 DC_AUDIT_PATHS 闸门限制。
# 另外：删空的目录由删除结果产生、不是候选，必须单独计数，否则回执和清单永远对不上。

dc_case_failed_path_logged() {
    local d
    d="$DC_TMPHOME/ro-dir"
    mkdir -p "$d"
    : > "$d/x"
    chmod 500 "$d"          # 目录不可写 → 删子项会 EACCES

    dc_counters_reset
    dc_delete_one "$d/x" >/dev/null 2>&1
    chmod 700 "$d"

    dc_assert_gt 0 "$DC_DEL_FAILS" '不可写目录里的删除应记为失败'
    dc_assert_begin
    if grep -q "failed" "$DC_AUDIT_LOG" 2>/dev/null && grep -q "$d/x" "$DC_AUDIT_LOG" 2>/dev/null; then
        :
    else
        dc_fail '失败路径没有落台账（事后无法复盘）'
    fi
}

dc_case_empty_dirs_counted_separately() {
    local root
    root="$DC_TMPHOME/vf-empty/T"
    mkdir -p "$root/sub"
    : > "$root/old.tmp"
    touch -t 202001010000 "$root/old.tmp" "$root/sub" 2>/dev/null || true

    dc_counters_reset
    dc_delete_aged "$root" 0 >/dev/null 2>&1

    dc_assert_eq 1 "$DC_DEL_OK" '已删只应统计候选文件（1 个）'
    dc_assert_gt 0 "$DC_DEL_EMPTY" '删空的目录应单独计数，不混进已删'
}

dc_case_undeletable_empty_dir_is_skip() {
    local root
    root="$DC_TMPHOME/vf-ro"
    mkdir -p "$root/empty-sub"
    chmod 500 "$root"          # 目录只读 → 删子项 EACCES

    dc_counters_reset
    dc_delete_aged "$root" 0 >/dev/null 2>&1
    chmod 700 "$root"

    dc_assert_eq 0 "$DC_DEL_FAILS" '删不动的空目录不应记成失败（否则每次清理都 exit 1）'
    dc_assert_gt 0 "$DC_DEL_EMPTY_SKIP" '删不动的空目录应单独记「跳过」'
}

DC_CASES+=(
    dc_case_failed_path_logged
    dc_case_empty_dirs_counted_separately
    dc_case_undeletable_empty_dir_is_skip
)
