#!/usr/bin/env bash
# 候选清单（manifest）：预览阶段把「到底会删哪些路径」落成可逐条核对的 TSV。
#
# 设计要点：
#   - 只在 `--clean --dry-run` 产出。数据来自**同一个删除漏斗**：plan 模式下
#     dc_funnel_rm / dc_batch_add 只做断言与保护判定并记录，不落 rm。
#     因此清单与真实执行共用一套枚举逻辑，天然不会漂移。
#   - 记不进去（只读、盘满）不影响判定：计数器在内存里照样准，JSON 里 path 为空串。
#   - 表头以 `#` 开头，解析方跳过即可；路径里的制表符/换行会在落盘前压成空格。
#   - 空目录清理（删空的目录）由删除结果决定，预览阶段无法预知，不进清单。
[[ -n "${_DC_PLAN_LOADED:-}" ]] && return 0
_DC_PLAN_LOADED=1

DC_PLAN_TARGET=""
DC_PLAN_ENABLED=0
DC_PLAN_COUNT=0
DC_PLAN_DELETE=0
DC_PLAN_PROTECTED=0
DC_PLAN_UNVERIFIED=0
DC_PLAN_KIND_DIR=0
DC_PLAN_KIND_FILE=0
DC_PLAN_KIND_COMMAND=0
DC_PLAN_MAX=${DC_PLAN_MAX:-100000}
DC_PLAN_TRUNCATED=0
DC_PLAN_WRITE_FAILED=0
DC_PLAN_CODE=""

# dc_plan_reset：清空内存计数（不动已落盘内容）
dc_plan_reset() {
    DC_PLAN_TARGET=""
    DC_PLAN_COUNT=0
    DC_PLAN_DELETE=0
    DC_PLAN_PROTECTED=0
    DC_PLAN_UNVERIFIED=0
    DC_PLAN_KIND_DIR=0
    DC_PLAN_KIND_FILE=0
    DC_PLAN_KIND_COMMAND=0
    DC_PLAN_TRUNCATED=0
    DC_PLAN_WRITE_FAILED=0
    DC_PLAN_CODE=""
}

# dc_plan_default_dir：优先跟台账同目录（沙箱里台账会退到 TMPDIR，清单跟着走），
# 都不行就空串（只留内存计数）。
dc_plan_default_dir() {
    local d u
    if [[ -n "${DC_AUDIT_LOG:-}" ]]; then
        d="$(dirname -- "$DC_AUDIT_LOG")/manifests"
        if mkdir -p -- "$d" 2>/dev/null; then printf '%s' "$d"; return 0; fi
    fi
    u=$(id -u 2>/dev/null || printf 0)
    d="${TMPDIR:-/tmp}"; d="${d%/}"
    d="$d/disk-cleanup-$u/manifests"
    if mkdir -p -- "$d" 2>/dev/null; then printf '%s' "$d"; return 0; fi
    printf ''
}

# dc_plan_init：决定清单落点并写表头。DC_MANIFEST_PATH 存在时以它为准。
dc_plan_init() {
    local dir target=""
    dc_plan_reset
    DC_PLAN_ENABLED=1
    if [[ -n "${DC_MANIFEST_PATH:-}" ]]; then
        # 相对路径按调用时的 cwd 定性，别让 JSON 里出现一个换个目录就读不到的相对路径
        DC_MANIFEST_PATH="$(resolve_path "$DC_MANIFEST_PATH")"
        dir="$(dirname -- "$DC_MANIFEST_PATH")"
        if mkdir -p -- "$dir" 2>/dev/null; then
            target="$DC_MANIFEST_PATH"
        else
            printf '提示：清单目录不可写（%s），本次只统计不落盘。\n' "$dir" >&2
        fi
    else
        dir=$(dc_plan_default_dir)
        [[ -n "$dir" ]] && target="$dir/plan-${DC_RUN_ID:-manual}.tsv"
    fi
    if [[ -n "$target" ]]; then
        if { dc_plan_header > "$target"; } 2>/dev/null; then
            DC_PLAN_TARGET="$target"
        else
            printf '提示：清单不可写（%s），本次只统计不落盘。\n' "$target" >&2
            DC_PLAN_TARGET=""
        fi
    fi
    return 0
}

