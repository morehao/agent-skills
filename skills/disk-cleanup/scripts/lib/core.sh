#!/usr/bin/env bash
# 通用工具与编码表：文本/JSON、大小换算、路径、编码加载与勾选判定。
# 编码唯一事实源是 data/codes.tsv，本文件只负责读它，不得硬编码编码名。
[[ -n "${_DC_CORE_LOADED:-}" ]] && return 0
_DC_CORE_LOADED=1

# JSON 契约版本：一处定义，三处输出（主 JSON / --list / --history）共用
DC_SCHEMA_VERSION=3

# say：--json 时进度信息走 stderr，保证 stdout 只有 JSON
say() {
    if [[ "${JSON:-0}" == "1" ]]; then
        printf '%s\n' "$*" >&2
    else
        printf '%s\n' "$*"
    fi
}

json_esc() {
    printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'
}

# human <KB>：KB → 可读大小
human() {
    awk -v kb="${1:-0}" '
    BEGIN {
      if (kb >= 1048576) { printf "%.2f GB", kb/1048576 }
      else if (kb >= 1024) { printf "%.0f MB", kb/1024 }
      else if (kb > 0) { printf "%d KB", kb }
      else { printf "0" }
    }'
}

# du_kb <path>：目录占用 KB；取不到按 0（兼容旧调用方的算术）
du_kb() {
    local p="${1:-}" kb
    [[ -z "$p" || ! -e "$p" ]] && { printf '0'; return; }
    kb=$(run_timeout "$DC_TIMEOUT_DU" du -sk "$p" 2>/dev/null | awk '{print $1}')
    printf '%s' "${kb:-0}"
}

# du_kb_strict <path>：读不到返回 -1（只报告段用，-1 表示未知而不是 0）
du_kb_strict() {
    local p="${1:-}" kb
    [[ -z "$p" || ! -e "$p" ]] && { printf '0'; return; }
    kb=$(run_timeout "$DC_TIMEOUT_DU" du -sk "$p" 2>/dev/null | awk '{print $1}')
    [[ -n "$kb" ]] && printf '%s' "$kb" || printf '%s' -1
}

# subset_kb <path> <days>：path 下 mtime 超过 days 天的普通文件总大小（KB）
# 只统计文件，不对目录求和（目录会把子树重复计入）
subset_kb() {
    local p="$1" d="$2" kb
    [[ -e "$p" ]] || { printf '0'; return; }
    kb=$(run_timeout "$DC_TIMEOUT_FIND" find "$p" \( -type f -o -type l \) -mtime +"$d" -exec du -k {} + 2>/dev/null \
        | awk '{s+=$1} END{printf "%d", s+0}')
    printf '%s' "${kb:-0}"
}

# denied_count <path>：浅层遍历被 TCC/权限拒绝的条目数（不当作 0）
denied_count() {
    local p="$1" n
    [[ -e "$p" ]] || { printf '0'; return; }
    n=$(find "$p" -maxdepth 2 -print 2>&1 >/dev/null | grep -c "Operation not permitted" || true)
    printf '%s' "${n:-0}"
}

# count_real_fails <stderr 文本>：把 find/rm 的报错里「真实失败」数出来；
# Operation not permitted 单独归类（TCC/沙箱），不算删除失败但也不当成功
count_real_fails() {
    printf '%s' "${1:-}" | grep -cE "Permission denied|Read-only file system|No such file|Directory not empty" || true
}

sum_top_kb() {
    local total=0 kb
    for kb in "$@"; do total=$((total + ${kb:-0})); done
    printf '%s' "$total"
}

lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

