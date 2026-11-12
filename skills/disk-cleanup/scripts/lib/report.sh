#!/usr/bin/env bash
# 报告与执行封装：run() 是每个编码的唯一执行入口，负责勾选/提权/预览/状态/审计。
[[ -n "${_DC_REPORT_LOADED:-}" ]] && return 0
_DC_REPORT_LOADED=1

# status_rank <status>：codes[] 聚合取最严重状态
status_rank() {
    case "${1:-}" in
        failed) echo 7 ;;
        partial) echo 6 ;;
        done) echo 5 ;;
        dry-run) echo 4 ;;
        reported) echo 3 ;;
        queried) echo 2 ;;
        skipped-sudo) echo 1 ;;
        *) echo 0 ;;
    esac
}

# dc_reason_from_counters：把 funnel 的计数折成一个 reason
dc_reason_from_counters() {
    if [[ "${DC_DEL_TIMEOUT:-0}" -gt 0 ]]; then printf 'timeout'; return; fi
    if [[ "${DC_DEL_FAILS:-0}" -gt 0 ]]; then printf '%s' "${DC_LAST_REASON:-io-error}"; return; fi
    if [[ "${DC_DEL_PROTECTED:-0}" -gt 0 && "${DC_DEL_OK:-0}" -eq 0 ]]; then printf 'protected'; return; fi
    if [[ "${DC_DEL_INUSE:-0}" -gt 0 && "${DC_DEL_OK:-0}" -eq 0 ]]; then printf 'in-use'; return; fi
    printf 'ok'
}

# json_add <id> <label> <status>
json_add() {
    local id="$1" desc="$2" status="$3" reason obj sample="" sep="" s
    reason="${STEP_REASON:-$(dc_reason_from_counters)}"
    obj=$(printf '{"id":"%s","label":"%s","status":"%s","reason":"%s","total_kb":%s,"deletable_kb":%s,"sudo":%s' \
        "$(json_esc "$id")" "$(json_esc "$desc")" "$status" "$(json_esc "$reason")" \
        "${STEP_TOTAL_KB:-0}" "${STEP_DEL_KB:-0}" "$(is_sudo_id "$id" && printf 'true' || printf 'false')")
    if [[ -n "${STEP_SAMPLE:-}" ]]; then
        while IFS= read -r s; do
            [[ -n "$s" ]] || continue
            sample="${sample}${sep}\"$(json_esc "$s")\""
            sep=","
        done <<EOF
$STEP_SAMPLE
EOF
    fi
    [[ -n "$sample" ]] && obj="${obj},\"sample_paths\":[${sample}]"
    if [[ -n "${STEP_PATH:-}" ]]; then
        obj="${obj},\"path\":\"$(json_esc "$STEP_PATH")\""
    fi
    if [[ -n "${STEP_NOTE:-}" ]]; then
        obj="${obj},\"note\":\"$(json_esc "$STEP_NOTE")\""
    fi
    # 少数编码需要的额外结构字段：由 target 设置，json_add 统一序列化（不许 target 手拼 JSON_ITEMS）
    if [[ -n "${DC_ITEM_CONFIDENCE:-}" ]]; then
        obj="${obj},\"confidence\":\"$(json_esc "$DC_ITEM_CONFIDENCE")\""
        DC_ITEM_CONFIDENCE=""
    fi
    if [[ -n "${DC_ITEM_CANDIDATES:-}" ]]; then
        obj="${obj},\"candidates\":[${DC_ITEM_CANDIDATES}]"
        DC_ITEM_CANDIDATES=""
    fi
    JSON_ITEMS+=("${obj}}")
    JSON_CODE_IDS+=("$id")
    JSON_CODE_STATUSES+=("$status")
    JSON_CODE_TOTALS+=("${STEP_TOTAL_KB:-0}")
    JSON_CODE_DELS+=("${STEP_DEL_KB:-0}")
    case "$status" in
        done) ESTIMATED_FREED_KB=$((ESTIMATED_FREED_KB + ${STEP_DEL_KB:-0})) ;;
    esac
}