dc_plan_header() {
    printf '%s\n' '#code	decision	kind	path	reason	size_kb	sudo'
}

# dc_plan_record <code> <decision> <kind> <path> [reason] [size_kb] [sudo]
#   decision: delete | protected | unverified
#   kind    : dir | file | command
# 只有路径可能带制表符/换行/控制字符；没有就一个进程都不起——几千条时这决定秒级还是分钟级。
dc_plan_record() {
    local code="$1" decision="$2" kind="$3" path="$4"
    local reason="${5:-}" size_kb="${6:--1}" use_sudo="${7:-0}"
    [[ "$DC_PLAN_COUNT" -ge "$DC_PLAN_MAX" ]] && { DC_PLAN_TRUNCATED=1; return 0; }
    DC_PLAN_COUNT=$((DC_PLAN_COUNT + 1))
    case "$decision" in
        protected) DC_PLAN_PROTECTED=$((DC_PLAN_PROTECTED + 1)) ;;
        unverified) DC_PLAN_UNVERIFIED=$((DC_PLAN_UNVERIFIED + 1)) ;;
        *) DC_PLAN_DELETE=$((DC_PLAN_DELETE + 1)) ;;
    esac
    case "$kind" in
        dir) DC_PLAN_KIND_DIR=$((DC_PLAN_KIND_DIR + 1)) ;;
        command) DC_PLAN_KIND_COMMAND=$((DC_PLAN_KIND_COMMAND + 1)) ;;
        *) DC_PLAN_KIND_FILE=$((DC_PLAN_KIND_FILE + 1)) ;;
    esac
    [[ -n "$DC_PLAN_TARGET" ]] || return 0
    case "$path" in
        *[[:cntrl:]]*)
            path=$(printf '%s' "$path" | tr '\t\n\r' '   ' | tr -d '\000-\010\013\014\016-\037')
            ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$code" "$decision" "$kind" "$path" "$reason" "$size_kb" "$use_sudo" \
        >> "$DC_PLAN_TARGET" 2>/dev/null || DC_PLAN_WRITE_FAILED=1
    return 0
}

# dc_plan_command <command> [size_kb]：该编码由外部命令执行，无法逐条枚举路径
dc_plan_command() {
    dc_plan_record "${DC_PLAN_CODE:-unknown}" delete command "${1:-}" "" "${2:--1}" 0
}

# dc_plan_json：manifest 块（没有清单时为 null）
dc_plan_json() {
    # 没在预览模式 → null；在预览但清单落不了盘 → 仍给计数，只是 path 为空串
    if [[ "${DC_PLAN_ENABLED:-0}" != "1" ]]; then
        printf 'null'
        return 0
    fi
    printf '{"path":"%s","count":%s,"truncated":%s,"write_failed":%s,' \
        "$(json_esc "$DC_PLAN_TARGET")" "$DC_PLAN_COUNT" \
        "$( [[ "$DC_PLAN_TRUNCATED" == "1" ]] && printf true || printf false )" \
        "$( [[ "$DC_PLAN_WRITE_FAILED" == "1" ]] && printf true || printf false )"
    printf '"by_decision":{"delete":%s,"protected":%s,"unverified":%s},' \
        "$DC_PLAN_DELETE" "$DC_PLAN_PROTECTED" "$DC_PLAN_UNVERIFIED"
    printf '"by_kind":{"dir":%s,"file":%s,"command":%s}}' \
        "$DC_PLAN_KIND_DIR" "$DC_PLAN_KIND_FILE" "$DC_PLAN_KIND_COMMAND"
}
