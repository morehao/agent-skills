#!/usr/bin/env bash
# 审计台账：append-only 的「删了什么」记录 + --history 读取。
# 设计：每个动作一行 TSV，写失败只警告一次；size 取不到写 unknown，绝不写 0。
[[ -n "${_DC_AUDIT_LOADED:-}" ]] && return 0
_DC_AUDIT_LOADED=1

DC_AUDIT_LOG="${DC_AUDIT_LOG:-${HOME}/Library/Logs/disk-cleanup/operations.log}"
DC_AUDIT_MAX_BYTES=5242880
DC_AUDIT_WARNED=0
DC_RUN_ID=""
DC_AUDIT_PATHS=0
DC_PROTECTED_HITS=()

dc_audit_init() {
    DC_RUN_ID=$(date +%Y%m%dT%H%M%S)-$$
    local dir
    dir=$(dirname -- "$DC_AUDIT_LOG")
    if ! mkdir -p -- "$dir" 2>/dev/null; then
        # 常见于 workspace-write 沙箱：$HOME 下不可写。退到临时目录，保证台账仍可回放。
        local _tmp="${TMPDIR:-/tmp}"; _tmp="${_tmp%/}"
        local alt="${_tmp}/disk-cleanup-$(id -u 2>/dev/null || printf 0)"
        if mkdir -p -- "$alt" 2>/dev/null; then
            DC_AUDIT_LOG="$alt/operations.log"
            printf '提示：$HOME 下日志目录不可写，本次台账写到 %s。\n' "$alt" >&2
        else
            dc_audit_warn "日志目录 ${dir} 与临时目录都不可写，本次不记录台账"
            DC_AUDIT_LOG=""
            return 0
        fi
    fi
    dc_audit_rotate
    local ts
    ts=$(date +%Y-%m-%dT%H:%M:%S%z)
    dc_audit_raw "$ts" "$DC_RUN_ID" "_run" "start" "-" "unknown" "ok" "$*"
}

dc_audit_warn() {
    [[ "$DC_AUDIT_WARNED" == "1" ]] && return 0
    DC_AUDIT_WARNED=1
    printf '提示：审计日志不可写（%s），本次清理仍会执行，但事后无法复盘。\n' "$1" >&2
}

dc_audit_rotate() {
    [[ -n "$DC_AUDIT_LOG" && -f "$DC_AUDIT_LOG" ]] || return 0
    local size
    size=$(wc -c < "$DC_AUDIT_LOG" 2>/dev/null | tr -d ' ')
    [[ -n "$size" ]] || return 0
    [[ "$size" -gt "$DC_AUDIT_MAX_BYTES" ]] || return 0
    mv -f -- "$DC_AUDIT_LOG" "${DC_AUDIT_LOG}.1" 2>/dev/null || true
}

# 控制字符与制表符会把一行记录拆坏，落盘前压成空格
dc_audit_sanitize() {
    printf '%s' "${1:-}" | tr '\t\n\r' '   ' | tr -d '\000-\010\013\014\016-\037'
}

dc_audit_raw() {
    [[ -n "$DC_AUDIT_LOG" ]] || return 0
    {
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(dc_audit_sanitize "$1")" "$(dc_audit_sanitize "$2")" "$(dc_audit_sanitize "$3")" \
            "$(dc_audit_sanitize "$4")" "$(dc_audit_sanitize "$5")" "$(dc_audit_sanitize "$6")" \
            "$(dc_audit_sanitize "$7")" "$(dc_audit_sanitize "${8:-}")"
    } >> "$DC_AUDIT_LOG" 2>/dev/null || dc_audit_warn "$DC_AUDIT_LOG"
}

# dc_audit_action <id> <action> <size_kb> <reason> <extra>
dc_audit_action() {
    local ts
    ts=$(date +%Y-%m-%dT%H:%M:%S%z)
    dc_audit_raw "$ts" "$DC_RUN_ID" "$1" "$2" "-" "${3:-unknown}" "${4:-ok}" "${5:-}"
}