# resolve_path <path>：转绝对路径并规范化（父目录 cd -P）
resolve_path() {
    local p="${1:-}"
    [[ -z "$p" ]] && { printf '%s' ""; return; }
    case "$p" in
        "~") p="$HOME" ;;
        "~/"*) p="$HOME/${p#\~/}" ;;
    esac
    case "$p" in
        /*) ;;
        *) p="$PWD/$p" ;;
    esac
    if [[ -d "$p" ]]; then
        ( cd -P -- "$p" 2>/dev/null && pwd -P ) || printf '%s' "$p"
    elif [[ -e "$p" ]]; then
        local d b
        d=$(dirname -- "$p"); b=$(basename -- "$p")
        ( cd -P -- "$d" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$b" ) || printf '%s' "$p"
    else
        printf '%s' "$p"
    fi
}

# keep_matches <path>：是否命中 --projects-keep
keep_matches() {
    local p="${1:-}" k
    [[ ${#PROJECTS_KEEP_LIST[@]} -eq 0 ]] && return 1
    for k in "${PROJECTS_KEEP_LIST[@]}"; do
        [[ -n "$k" ]] || continue
        case "$p" in
            "$k"|"$k"/*) return 0 ;;
        esac
    done
    return 1
}

# project_roots_list：--projects-roots 归一化为数组内容（换行/逗号/冒号分隔都接受）
project_roots_list() {
    local raw="${PROJECT_ROOTS:-$HOME/Documents}" out="" r
    local OLD_IFS="$IFS"
    IFS=',: '
    for r in $raw; do
        r=$(resolve_path "$r")
        [[ -d "$r" ]] || continue
        out="${out}${out:+
}${r}"
    done
    IFS="$OLD_IFS"
    [[ -n "$out" ]] && printf '%s\n' "$out"
    return 0
}

alnum_only_var() {
    local v="${1:-}"
    case "$v" in [A-Za-z_]*) ;; *) return 1 ;; esac
    case "$v" in *[!A-Za-z0-9_]*) return 1 ;; esac
    return 0
}

is_pos_int() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

# ---------------- 编码表（data/codes.tsv） ----------------
dc_codes_load() {
    local f="$DC_SCRIPT_DIR/data/codes.tsv" n=0 id label desc sd tab
    tab=$(printf '\t')
    if [[ ! -r "$f" ]]; then
        printf '编码表不可读: %s\n' "$f" >&2
        return 1
    fi
    DC_CODE_IDS=(); DC_CODE_LABELS=(); DC_CODE_DESCS=(); DC_CODE_SUDOS=()
    while IFS="$tab" read -r id label desc sd || [[ -n "${id:-}" ]]; do
        case "${id:-}" in ''|'#'*) continue ;; esac
        DC_CODE_IDS[$n]="$id"
        DC_CODE_LABELS[$n]="$label"
        DC_CODE_DESCS[$n]="$desc"
        DC_CODE_SUDOS[$n]="${sd:-0}"
        n=$((n + 1))
    done < "$f"
    DC_CODE_COUNT=$n
    KNOWN_IDS=""
    local i
    for ((i = 0; i < DC_CODE_COUNT; i++)); do
        KNOWN_IDS="${KNOWN_IDS}${KNOWN_IDS:+ }${DC_CODE_IDS[$i]}"
    done
    [[ "$DC_CODE_COUNT" -gt 0 ]]
}

# ---------------- 场景组（data/groups.tsv） ----------------
# 组名是「用户语言」到「编码」的映射；不得与编码同名（编码优先）。
dc_groups_load() {
    local f="$DC_SCRIPT_DIR/data/groups.tsv" tab name codes desc n=0
    tab=$(printf '\t')
    DC_GROUP_NAMES=(); DC_GROUP_CODES=(); DC_GROUP_DESCS=()
    [[ -r "$f" ]] || { DC_GROUP_COUNT=0; return 0; }
    while IFS="$tab" read -r name codes desc || [[ -n "${name:-}" ]]; do
        case "${name:-}" in ''|'#'*) continue ;; esac
        if dc_code_index "$name" >/dev/null 2>&1; then
            printf '场景组名与编码重名：%s（codes.tsv 优先，组名必须换一个）\n' "$name" >&2
            exit 2
        fi
        DC_GROUP_NAMES[$n]="$name"
        DC_GROUP_CODES[$n]="$codes"
        DC_GROUP_DESCS[$n]="${desc:-}"
        n=$((n + 1))
    done < "$f"
    DC_GROUP_COUNT=$n
}

# dc_group_codes <name>：命中输出逗号列表（0），否则 1
dc_group_codes() {
    local want="$1" i
    for ((i = 0; i < ${DC_GROUP_COUNT:-0}; i++)); do
        [[ "${DC_GROUP_NAMES[$i]}" == "$want" ]] || continue
        printf '%s' "${DC_GROUP_CODES[$i]}"
        return 0
    done
    return 1
}

dc_group_list() {
    local i
    for ((i = 0; i < ${DC_GROUP_COUNT:-0}; i++)); do
        printf '  %-18s %s\n' "${DC_GROUP_NAMES[$i]}" "${DC_GROUP_DESCS[$i]}"
        printf '  %-18s   → %s\n' "" "${DC_GROUP_CODES[$i]}"
    done
}

# dc_code_index <id>：输出下标，未找到输出空
dc_code_index() {
    local want_id="$1" i
    for ((i = 0; i < DC_CODE_COUNT; i++)); do
        [[ "${DC_CODE_IDS[$i]}" == "$want_id" ]] && { printf '%s' "$i"; return 0; }
    done
    return 1
}

item_label() {
    local i
    i=$(dc_code_index "${1:-}") || { printf '%s' "${1:-}"; return; }
    printf '%s' "${DC_CODE_LABELS[$i]}"
}

item_desc() {
    local i
    i=$(dc_code_index "${1:-}") || { printf '%s' ""; return; }
    printf '%s' "${DC_CODE_DESCS[$i]}"
}

is_sudo_id() {
    local i
    i=$(dc_code_index "${1:-}") || return 1
    [[ "${DC_CODE_SUDOS[$i]}" == "1" ]]
}

# is_sudo_path <path>：路径落在需要提权的系统位置
is_sudo_path() {
    case "${1:-}" in
        /tmp/*|/private/tmp/*|/Library/*|/private/var/*|"/") return 0 ;;
    esac
    return 1
}

list_items() {
    local i
    for ((i = 0; i < DC_CODE_COUNT; i++)); do
        if [[ "${DC_CODE_SUDOS[$i]}" == "1" ]]; then
            printf '  %-14s %s    [需 sudo]\n' "${DC_CODE_IDS[$i]}" "${DC_CODE_LABELS[$i]}"
        else
            printf '  %-14s %s\n' "${DC_CODE_IDS[$i]}" "${DC_CODE_LABELS[$i]}"
        fi
        printf '  %-14s   %s\n' "" "${DC_CODE_DESCS[$i]}"
    done
    printf '%s\n' \
        "" \
        "不含在本脚本里的：" \
        "  opencode 数据库瘦身：由 disk-cleanup skill 走 cleanup-opencode.sh（先备份、先闭库、再 VACUUM）" \
        "  iOS 设备备份、聊天记录、虚拟机镜像等用户数据：只报告大小与路径，不代删"
}

list_items_json() {
    local i sep="" sudo
    printf '{"schema":%s,"codes":[' "${DC_SCHEMA_VERSION}"
    for ((i = 0; i < DC_CODE_COUNT; i++)); do
        sudo=false
        [[ "${DC_CODE_SUDOS[$i]}" == "1" ]] && sudo=true
        printf '%s{"id":"%s","label":"%s","desc":"%s","sudo":%s}' \
            "$sep" "$(json_esc "${DC_CODE_IDS[$i]}")" "$(json_esc "${DC_CODE_LABELS[$i]}")" \
            "$(json_esc "${DC_CODE_DESCS[$i]}")" "$sudo"
        sep=","
    done
    printf ']}\n'
}

normalize_ids() {
    local raw="$1" out="" id
    local OLD_IFS="$IFS"
    IFS=','
    for id in $raw; do
        id=$(printf '%s' "$id" | tr -d '[:space:]')
        [[ -z "$id" ]] && continue
        out="${out}${out:+,}${id}"
    done
    IFS="$OLD_IFS"
    printf '%s' "$out"
}

validate_ids() {
    local raw="$1" flag="$2" id
    local OLD_IFS="$IFS"
    IFS=','
    for id in $raw; do
        id=$(printf '%s' "$id" | tr -d '[:space:]')
        [[ -z "$id" ]] && continue
        case " $KNOWN_IDS " in
            *" $id "*) ;;
            *)
                printf '未知清理项: %s（%s）；可用编码: %s\n' "$id" "$flag" "$KNOWN_IDS" >&2
                IFS="$OLD_IFS"
                exit 2 ;;
        esac
    done
    IFS="$OLD_IFS"
}

# want <id>：当前选择是否包含该编码（ONLY/SKIP 用逗号包裹比较）
want() {
    local id="$1"
    if [[ -n "${ONLY_IDS:-}" ]]; then
        case "$ONLY_IDS" in *",$id,"*) ;; *) return 1 ;; esac
    fi
    if [[ -n "${SKIP_IDS:-}" ]]; then
        case "$SKIP_IDS" in *",$id,"*) return 1 ;; esac
    fi
    return 0
}

mark_unselected() {
    case ",${UNSELECTED_IDS:-}," in
        *",$1,"*) ;;
        *) UNSELECTED_IDS="${UNSELECTED_IDS:-}${UNSELECTED_IDS:+,}$1" ;;
    esac
}
