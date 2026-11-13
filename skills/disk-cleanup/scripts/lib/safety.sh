#!/usr/bin/env bash
# 删除安全内核：环境断言、单一路径断言、保护清单、唯一删除漏斗。
# 铁律：整个磁盘清理脚本里，只有本文件的 dc_funnel_rm 允许出现 rm。
[[ -n "${_DC_SAFETY_LOADED:-}" ]] && return 0
_DC_SAFETY_LOADED=1

DC_DEL_OK=0
DC_DEL_FAILS=0
DC_DEL_EMPTY=0
DC_DEL_EMPTY_SKIP=0
DC_DEL_PROTECTED=0
DC_DEL_INUSE=0
DC_DEL_TIMEOUT=0
DC_LAST_REASON=""
DC_PROBE_UNKNOWN=0
DC_TIMEOUT_RM=600
# 批量删除：每批一次 rm，把「每个路径 3~4 个进程」压成「每批 3~4 个进程」
DC_RM_BATCH_MAX=${DC_RM_BATCH_MAX:-256}
DC_TIMEOUT_BATCH=${DC_TIMEOUT_BATCH:-$DC_TIMEOUT_RM}

dc_counters_reset() {
    DC_DEL_OK=0; DC_DEL_FAILS=0; DC_DEL_EMPTY=0; DC_DEL_EMPTY_SKIP=0; DC_DEL_PROTECTED=0
    DC_DEL_INUSE=0; DC_DEL_TIMEOUT=0; DC_LAST_REASON=""
}