# dc_audit_path <path> <size_kb> <reason>：只在整目录删除或大件时记录
dc_audit_path() {
    local p="$1" kb="${2:-0}" reason="${3:-ok}" size_field
    [[ "$DC_AUDIT_PATHS" == "1" ]] || return 0
    if [[ "$kb" == "0" ]]; then size_field="unknown"; else size_field="$kb"; fi
    local ts
    ts=$(date +%Y-%m-%dT%H:%M:%S%z)
    dc_audit_raw "$ts" "$DC_RUN_ID" "_path" "removed" "$p" "$size_field" "$reason" ""
}

# dc_audit_failure <path> <size_kb> <reason>：**失败的路径**单独落一行。
# 批量删除整批失败时会回退逐条，以前只汇总一个 failed 计数，事后根本查不到是哪几条；
# 这条记录是「失败可复盘」的唯一来源，不受 DC_AUDIT_PATHS 闸门限制（失败必然要留痕）。
dc_audit_failure() {
    [[ -n "${DC_AUDIT_LOG:-}" ]] || return 0
    local p="${1:-}" kb="${2:-0}" reason="${3:-failed}" size_field ts
    [[ -n "$p" ]] || return 0
    if [[ "$kb" == "0" || ! "$kb" =~ ^[0-9]+$ ]]; then size_field="unknown"; else size_field="$kb"; fi
    ts=$(date +%Y-%m-%dT%H:%M:%S%z)
    dc_audit_raw "$ts" "$DC_RUN_ID" "_path" "${DC_FAIL_ACTION:-failed}" "$p" "$size_field" "$reason" ""
}

# dc_history_tail <N>：流式读最后 N 条（不整读入内存）
dc_history_tail() {
    local n="${1:-50}"
    [[ -f "$DC_AUDIT_LOG" ]] || [[ -f "${DC_AUDIT_LOG}.1" ]] || return 0
    if [[ -f "$DC_AUDIT_LOG" ]]; then
        tail -n "$n" -- "$DC_AUDIT_LOG" 2>/dev/null
    elif [[ -f "${DC_AUDIT_LOG}.1" ]]; then
        tail -n "$n" -- "${DC_AUDIT_LOG}.1" 2>/dev/null
    fi
}

dc_history_text() {
    local n="${1:-50}" ts run id action path kb reason extra line
    say "最近 ${n} 条清理动作（${DC_AUDIT_LOG}）"
    dc_history_tail "$n" | while IFS="$(printf '\t')" read -r ts run id action path kb reason extra; do
        [[ -n "${ts:-}" ]] || continue
        [[ "$path" == "-" ]] && path=""
        printf '  %s  %-12s %-8s %-8s %s%s\n' "$ts" "$id" "$action" "${kb}KB" "$reason" "${path:+  $path}"
    done
}

dc_history_json() {
    local n="${1:-50}" ts run id action path kb reason extra sep="" kb_num
    printf '{"schema":%s,"mode":"history","entries":[' "${DC_SCHEMA_VERSION:-3}"
    while IFS="$(printf '\t')" read -r ts run id action path kb reason extra; do
        [[ -n "${ts:-}" ]] || continue
        [[ "$path" == "-" ]] && path=""
        case "${kb:-}" in
            ''|*[!0-9-]*) kb_num=-1 ;;
            *) kb_num="$kb" ;;
        esac
        printf '%s{"ts":"%s","run_id":"%s","id":"%s","action":"%s","path":"%s","size_kb":%s,"reason":"%s"}' \
            "$sep" "$(json_esc "$ts")" "$(json_esc "$run")" "$(json_esc "$id")" "$(json_esc "$action")" \
            "$(json_esc "$path")" "$kb_num" "$(json_esc "$reason")"
        sep=","
    done < <(dc_history_tail "$n")
    printf ']}\n'
}