build_codes_json() {
    local i j id total del count rank best best_rank out="" sep="" found
    for ((i = 0; i < ${#JSON_CODE_IDS[@]}; i++)); do
        id="${JSON_CODE_IDS[$i]}"
        found=0
        for ((j = 0; j < i; j++)); do
            [[ "${JSON_CODE_IDS[$j]}" == "$id" ]] && { found=1; break; }
        done
        [[ "$found" -eq 1 ]] && continue
        total=0; del=0; count=0; best=""; best_rank=0
        for ((j = i; j < ${#JSON_CODE_IDS[@]}; j++)); do
            [[ "${JSON_CODE_IDS[$j]}" == "$id" ]] || continue
            count=$((count + 1))
            total=$((total + ${JSON_CODE_TOTALS[$j]:-0}))
            del=$((del + ${JSON_CODE_DELS[$j]:-0}))
            rank=$(status_rank "${JSON_CODE_STATUSES[$j]}")
            if [[ -z "$best" || "$rank" -gt "$best_rank" ]]; then
                best_rank="$rank"
                best="${JSON_CODE_STATUSES[$j]}"
            fi
        done
        out="${out}${sep}{\"id\":\"$(json_esc "$id")\",\"label\":\"$(json_esc "$(item_label "$id")")\",\"status\":\"${best}\",\"total_kb\":${total},\"deletable_kb\":${del},\"items\":${count}}"
        sep=","
    done
    printf '%s' "$out"
}

report_add_json() {
    REPORT_JSON="${REPORT_JSON}${REPORT_SEP}${1}"
    REPORT_SEP=","
}

dc_protected_json() {
    local out="" sep="" hit p r
    for hit in "${DC_PROTECTED_HITS[@]:-}"; do
        [[ -n "$hit" ]] || continue
        p="${hit%%|*}"; r="${hit#*|}"
        out="${out}${sep}{\"path\":\"$(json_esc "$p")\",\"reason\":\"$(json_esc "$r")\"}"
        sep=","
    done
    printf '%s' "$out"
}

# report_line <id> <label> <kb> <note>：文本一行 + reports[] 一条（kb<0 表示读不到）
report_line() {
    local id="$1" label="$2" kb="$3" note="$4" json_note="$4"
    if [[ "$kb" -lt 0 ]]; then
        say "  ${label}: 读不到${note:+（${note}）}"
        case "$json_note" in
            *读不到*) ;;
            "") json_note="读不到" ;;
            *) json_note="读不到（${json_note}）" ;;
        esac
    else
        say "  ${label}: $(human "$kb")${note:+（${note}）}"
    fi
    report_add_json "{\"id\":\"$(json_esc "$id")\",\"label\":\"$(json_esc "$label")\",\"kb\":${kb},\"note\":\"$(json_esc "$json_note")\"}"
}

report_path() {
    local id="$1" label="$2" path="$3" oknote="$4" badnote="$5" kb
    if [[ ! -e "$path" ]]; then
        report_line "$id" "$label" 0 "未找到"
        return 0
    fi
    if dc_is_network_path "$path"; then
        report_line "$id" "$label" -1 "外接/网络卷，不统计"
        return 0
    fi
    kb=$(du_kb_strict "$path")
    if [[ -z "$kb" || "$kb" -lt 0 ]]; then
        report_line "$id" "$label" -1 "$badnote"
    else
        report_line "$id" "$label" "$kb" "$oknote"
    fi
}

# ---------- run()：编码的执行入口 ----------
# run <编码> <描述> <函数或命令...>
# 未勾选 → skipped-unselected；需 sudo 无权限 → skipped-sudo；
# 仅查询 → queried；预览 → dry-run（只打印 PLAN_CMD）；否则执行并记 done/partial/failed。
run() {
    local id="$1" desc="$2" rc=0 status reason
    shift 2
    # STEP_NOTE / STEP_REASON 由 target 在调用 run 之前设置（如「活跃跳过 N」「user-kept」），
    # 这里不清空，否则这些判据进不了回执与 JSON。
    STEP_REASON="${STEP_REASON:-}"
    if ! dc_code_index "$id" >/dev/null; then
        printf '内部错误：编码 %s 不在 codes.tsv 中\n' "$id" >&2
        exit 2
    fi
    if [[ "$CLEAN" == "1" ]] && ! want "$id"; then
        LAST_RUN_SELECTED=0
        mark_unselected "$id"
        say "   [跳过] ${desc}（未勾选：${id}）"
        STEP_REASON="unselected"
        json_add "$id" "$desc" "skipped-unselected"
        return 0
    fi
    LAST_RUN_SELECTED=1
    if is_sudo_id "$id" && [[ "$CLEAN" == "1" && "$DRY_RUN" != "1" && "$SUDO_OK" != "1" ]]; then
        say "   [跳过] ${desc}（当前环境无 sudo 权限）"
        say "      请在用户终端执行: ${PLAN_CMD:-$*}"
        SKIPPED_STEPS+=("${desc}（需 sudo，已交给用户终端）")
        STEP_REASON="sudo-required"
        dc_audit_action "$id" "skipped" "$STEP_DEL_KB" "sudo-required" ""
        json_add "$id" "$desc" "skipped-sudo"
        return 0
    fi
    if [[ "$CLEAN" != "1" ]]; then
        say "   [查询] ${desc}"
        STEP_REASON="${STEP_REASON:-ok}"
        json_add "$id" "$desc" "queried"
        return 0
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        say "   [预览] ${desc}"
        say "      ${PLAN_CMD:-（内部实现，无独立命令）}"
        # 预览阶段就把「会被保护清单拦下」的条目标出来：样本最多 5 条，代价可忽略
        if [[ -n "${STEP_SAMPLE:-}" && "${DC_PROTECT_COUNT:-0}" -gt 0 ]]; then
            _hit=0
            while IFS= read -r _p; do
                [[ -n "$_p" ]] || continue
                if dc_protected_reason "$_p" >/dev/null; then _hit=$((_hit + 1)); fi
            done <<EOF
$STEP_SAMPLE
EOF
            if [[ "$_hit" -gt 0 ]]; then
                say "      注意：样本中有 ${_hit} 条命中保护清单，执行时会被跳过"
                STEP_NOTE="${STEP_NOTE:+${STEP_NOTE}；}样本 ${_hit} 条受保护"
            fi
        fi
        STEP_REASON="${STEP_REASON:-ok}"
        dc_audit_action "$id" "plan" "$STEP_DEL_KB" "ok" "${PLAN_CMD:-}"
        json_add "$id" "$desc" "dry-run"
        return 0
    fi
    say "   [执行] ${desc}"
    dc_counters_reset
    if [[ "$JSON" == "1" ]]; then
        "$@" >&2 || rc=$?
    else
        "$@" || rc=$?
    fi
    reason="${STEP_REASON:-$(dc_reason_from_counters)}"
    STEP_REASON="$reason"
    if [[ "$rc" -eq 0 ]]; then
        REPORT_STEPS+=("${desc}${STEP_NOTE:+（${STEP_NOTE}）}")
        dc_audit_action "$id" "removed" "${STEP_DEL_KB:-unknown}" "$reason" "${STEP_NOTE:-}"
        json_add "$id" "$desc" "done"
    else
        HAD_FAILURE=1
        FAILED_COUNT=$((FAILED_COUNT + 1))
        status="partial"
        [[ "$rc" -eq 127 ]] && status="failed"
        SKIPPED_STEPS+=("${desc}（${STEP_NOTE:-命令返回 ${rc}，可能部分未删}）")
        dc_audit_action "$id" "failed" "${STEP_DEL_KB:-unknown}" "$reason" "${STEP_NOTE:-}"
        json_add "$id" "$desc" "$status"
    fi
}

# dc_json_emit：schema 2 输出（stdout 只有这一段）
dc_json_emit() {
    local mode="query" sep="" it codes scope_json
    [[ "$CLEAN" == "1" ]] && mode="clean"
    [[ "$CLEAN" == "1" && "$DRY_RUN" == "1" ]] && mode="dry-run"
    codes=$(build_codes_json)
    printf '{"schema":2,"mode":"%s","exit_code":%s,"failed_count":%s,' \
        "$mode" "$FINAL_EXIT" "$FAILED_COUNT"
    printf '"disk":{"free_before_kb":%s,"free_after_kb":%s,"freed_kb":%s,"estimated_freed_kb":%s,"df_delta_kb":%s},' \
        "$DISK_FREE_BEFORE_KB" "$DISK_FREE_AFTER_KB" "$FREED_KB" "$ESTIMATED_FREED_KB" "$DF_DELTA_KB"
    scope_json=$(printf '{"active":%s,"only":"%s","skip":"%s"}' \
        "$( [[ "${SCOPE_ACTIVE:-0}" == "1" ]] && printf true || printf false )" \
        "$(json_esc "${ONLY_NORM:-}")" "$(json_esc "${SKIP_NORM:-}")")
    printf '"scope":%s,"codes":[%s],"reports":[%s],"protected":[%s],"items":[' \
        "$scope_json" "$codes" "$REPORT_JSON" "$(dc_protected_json)"
    if [[ ${#JSON_ITEMS[@]} -gt 0 ]]; then
        for it in "${JSON_ITEMS[@]}"; do printf '%s%s' "$sep" "$it"; sep=","; done
    fi
    printf '],"audit":{"run_id":"%s","log":"%s"}}\n' "$(json_esc "$DC_RUN_ID")" "$(json_esc "$DC_AUDIT_LOG")"
}