# I3：HOME 断言。HOME 为空或相对路径时，所有 "$HOME/..." 会塌缩成系统路径。
dc_env_assert() {
    case "${HOME:-}" in
        /*) ;;
        *)
            printf 'HOME 未设置或不是绝对路径（%s）：拒绝运行，防止路径塌缩成系统目录。\n' "${HOME:-<空>}" >&2
            exit 2 ;;
    esac
    [[ -d "$HOME" ]] || { printf 'HOME 不存在（%s）：拒绝运行。\n' "$HOME" >&2; exit 2; }
    [[ "$HOME" != "/" ]] || { printf 'HOME 是 /：拒绝运行。\n' >&2; exit 2; }
}

# I2：路径断言。通过返回 0；失败时 DC_LAST_REASON 说明原因。
dc_path_assert() {
    local p="${1:-}"
    DC_LAST_REASON=""
    [[ -n "$p" ]] || { DC_LAST_REASON="io-error"; return 1; }
    case "$p" in
        /*) ;;
        *) DC_LAST_REASON="io-error"; return 1 ;;
    esac
    [[ "$p" == "/" ]] && { DC_LAST_REASON="protected"; return 1; }
    [[ "$p" == "$HOME" || "$p" == "$HOME/" ]] && { DC_LAST_REASON="protected"; return 1; }
    [[ ${#p} -gt 1 ]] || { DC_LAST_REASON="io-error"; return 1; }
    case "$p" in
        *[[:cntrl:]]*) DC_LAST_REASON="io-error"; return 1 ;;
    esac
    case "/$p/" in
        */../*|*/./*) DC_LAST_REASON="unverified-owner"; return 1 ;;
    esac
    # 系统关键根：不做保护清单之外的黑名单，靠 protect.tsv 表达
    return 0
}

# dc_under <path> <root>：path 是否等于 root 或在其下（按 / 边界，防 /Users/x 撞 /Users/xy）
dc_under() {
    local p="${1:-}" r="${2:-}"
    [[ -n "$p" && -n "$r" ]] || return 1
    [[ "$r" == "/" ]] && return 0
    case "$p" in
        "$r"|"$r"/*) return 0 ;;
    esac
    return 1
}

# ---------------- 保护清单 ----------------
dc_protect_load() {
    local f="$DC_SCRIPT_DIR/data/protect.tsv" tab pat scope reason n=0
    tab=$(printf '\t')
    DC_PROTECT_PATTERNS=(); DC_PROTECT_SCOPES=(); DC_PROTECT_REASONS=()
    if [[ ! -r "$f" ]]; then
        # fail-closed：保护清单读不到 ≠ 没有保护
        printf '保护清单不可读：%s（拒绝运行）\n' "$f" >&2
        exit 2
    fi
    if [[ -r "$f" ]]; then
        while IFS="$tab" read -r pat scope reason || [[ -n "${pat:-}" ]]; do
            case "${pat:-}" in ''|'#'*) continue ;; esac
            DC_PROTECT_PATTERNS[$n]="${pat#\$HOME}"
            DC_PROTECT_PATTERNS[$n]="$HOME${DC_PROTECT_PATTERNS[$n]}"
            DC_PROTECT_SCOPES[$n]="${scope:-soft}"
            DC_PROTECT_REASONS[$n]="${reason:-protected}"
            n=$((n + 1))
        done < "$f"
    fi
    DC_PROTECT_COUNT=$n
    dc_protect_load_user
}

# 用户文件只能「追加保护」或用 !pattern 解除 soft；hard 不受影响。
# 文件存在但不可读 → 拒绝运行（读不到不等于没有保护）。
# dc_expand_home <pattern>：把 $HOME 字面量、~/ 与相对写法统一成绝对路径
dc_expand_home() {
    local t="${1:-}"
    case "$t" in
        '$HOME') t="$HOME" ;;
        '$HOME/'*) t="$HOME${t#\$HOME}" ;;
        "~") t="$HOME" ;;
        "~/"*) t="$HOME/${t#\~/}" ;;
        /*) ;;
        *) t="$HOME/$t" ;;
    esac
    printf '%s' "$t"
}

dc_protect_load_user() {
    local uf="$HOME/.config/disk-cleanup/protect.txt"
    local n="${DC_PROTECT_COUNT:-0}" line i
    [[ -e "$uf" ]] || return 0
    if [[ ! -r "$uf" ]]; then
        printf '保护清单存在但不可读：%s（拒绝运行，避免把「读不到」当成「没有保护」）\n' "$uf" >&2
        exit 2
    fi
    while IFS= read -r line || [[ -n "${line:-}" ]]; do
        line=$(printf '%s' "$line" | sed -e 's/[[:space:]]*$//')
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in
            '!'*)
                local target
                target=$(dc_expand_home "${line#!}")
                for i in $(seq 0 $((n - 1))); do
                    [[ "${DC_PROTECT_SCOPES[$i]}" == "soft" ]] || continue
                    [[ "${DC_PROTECT_PATTERNS[$i]%\*}" == "${target%\*}" ]] && DC_PROTECT_SCOPES[$i]="off"
                done
                ;;
            *)
                DC_PROTECT_PATTERNS[$n]="$(dc_expand_home "$line")"
                DC_PROTECT_SCOPES[$n]="user"
                DC_PROTECT_REASONS[$n]="user-protect"
                n=$((n + 1))
                ;;
        esac
    done < "$uf"
    DC_PROTECT_COUNT=$n
}

# dc_protected_reason <path>：命中保护清单则输出 reason（0），否则 1
dc_protected_reason() {
    local p="${1:-}" i pat
    [[ ${DC_PROTECT_COUNT:-0} -gt 0 ]] || return 1
    for ((i = 0; i < DC_PROTECT_COUNT; i++)); do
        [[ "${DC_PROTECT_SCOPES[$i]}" == "off" ]] && continue
        pat="${DC_PROTECT_PATTERNS[$i]}"
        [[ -n "$pat" ]] || continue
        case "$p" in
            $pat|$pat/*)
                printf '%s' "${DC_PROTECT_REASONS[$i]}"
                return 0 ;;
        esac
    done
    return 1
}

# dc_protected_hit <path>：命中保护清单时返回 0，并把原因写进 DC_LAST_PROTECT_REASON。
# 与 dc_protected_reason 的区别：**不起子 shell**，用于上万条候选的热路径；
# 并且记住最近一次命中的父目录——路径按目录成批出现，命中一棵子树后子项直接继承。
DC_LAST_PROTECT_REASON=""
DC_PROTECT_LAST_PARENT=""
dc_protected_hit() {
    local p="${1:-}" i pat
    DC_LAST_PROTECT_REASON=""
    [[ ${DC_PROTECT_COUNT:-0} -gt 0 ]] || return 1
    # 父目录已命中 ⇒ 子项必然命中（保护是路径前缀语义）
    if [[ -n "$DC_PROTECT_LAST_PARENT" ]] && dc_under "$p" "$DC_PROTECT_LAST_PARENT"; then
        DC_LAST_PROTECT_REASON="${DC_PROTECT_LAST_REASON:-protected}"
        return 0
    fi
    for ((i = 0; i < DC_PROTECT_COUNT; i++)); do
        [[ "${DC_PROTECT_SCOPES[$i]}" == "off" ]] && continue
        pat="${DC_PROTECT_PATTERNS[$i]}"
        [[ -n "$pat" ]] || continue
        case "$p" in
            $pat|$pat/*)
                DC_LAST_PROTECT_REASON="${DC_PROTECT_REASONS[$i]}"
                DC_PROTECT_LAST_PARENT="$p"
                DC_PROTECT_LAST_REASON="$DC_LAST_PROTECT_REASON"
                return 0 ;;
        esac
    done
    return 1
}

# dc_classify_failure <父目录>：rm 失败后判定原因（区分只读/沙箱/TCC/其它）
dc_classify_failure() {
    local parent="${1:-}"
    local wp
    wp=$(write_probe "$parent" 2>/dev/null)
    case "$wp" in
        readonly) printf '%s' "denied-readonly" ;;
        denied) printf '%s' "denied-sandbox" ;;
        missing) printf '%s' "not-found" ;;
        *) printf '%s' "io-error" ;;
    esac
}

# dc_plan_probe <path> <0|1 sudo>：plan 模式下的「假删除」。
# 只做路径断言与保护清单判定，命中/拒绝都记进清单；不碰文件系统、不做 lsof
# （在用是执行期条件，预览时既不准确也不值得为几万个文件各起一次 lsof）。
# 返回 0 = 计划删除 / 2 = 被拦下（unverified|protected）
dc_plan_probe() {
    local p="${1:-}" use_sudo="${2:-0}" kind="file"
    [[ -d "$p" ]] && kind="dir"
    if ! dc_path_assert "$p"; then
        dc_plan_record "${DC_PLAN_CODE:-unknown}" "unverified" "$kind" "$p" "${DC_LAST_REASON:-io-error}" -1 "$use_sudo"
        return 2
    fi
    if dc_protected_hit "$p"; then
        [[ ${#DC_PROTECTED_HITS[@]} -lt 50 ]] && DC_PROTECTED_HITS+=("$p|$DC_LAST_PROTECT_REASON")
        dc_plan_record "${DC_PLAN_CODE:-unknown}" "protected" "$kind" "$p" "$DC_LAST_PROTECT_REASON" -1 "$use_sudo"
        return 2
    fi
    dc_plan_record "${DC_PLAN_CODE:-unknown}" "delete" "$kind" "$p" "" -1 "$use_sudo"
    return 0
}

# dc_funnel_rm <path> <0|1 sudo>：唯一的删除出口。
# 返回 0 已删 / 2 跳过（protected|in-use|denied）/ 3 失败
dc_funnel_rm() {
    local p="$1" use_sudo="${2:-0}" reason rc=0 parent
    if [[ "${DC_PLAN_MODE:-0}" == "1" ]]; then
        dc_plan_probe "$p" "$use_sudo"
        return $?
    fi
    DC_LAST_REASON=""
    if ! dc_path_assert "$p"; then
        DC_LAST_REASON="${DC_LAST_REASON:-io-error}"
        DC_DEL_FAILS=$((DC_DEL_FAILS + 1))
        return 3
    fi
    if dc_protected_hit "$p"; then
        reason="$DC_LAST_PROTECT_REASON"
        DC_LAST_REASON="protected"
        DC_DEL_PROTECTED=$((DC_DEL_PROTECTED + 1))
        [[ ${#DC_PROTECTED_HITS[@]} -lt 50 ]] && DC_PROTECTED_HITS+=("$p|$reason")
        dc_audit_path "$p" 0 "$reason"
        return 2
    fi
    if [[ -f "$p" ]] && is_path_in_use "$p"; then
        DC_LAST_REASON="in-use"
        DC_DEL_INUSE=$((DC_DEL_INUSE + 1))
        return 2
    fi
    parent=$(dirname -- "$p" 2>/dev/null)
    if [[ "$use_sudo" == "1" ]]; then
        run_timeout "$DC_TIMEOUT_RM" sudo -n rm -rf -- "$p" 2>/dev/null || rc=$?
    else
        run_timeout "$DC_TIMEOUT_RM" rm -rf -- "$p" 2>/dev/null || rc=$?
    fi
    if [[ "$rc" -eq 0 ]]; then
        DC_DEL_OK=$((DC_DEL_OK + 1))
        return 0
    fi
    if [[ "$rc" -eq 124 ]]; then
        DC_DEL_TIMEOUT=$((DC_DEL_TIMEOUT + 1))
        DC_LAST_REASON="timeout"
        dc_audit_failure "$p" 0 "timeout"
        return 3
    fi
    DC_DEL_FAILS=$((DC_DEL_FAILS + 1))
    DC_LAST_REASON=$(dc_classify_failure "$parent")
    dc_audit_failure "$p" 0 "$DC_LAST_REASON"
    return 3
}

# ---------------- 批量删除（同一漏斗，少起进程） ----------------
# 逐条 dc_funnel_rm 时，每个路径要付 rm + 看门狗子 shell + sleep 共 3~4 个进程；
# 清缓存这种几千个文件的场景会顶满 macOS 默认 4000 的进程上限，把脚本自己 fork 死。
# 这里先做与单条完全一致的三道检查（断言 / 保护清单 / 在用），通过后攒成一批整删；
# 整批失败才回退逐条定位原因——失败路径才会多付进程，成功路径不再付。
DC_BATCH_PATHS=()

dc_batch_reset() {
    DC_BATCH_PATHS=()
}

# dc_batch_flush <0|1 sudo>：执行当前批次（不再检查，未过三道的路径不该进批）
dc_batch_flush() {
    local use_sudo="${1:-0}" n=${#DC_BATCH_PATHS[@]} rc=0 p parent
    [[ "$n" -gt 0 ]] || return 0
    if [[ "$use_sudo" == "1" ]]; then
        run_timeout "$DC_TIMEOUT_BATCH" sudo -n rm -rf -- "${DC_BATCH_PATHS[@]}" 2>/dev/null || rc=$?
    else
        run_timeout "$DC_TIMEOUT_BATCH" rm -rf -- "${DC_BATCH_PATHS[@]}" 2>/dev/null || rc=$?
    fi
    if [[ "$rc" -eq 0 ]]; then
        DC_DEL_OK=$((DC_DEL_OK + n))
    else
        # 回退逐条：只对「还活着」的路径判原因，已删掉的照常计成功
        for p in "${DC_BATCH_PATHS[@]}"; do
            if [[ ! -e "$p" && ! -L "$p" ]]; then
                DC_DEL_OK=$((DC_DEL_OK + 1))
                continue
            fi
            if [[ "$rc" -eq 124 ]]; then
                DC_DEL_TIMEOUT=$((DC_DEL_TIMEOUT + 1))
                DC_LAST_REASON="timeout"
            else
                parent=$(dirname -- "$p" 2>/dev/null)
                DC_DEL_FAILS=$((DC_DEL_FAILS + 1))
                DC_LAST_REASON=$(dc_classify_failure "$parent")
            fi
            dc_audit_failure "$p" 0 "${DC_LAST_REASON:-io-error}"
            dc_audit_path "$p" 0 "${DC_LAST_REASON:-io-error}"
        done
    fi
    DC_BATCH_PATHS=()
    return 0
}

# dc_batch_add <path> <0|1 sudo>：0 已入批 / 1 被拦下（已计入对应计数器）
dc_batch_add() {
    local p="${1:-}" use_sudo="${2:-0}" reason
    [[ -n "$p" ]] || return 1
    if [[ "${DC_PLAN_MODE:-0}" == "1" ]]; then
        dc_plan_probe "$p" "$use_sudo" || return 1
        return 0
    fi
    if ! dc_path_assert "$p"; then
        DC_LAST_REASON="${DC_LAST_REASON:-io-error}"
        DC_DEL_FAILS=$((DC_DEL_FAILS + 1))
        return 1
    fi
    if dc_protected_hit "$p"; then
        reason="$DC_LAST_PROTECT_REASON"
        DC_LAST_REASON="protected"
        DC_DEL_PROTECTED=$((DC_DEL_PROTECTED + 1))
        [[ ${#DC_PROTECTED_HITS[@]} -lt 50 ]] && DC_PROTECTED_HITS+=("$p|$reason")
        dc_audit_path "$p" 0 "$reason"
        return 1
    fi
    if [[ -f "$p" ]] && is_path_in_use "$p"; then
        DC_LAST_REASON="in-use"
        DC_DEL_INUSE=$((DC_DEL_INUSE + 1))
        return 1
    fi
    DC_BATCH_PATHS+=("$p")
    [[ ${#DC_BATCH_PATHS[@]} -ge "$DC_RM_BATCH_MAX" ]] && dc_batch_flush "$use_sudo"
    return 0
}

# dc_delete_one <path> [sudo]：删单条；返回 0 成功 / 1 跳过（不算失败）/ 2 失败
dc_delete_one() {
    local p="$1" use_sudo="${2:-0}" rc=0
    dc_funnel_rm "$p" "$use_sudo" || rc=$?
    case "$rc" in
        0) return 0 ;;
        2) return 1 ;;
        *) return 2 ;;
    esac
}

# dc_delete_aged <dir> <days> [sudo]：只删「过期的文件/链接」，再清掉因此变空的目录。
# 不用 find -delete：整个脚本的删除必须经过漏斗。
dc_delete_aged() {
    local dir="$1" days="$2" use_sudo="${3:-0}" p existed=0
    [[ -e "$dir" ]] || { STEP_NOTE="路径不存在"; return 0; }
    existed=1
    dc_batch_reset
    # AppTranslocation 是 macOS 给「从下载目录直接运行」的 App 做的隔离副本，
    # 里面是**正在运行的 app 本体**（du 甚至会报 Result too large）。它不是临时垃圾，
    # 删了会让运行中的 app 当场崩；系统在 app 退出后会自己回收。
    while IFS= read -r -d '' p; do
        dc_batch_add "$p" "$use_sudo" >/dev/null 2>&1 || true
    done < <(find "$dir" -mindepth 1 \( -path '*/AppTranslocation' -prune \) -o \
        \( -type f -o -type l \) -mtime +"$days" -print0 2>/dev/null)
    dc_batch_flush "$use_sudo"
    # plan 模式到此为止：删空的目录由删除结果决定，预览阶段无法预知，不进清单
    [[ "${DC_PLAN_MODE:-0}" == "1" ]] && return 0
    # 空目录：不含新数据，删掉安全（不递归进非空目录）。
    # 只清**当前用户**的空目录：/var/folders 里混着 WebKit、Safari 等系统进程的沙箱目录，
    # 删别人的目录必然 EACCES，会把每一次清理都刷成 exit 1（本机实测一次 197 条）。
    # 单独计数：它们是删除的**结果**而不是候选，混进「已删 N」会让回执和清单对不上。
    local ok_before="$DC_DEL_OK" fail_before="$DC_DEL_FAILS" to_before="$DC_DEL_TIMEOUT" self_user action_before="${DC_FAIL_ACTION:-failed}"
    DC_FAIL_ACTION="skipped-empty"
    self_user=$(id -un 2>/dev/null || printf '')
    while IFS= read -r -d '' p; do
        [[ -d "$p" ]] || continue
        dc_batch_add "$p" "$use_sudo" >/dev/null 2>&1 || true
    done < <(find "$dir" -mindepth 1 -type d -empty ${self_user:+-user "$self_user"} -print0 2>/dev/null)
    dc_batch_flush "$use_sudo"
    # 删不掉的多是系统进程的沙箱目录（TCC 护着，owner 却是当前用户），本来就删不动：
    # 记成「跳过」而不是失败——否则每次清理都 exit 1，人就会开始无视失败。
    DC_DEL_EMPTY=$((DC_DEL_EMPTY + DC_DEL_OK - ok_before))
    DC_DEL_EMPTY_SKIP=$((DC_DEL_EMPTY_SKIP + DC_DEL_FAILS - fail_before + DC_DEL_TIMEOUT - to_before))
    DC_DEL_OK="$ok_before"
    DC_DEL_FAILS="$fail_before"
    DC_DEL_TIMEOUT="$to_before"
    DC_FAIL_ACTION="$action_before"
    [[ "$existed" -eq 1 ]] || { STEP_NOTE="路径不存在"; return 0; }
    STEP_NOTE="已删 ${DC_DEL_OK} / 保护 ${DC_DEL_PROTECTED} / 在用 ${DC_DEL_INUSE} / 失败 ${DC_DEL_FAILS}${DC_DEL_TIMEOUT:+/超时 ${DC_DEL_TIMEOUT}}"
    [[ "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

# dc_delete_whole <path> [sudo]：整目录删除（走漏斗，记录审计）
dc_delete_whole() {
    local p="$1" use_sudo="${2:-0}" size_kb=0 rc=0
    [[ -e "$p" ]] || { STEP_NOTE="路径不存在"; return 0; }
    if [[ "${DC_PLAN_MODE:-0}" == "1" ]]; then
        dc_funnel_rm "$p" "$use_sudo"
        return 0
    fi
    size_kb=$(du_kb "$p")
    DC_AUDIT_PATHS=1
    dc_funnel_rm "$p" "$use_sudo" || rc=$?
    DC_AUDIT_PATHS=0
    if [[ "$rc" -eq 0 ]]; then
        STEP_NOTE="已删除 $(human "$size_kb")"
        return 0
    fi
    if [[ "$rc" -eq 2 ]]; then
        STEP_NOTE="跳过（${DC_LAST_REASON}）"
        return 1
    fi
    STEP_NOTE="删除失败（${DC_LAST_REASON}）"
    return 1
}

# dc_delete_paths_stdin [sudo]：从 stdin 读 NUL 分隔路径，过三道检查后分批走漏斗
dc_delete_paths_stdin() {
    local use_sudo="${1:-0}" p
    dc_batch_reset
    while IFS= read -r -d '' p; do
        dc_batch_add "$p" "$use_sudo" >/dev/null 2>&1 || true
    done
    dc_batch_flush "$use_sudo"
    STEP_NOTE="已删 ${DC_DEL_OK} / 保护 ${DC_DEL_PROTECTED} / 在用 ${DC_DEL_INUSE} / 失败 ${DC_DEL_FAILS}"
    [[ "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

# dc_deleted_summary：给文本回执的一行
dc_deleted_summary() {
    printf '已删 %s' "$DC_DEL_OK"
    [[ "${DC_DEL_EMPTY:-0}" -gt 0 ]] && printf ' + 清空目录 %s' "$DC_DEL_EMPTY"
    [[ "${DC_DEL_EMPTY_SKIP:-0}" -gt 0 ]] && printf '（另有 %s 个系统目录删不动，已跳过）' "$DC_DEL_EMPTY_SKIP"
    [[ "$DC_DEL_PROTECTED" -gt 0 ]] && printf ' / 保护 %s' "$DC_DEL_PROTECTED"
    [[ "$DC_DEL_INUSE" -gt 0 ]] && printf ' / 在用 %s' "$DC_DEL_INUSE"
    [[ "$DC_DEL_FAILS" -gt 0 ]] && printf ' / 失败 %s' "$DC_DEL_FAILS"
    [[ "$DC_DEL_TIMEOUT" -gt 0 ]] && printf ' / 超时 %s' "$DC_DEL_TIMEOUT"
    printf ''
}
