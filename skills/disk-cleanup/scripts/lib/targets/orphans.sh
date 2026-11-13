#!/usr/bin/env bash
# targets: orphans —— 已卸载 App 的残留（A/B 双档，只报告；删除只认 --orphans-delete 点名）
#
# macOS 没有「谁装过什么」的台账，只能反推。判定链：
#   候选 = ORPHAN_ROOTS 的顶层条目（find -maxdepth 1，绝不递归全盘）
#   A 档（高置信）= 只在三根（Caches / Logs / Saved Application State）
#                  + 名字是反向 DNS（^(com|org|net|io)\.[A-Za-z0-9.-]+$）
#                  + 树内 ORPHANS_AGE_DAYS 天无写入（tree_active 为假）
#                  + 归属证明全部为负（运行中 / 内嵌次级 id / pkgutil receipts / Spotlight 反查）
#   B 档（低置信）= 其余根，沿用 v1 的名字匹配；标 confidence=low、措辞「需人工确认」，
#                  不计入可删量（只进文本与 JSON 的 candidates）
#
# 删除：--clean --only orphans --orphans-delete <路径>，三重校验（存在 / 扫描根直接子项 /
#       本次候选），任一不过 exit 1；删除全部经 safety.sh 的漏斗（dc_delete_one），不直接 rm。
# 入口设置的全局：ORPHANS_AGE_DAYS / ORPHANS_DELETE_LIST / ORPHANS_NEED_SUDO /
#                 ORPHANS_LIST_ALL / ORPHANS_MAX / ORPHAN_CANDIDATE_PATHS
[[ -n "${_DC_T_ORPHANS_LOADED:-}" ]] && return 0
_DC_T_ORPHANS_LOADED=1

# ---------------- 扫描根 ----------------
# A 档三根：卸载后几乎只会是「App 自己的纯数据」，且不碰用户内容
ORPHANS_A_ROOTS=(
    "$HOME/Library/Caches"
    "$HOME/Library/Logs"
    "$HOME/Library/Saved Application State"
)
# B 档：其余 12 根（v1 全集去掉 A 档两处）。容器/偏好可能同名不同家，一律低置信。
ORPHANS_B_ROOTS=(
    "$HOME/Library/Application Support"
    "$HOME/Library/Preferences"
    "$HOME/Library/Containers"
    "$HOME/Library/Group Containers"
    "$HOME/Library/HTTPStorages"
    "$HOME/Library/LaunchAgents"
    "/Library/Application Support"
    "/Library/Preferences"
    "/Library/Caches"
    "/Library/LaunchAgents"
    "/Library/LaunchDaemons"
    "/Library/PrivilegedHelperTools"
)
# prevalidate 的「扫描根」= 两档合集（A 档路径也是合法候选来源）
ORPHAN_ROOTS=("${ORPHANS_A_ROOTS[@]}" "${ORPHANS_B_ROOTS[@]}")

# ---------------- 跨函数状态 ----------------
ORPHAN_ROWS_A=""          # kb \t path \t age \t sudo \t size_unknown
ORPHAN_ROWS_B=""
ORPHAN_CANDIDATE_PATHS=() # 本次扫描命中（A+B）；--orphans-delete 只认这批
ORPHAN_A_KB=0
ORPHAN_B_KB=0
ORPHAN_A_N=0
ORPHAN_B_N=0
ORPHAN_UNKNOWN=0
ORPHAN_NOW=0
ORPHAN_DELETED_KB=0
ORPHAN_SIZE_KEYS=()       # 每根一次 du 的批量结果（路径 → KB）
ORPHAN_SIZE_VALS=()

# 已装 App 名单（v1 四级匹配：id / 段 / 名字 / 词 / 前缀 / 厂商）
APP_ID_SET="|"
APP_SEG_SET="|"
APP_NAME_SET="|"
APP_TOKEN_SET="|"
APP_NAME_PREFIX_SET="|"
APP_VENDORS=""
ORPHAN_APP_PATHS=()       # 已装 .app 路径（内嵌 id 扫描用）
ORPHAN_APP_IDS=()         # 对应的小写 bundle id
ORPHAN_APP_ALNUM=()       # 对应的名字归一串
ORPHAN_APPS_LOADED=0

# 归属证明用的一次性缓存
ORPHAN_RUNNING_LOADED=0
ORPHAN_RUNNING_IDS=()
ORPHAN_EMBED_IDS=()
ORPHAN_EMBED_SCANNED="|"
ORPHAN_PKG_LOADED=0
ORPHAN_PKG_APPS=()

# ---------------- 名字工具 ----------------
# orphan_alnum_var <str>：只留 a-z0-9，结果写进全局 ALNUM_OUT（不 fork）
ALNUM_OUT=""
orphan_alnum_var() {
    local s="${1:-}" i c
    ALNUM_OUT=""
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-z0-9]) ALNUM_OUT="${ALNUM_OUT}${c}" ;;
        esac
    done
}

# orphan_name_is_reverse_dns <名字>：A 档名字门槛
orphan_name_is_reverse_dns() {
    [[ "${1:-}" =~ ^(com|org|net|io)\.[A-Za-z0-9.-]+$ ]]
}

# is_generic_seg <bundle id 段>：太通用的段不能反推归属（StepFun Desktop 会被 .desktop 掩盖）
is_generic_seg() {
    case "${1:-}" in
        desktop|client|helper|update|updater|service|shared|plugin|widget|launcher|extension) return 0 ;;
        framework|runtime|electron|binary|server|daemon|installer|preferences|application) return 0 ;;
    esac
    return 1
}

# orphan_skip <小写原名>：系统/共用组件不是「某个 App 的残留」
orphan_skip() {
    case "${1:-}" in
        com.apple|com.apple.*|group.com.apple|group.com.apple.*) return 0 ;;
        apple|"app store"|appstore|"script editor"|btserver|livefsd|proapps|ilifemediabrowser) return 0 ;;
        cloudkit|familycircle|crashreporter|diagnosticreports|install|installation|dws) return 0 ;;
        systemconfiguration|logging|opendirectory|directoryservice|xsan|security|audio) return 0 ;;
        org.cups.*) return 0 ;;
        homebrew|pnpm|go-build|ms-playwright|cocoapods) return 0 ;;
    esac
    return 1
}

# orphan_purge_cache_name <名字>：~/.Library/Caches 里由 caches 编码负责的纯缓存/更新器，不重复报
orphan_purge_cache_name() {
    local n
    n=$(lower "${1:-}")
    if declare -F is_purge_cache >/dev/null 2>&1; then
        is_purge_cache "$n" && return 0
    fi
    case "$n" in
        "microsoft edge"|google|google/chrome|chromium|bravesoftware|vivaldi|opera|firefox) return 0 ;;
        *updater*|*-updater) return 0 ;;
        "com.apple.softwareupdate"|"com.apple.appstore"|"com.apple.appstoreagent") return 0 ;;
        "com.apple.safari"|safari) return 0 ;;
    esac
    return 1
}

# ---------------- 已装 App 名单 ----------------
load_installed_apps() {
    local root app bid nm id seg tok raw_name old_ifs v1 v2 rest i
    for root in "/Applications" "/System/Applications" "$HOME/Applications" \
                "/Library/Input Methods" "$HOME/Library/Input Methods"; do
        [[ -d "$root" ]] || continue
        while IFS= read -r app; do
            [[ -n "$app" ]] || continue
            bid=$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null) || bid=""
            raw_name=$(lower "$(basename "$app" .app)")
            if [[ -n "$bid" ]]; then
                id=$(lower "$bid")
                APP_ID_SET="${APP_ID_SET}${id}|"
                v1="${id%%.*}"
                rest="${id#*.}"
                if [[ "$rest" == *.* ]]; then
                    v2="${rest%%.*}"
                    APP_VENDORS="${APP_VENDORS}${v1}.${v2}"$'\n'
                fi
                # 段（com.bilibili.bilibiliPC → bilibili / bilibilipc）
                old_ifs="$IFS"; IFS='.'
                for seg in $id; do
                    [[ ${#seg} -ge 6 ]] || continue
                    is_generic_seg "$seg" && continue
                    APP_SEG_SET="${APP_SEG_SET}${seg}|"
                done
                IFS="$old_ifs"
            fi
            orphan_alnum_var "$raw_name"; nm="$ALNUM_OUT"
            if [[ -n "$nm" ]]; then
                APP_NAME_SET="${APP_NAME_SET}${nm}|"
                i=4
                while [[ "$i" -le "${#nm}" ]]; do
                    APP_NAME_PREFIX_SET="${APP_NAME_PREFIX_SET}${nm:0:i}|"
                    i=$((i + 1))
                done
            fi
            old_ifs="$IFS"; IFS=' .-_'
            for tok in $raw_name; do
                [[ ${#tok} -ge 4 ]] && APP_TOKEN_SET="${APP_TOKEN_SET}${tok}|"
            done
            IFS="$old_ifs"
            ORPHAN_APP_PATHS+=("$app")
            ORPHAN_APP_IDS+=("${id:-}")
            ORPHAN_APP_ALNUM+=("$nm")
        done < <(find "$root" -maxdepth 3 -name '*.app' -prune -print 2>/dev/null)
    done
}

orphan_ensure_apps() {
    [[ "$ORPHAN_APPS_LOADED" == "1" ]] && return 0
    ORPHAN_APPS_LOADED=1
    load_installed_apps
}

# entry_is_installed <小写原名> <名字归一串>：命中 = 属于已装 App，不是残留
entry_is_installed() {
    local lc="${1:-}" nm="${2:-}" cur t p i comp old_ifs
    # 1) bundle id：完全相等 / 子 bundle / 以段开头
    cur="$lc"
    while :; do
        t="${cur#"${cur%%[a-z0-9]*}"}"
        [[ -n "$t" ]] || t="$cur"
        [[ "$APP_ID_SET" == *"|${t}|"* ]] && return 0
        [[ "$APP_SEG_SET" == *"|${t}|"* ]] && return 0
        case "$cur" in
            *[.-]*) cur="${cur%[.-]*}" ;;
            *) break ;;
        esac
    done
    # 2) 名字：完全相等 / 条目以 App 名开头 / 条目是 App 名的前缀 / 独立词
    if [[ -n "$nm" ]]; then
        [[ "$APP_NAME_SET" == *"|${nm}|"* ]] && return 0
        [[ "$APP_TOKEN_SET" == *"|${nm}|"* ]] && return 0
        [[ "$APP_NAME_PREFIX_SET" == *"|${nm}|"* ]] && return 0
        i=${#nm}
        while [[ "$i" -ge 4 ]]; do
            [[ "$APP_NAME_SET" == *"|${nm:0:i}|"* ]] && return 0
            i=$((i - 1))
        done
    fi
    # 3) 条目里的某一段就是 App 名/名字前缀 → 它的组件
    old_ifs="$IFS"
    IFS='.-'
    for comp in $lc; do
        comp="${comp#"${comp%%[a-z0-9]*}"}"
        if [[ ${#comp} -ge 4 ]] && { [[ "$APP_NAME_SET" == *"|${comp}|"* ]] \
             || [[ "$APP_TOKEN_SET" == *"|${comp}|"* ]] \
             || [[ "$APP_NAME_PREFIX_SET" == *"|${comp}|"* ]]; }; then
            IFS="$old_ifs"
            return 0
        fi
    done
    IFS="$old_ifs"
    # 4) helper/daemon：与已装 App 同厂商前缀 → 它的组件
    case "$lc" in
        *helper*|*daemon*|*.agent|*.service|*.xpc|*.plugin)
            while IFS= read -r p; do
                [[ -n "$p" ]] || continue
                [[ "$lc" == "$p".* ]] && return 0
            done < <(printf '%s\n' "$APP_VENDORS")
            ;;
    esac
    return 1
}

# ---------------- 归属证明（A 档必过；任一命中 = 其实还装着） ----------------
# orphan_id_relates <候选 id> <已装/运行中 id>：相等，或互为点分前缀
orphan_id_relates() {
    local a="${1:-}" b="${2:-}"
    [[ -n "$a" && -n "$b" ]] || return 1
    [[ "$a" == "$b" ]] && return 0
    case "$a" in "$b".*) return 0 ;; esac
    case "$b" in "$a".*) return 0 ;; esac
    return 1
}

# ① 运行中进程的 bundle id（osascript 失败时内核兜底 lsappinfo）
orphan_running_match() {
    local id="${1:-}" i
    [[ -n "$id" ]] || return 1
    if [[ "$ORPHAN_RUNNING_LOADED" != "1" ]]; then
        ORPHAN_RUNNING_LOADED=1
        while IFS= read -r i; do
            [[ -n "$i" ]] && ORPHAN_RUNNING_IDS+=("$(lower "$i")")
        done < <(app_bundle_ids_running 2>/dev/null)
    fi
    for ((i = 0; i < ${#ORPHAN_RUNNING_IDS[@]}; i++)); do
        orphan_id_relates "$id" "${ORPHAN_RUNNING_IDS[$i]}" && return 0
    done
    return 1
}

# orphan_scan_embedded <app>：扫一次内嵌次级 id 并缓存（每个 .app 最多一次）
orphan_scan_embedded() {
    local app="$1" e
    case "$ORPHAN_EMBED_SCANNED" in *"|${app}|"*) return 0 ;; esac
    ORPHAN_EMBED_SCANNED="${ORPHAN_EMBED_SCANNED}${app}|"
    while IFS= read -r e; do
        [[ -n "$e" ]] && ORPHAN_EMBED_IDS+=("$(lower "$e")")
    done < <(embedded_bundle_ids "$app" 2>/dev/null)
}

# orphan_app_looks_related <候选 id> <名字归一串> <app 路径> <app 名归一串> <app id>：
# 只对「名字或厂商相近」的少数 .app 做内嵌扫描（性能：embedded_bundle_ids 要遍历 Contents）
orphan_app_looks_related() {
    local id="$1" nm="$2" an="$4" aid="$5" v1 v2
    orphan_names_related "$nm" "$an" && return 0
    if [[ -n "$id" && -n "$aid" ]]; then
        v1="${id#*.}"; v1="${v1%%.*}"
        v2="${aid#*.}"; v2="${v2%%.*}"
        [[ -n "$v1" && "$v1" == "$v2" ]] && return 0
    fi
    return 1
}

# ② 内嵌次级 bundle id（helper/更新器/LoginItems）
orphan_embedded_match() {
    local id="$1" nm="$2" i app an aid scanned=0 e
    [[ -n "$id" ]] || return 1
    for ((i = 0; i < ${#ORPHAN_APP_PATHS[@]} && scanned < 3; i++)); do
        app="${ORPHAN_APP_PATHS[$i]}"
        an="${ORPHAN_APP_ALNUM[$i]:-}"
        aid="${ORPHAN_APP_IDS[$i]:-}"
        orphan_app_looks_related "$id" "$nm" "$app" "$an" "$aid" || continue
        scanned=$((scanned + 1))
        orphan_scan_embedded "$app"
        for ((e = 0; e < ${#ORPHAN_EMBED_IDS[@]}; e++)); do
            orphan_id_relates "$id" "${ORPHAN_EMBED_IDS[$e]}" && return 0
        done
    done
    return 1
}

# ③ pkgutil receipts 登记的 .app（装在 /opt、/usr/local 等非标准位置）
# 注意：内核的 pkg_apps 只打印结果、不写 DC_PKG_APPS，所以本文件自行缓存一份。
orphan_load_pkg_apps() {
    [[ "$ORPHAN_PKG_LOADED" == "1" ]] && return 0
    ORPHAN_PKG_LOADED=1
    local a out
    out=$(pkg_apps 2>/dev/null) || out=""
    [[ -n "$out" ]] || return 0
    while IFS= read -r a; do
        [[ -n "$a" ]] && ORPHAN_PKG_APPS+=("$a")
    done < <(printf '%s\n' "$out")
}

# orphan_names_related <a> <b>：两边归一串互为前缀（≥4 字符）
orphan_names_related() {
    local a="${1:-}" b="${2:-}"
    [[ ${#a} -ge 4 && ${#b} -ge 4 ]] || return 1
    case "$a" in "$b"*) return 0 ;; esac
    case "$b" in "$a"*) return 0 ;; esac
    return 1
}

orphan_pkg_match() {
    local id="$1" nm="$2" i app an pbid
    [[ -n "$id" ]] || return 1
    orphan_load_pkg_apps
    for ((i = 0; i < ${#ORPHAN_PKG_APPS[@]}; i++)); do
        app="${ORPHAN_PKG_APPS[$i]}"
        [[ -d "$app" && "$app" == *.app ]] || continue
        an=$(lower "$(basename "$app" .app)")
        # 名字不像就不读 Info.plist（每读一次一个 plutil 进程）
        orphan_names_related "$nm" "$an" || continue
        pbid=$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null) || pbid=""
        pbid=$(lower "$pbid")
        [[ -n "$pbid" ]] && orphan_id_relates "$id" "$pbid" && return 0
    done
    return 1
}

# orphan_owned_by_installed <候选 id> <名字归一串>：0 = 还有 App 归它（不是残留）
orphan_owned_by_installed() {
    local id="${1:-}" nm="${2:-}"
    orphan_ensure_apps
    entry_is_installed "$id" "$nm" && return 0                 # ① 名单四级匹配
    orphan_running_match "$id" && return 0                     # ② 运行中
    orphan_embedded_match "$id" "$nm" && return 0              # ③ 内嵌次级 id
    orphan_pkg_match "$id" "$nm" && return 0                   # ④ receipts
    app_is_installed "$id" && return 0                         # ⑤ Spotlight（fail-closed）
    return 1
}

# ---------------- --orphans-delete 的三重校验 ----------------
# 第一重（不依赖扫描）：绝对路径 / 无尾斜杠 / 无 . 与 .. 组件 / 存在 / 扫描根直接子项。
dc_orphans_prevalidate() {
    local p pdir base resolved root_real ok out=""
    [[ -n "${ORPHANS_DELETE_LIST:-}" ]] || return 0
    while IFS= read -r p; do
        p="${p%$'\r'}"
        [[ -n "$p" ]] || continue
        case "$p" in
            /*) ;;
            *) printf -- '--orphans-delete 需要绝对路径: %s\n' "$p" >&2; exit 1 ;;
        esac
        case "$p" in
            */) printf -- '--orphans-delete 不接受以 / 结尾的路径（会被当成整目录）: %s\n' "$p" >&2; exit 1 ;;
        esac
        case "/${p}/" in
            *"/../"*|*"/./"*) printf -- "--orphans-delete 路径不能包含 '..' 或 '.' 组件: %s\n" "$p" >&2; exit 1 ;;
        esac
        if [[ ! -e "$p" ]]; then
            printf -- '--orphans-delete 路径不存在: %s\n' "$p" >&2
            exit 1
        fi
        base=$(basename -- "$p")
        pdir=$(cd -- "$(dirname -- "$p")" 2>/dev/null && pwd -P) || {
            printf -- '--orphans-delete 父目录不可访问: %s\n' "$p" >&2
            exit 1
        }
        resolved="${pdir}/${base}"
        ok=0
        for root_real in "${ORPHAN_ROOTS[@]}"; do
            [[ -d "$root_real" ]] || continue
            root_real=$(cd -- "$root_real" 2>/dev/null && pwd -P) || continue
            if [[ "$resolved" == "$root_real" ]]; then
                printf -- '--orphans-delete 不能指向扫描根本身: %s\n' "$p" >&2
                exit 1
            fi
            [[ "$pdir" == "$root_real" ]] && ok=1
        done
        if [[ "$ok" != "1" ]]; then
            printf -- '--orphans-delete 只接受扫描根的直接子项: %s\n' "$p" >&2
            exit 1
        fi
        is_sudo_path "$resolved" && ORPHANS_NEED_SUDO=1
        out="${out}${resolved}"$'\n'
    done < <(printf '%s\n' "$ORPHANS_DELETE_LIST")
    ORPHANS_DELETE_LIST="$out"
}

# 第三重（扫描后）：必须在本次候选里，否则 exit 1（这条是 v1 的既有优势，不能弱化）
dc_orphans_validate_candidates() {
    local p c found
    [[ -n "${ORPHANS_DELETE_LIST:-}" ]] || return 0
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        found=0
        for c in "${ORPHAN_CANDIDATE_PATHS[@]:-}"; do
            [[ "$c" == "$p" ]] && { found=1; break; }
        done
        if [[ "$found" != "1" ]]; then
            printf -- '--orphans-delete 路径不在本次残留候选里（可能已安装、已被过滤或名字写错）: %s\n' "$p" >&2
            exit 1
        fi
    done < <(printf '%s\n' "$ORPHANS_DELETE_LIST")
}

# ---------------- 大小：每根一次批量 du（只对通过筛选的候选取大小） ----------------
orphan_du_batch() {
    [[ $# -gt 0 ]] || return 0
    local out kb p
    out=$(run_timeout "$DC_TIMEOUT_DU" du -sk -- "$@" 2>/dev/null) || out=""
    [[ -n "$out" ]] || return 0
    while IFS=$' \t' read -r kb p; do
        [[ -n "${kb:-}" && -n "${p:-}" ]] || continue
        ORPHAN_SIZE_KEYS+=("$p")
        ORPHAN_SIZE_VALS+=("$kb")
    done < <(printf '%s\n' "$out")
}

# orphan_size_kb <path>：批量结果里查；查不到输出空（= 未知，不是 0）
orphan_size_kb() {
    local p="$1" i
    for ((i = 0; i < ${#ORPHAN_SIZE_KEYS[@]}; i++)); do
        if [[ "${ORPHAN_SIZE_KEYS[$i]}" == "$p" ]]; then
            printf '%s' "${ORPHAN_SIZE_VALS[$i]}"
            return 0
        fi
    done
    printf '%s' ""
}

# ---------------- JSON：items[].confidence + candidates[] ----------------
# orphan_rows_json <rows> <high|low>：把一行行候选折成 candidates[] 片段，结果写 ORPHAN_JSON_OUT
ORPHAN_JSON_OUT=""
orphan_rows_json() {
    local rows="$1" conf="$2" out="" sep="" kb p age sd un tier sudo_json un_json
    ORPHAN_JSON_OUT=""
    [[ -n "$rows" ]] || return 0
    if [[ "$conf" == "high" ]]; then tier="a"; else tier="b"; fi
    while IFS=$'\t' read -r kb p age sd un; do
        [[ -n "${p:-}" ]] || continue
        if [[ "$sd" == "1" ]]; then sudo_json="true"; else sudo_json="false"; fi
        if [[ "$un" == "1" ]]; then un_json="true"; else un_json="false"; fi
        out="${out}${sep}{\"path\":\"$(json_esc "$p")\",\"kb\":${kb:-0},\"age_days\":${age:-0},\"tier\":\"${tier}\",\"confidence\":\"${conf}\",\"sudo\":${sudo_json},\"size_unknown\":${un_json}}"
        sep=","
    done < <(printf '%s\n' "$rows")
    ORPHAN_JSON_OUT="$out"
}

# json_orphans_emit <status> <reason>
json_orphans_emit() {
    local status="$1" reason="${2:-ok}" cands="" conf
    conf="low"
    [[ "$ORPHAN_A_N" -gt 0 ]] && conf="high"
    orphan_rows_json "$ORPHAN_ROWS_A" "high"
    cands="$ORPHAN_JSON_OUT"
    orphan_rows_json "$ORPHAN_ROWS_B" "low"
    if [[ -n "$ORPHAN_JSON_OUT" ]]; then
        cands="${cands:+${cands},}${ORPHAN_JSON_OUT}"
    fi
    DC_ITEM_CONFIDENCE="$conf"
    DC_ITEM_CANDIDATES="$cands"
    STEP_TOTAL_KB="$ORPHAN_A_KB"
    STEP_DEL_KB="$ORPHAN_A_KB"
    STEP_REASON="$reason"
    STEP_NOTE="A ${ORPHAN_A_N} 项 / B ${ORPHAN_B_N} 项 ${ORPHAN_B_KB}KB（不计入可删）/ 大小未知 ${ORPHAN_UNKNOWN} 项"
    json_add orphans "$(item_label orphans)" "$status"
}

# ---------------- 文本渲染 ----------------
# orphan_render_rows <rows> <limit> <confidence> <low 0|1>
orphan_render_rows() {
    local rows="$1" limit="$2" conf="$3" low="$4" kb p age sd un shown line total
    [[ -n "$rows" ]] || { say "    （无）"; return 0; }
    printf '%s' "$rows" | sort -t"$(printf '\t')" -k1,1 -rn | head -n "$limit" | \
    while IFS=$'\t' read -r kb p age sd un; do
        [[ -n "${p:-}" ]] || continue
        shown="${age}"
        if [[ "$conf" == "high" && ${ORPHANS_AGE_DAYS:-30} -gt 0 && ${age:-0} -lt ${ORPHANS_AGE_DAYS} ]]; then
            shown="${ORPHANS_AGE_DAYS}+"
        fi
        line="    - $(human "${kb:-0}")  ${p/#$HOME/~}  （${shown} 天未改动"
        [[ "$low" == "1" ]] && line="${line}，需人工确认"
        line="${line}，confidence=${conf}"
        [[ "$sd" == "1" ]] && line="${line}，需 sudo"
        [[ "$un" == "1" ]] && line="${line}，大小未知"
        say "${line}）"
    done
}

# ---------------- 删除（逐条走漏斗） ----------------
clean_orphans() {
    local p use_sudo rc ok=0 skip=0 fails=0 sudo_blocked=0 n=0 sz
    ORPHAN_DELETED_KB=0
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        n=$((n + 1))
        use_sudo=0
        if is_sudo_path "$p"; then
            use_sudo=1
            if [[ "$SUDO_OK" != "1" ]]; then
                say "      [跳过·需 sudo] ${p}"
                sudo_blocked=$((sudo_blocked + 1))
                continue
            fi
        fi
        sz=$(orphan_size_kb "$p")
        rc=0
        dc_delete_one "$p" "$use_sudo" || rc=$?
        case "$rc" in
            0) ok=$((ok + 1)); ORPHAN_DELETED_KB=$((ORPHAN_DELETED_KB + ${sz:-0})) ;;
            1) skip=$((skip + 1)) ;;
            *) fails=$((fails + 1)) ;;
        esac
    done < <(printf '%s\n' "$ORPHANS_DELETE_LIST")
    STEP_NOTE="点名 ${n} 项：已删 ${ok} / 跳过 ${skip} / 失败 ${fails}"
    [[ "$sudo_blocked" -gt 0 ]] && STEP_NOTE="${STEP_NOTE} / 待 sudo ${sudo_blocked}"
    say "      ${STEP_NOTE}"
    if [[ "$sudo_blocked" -gt 0 ]]; then
        say "      需 sudo 的路径请在用户自己的终端重跑（可交互输入密码，仍走本脚本漏斗）："
        say "        $0 --clean --only orphans --orphans-delete '<路径>'"
    fi
    [[ "$fails" -eq 0 ]]
}

# ---------------- target ----------------
target_orphans() {
    local root root_real tier i n limit conf s
    local entry base lc nm resolved kb age row_sudo row_un mtime_now
    dc_section orphans
    ORPHAN_ROWS_A=""
    ORPHAN_ROWS_B=""
    ORPHAN_CANDIDATE_PATHS=()
    ORPHAN_A_KB=0; ORPHAN_B_KB=0; ORPHAN_A_N=0; ORPHAN_B_N=0; ORPHAN_UNKNOWN=0
    ORPHAN_SIZE_KEYS=(); ORPHAN_SIZE_VALS=()
    ORPHAN_NOW=$(date +%s)
    ORPHANS_NEED_SUDO="${ORPHANS_NEED_SUDO:-0}"
    limit="${ORPHANS_MAX:-15}"
    [[ "${ORPHANS_LIST_ALL:-0}" == "1" ]] && limit=1000000

    if [[ "$CLEAN" == "1" ]] && ! want orphans; then
        LAST_RUN_SELECTED=0
        mark_unselected orphans
        say "   [跳过] 已卸载 App 残留（未勾选：orphans）"
        STEP_REASON="unselected"
        json_orphans_emit "skipped-unselected" "unselected"
        return 0
    fi
    LAST_RUN_SELECTED=1

    local entries=() names=() lowers=()
    local keep=() keep_names=() keep_lc=()
    local t_keep=() t_names=() t_lc=()
    for root in "${ORPHAN_ROOTS[@]}"; do
        [[ -d "$root" ]] || continue
        root_real=$(cd -- "$root" 2>/dev/null && pwd -P) || root_real="$root"
        tier="b"
        for s in "${ORPHANS_A_ROOTS[@]}"; do
            [[ "$root" == "$s" ]] && tier="a"
        done
        entries=(); names=(); lowers=()
        keep=(); keep_names=(); keep_lc=()
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            entries+=("$entry")
            names+=("${entry##*/}")
        done < <(find "$root" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
        n=${#entries[@]}
        [[ "$n" -gt 0 ]] || continue
        # 一个根只 fork 一次 tr：逐条目 lower 会为每个条目起一次子进程（实测把扫描拖到几十秒）
        while IFS= read -r lc; do
            lowers+=("$lc")
        done < <(printf '%s\n' "${names[@]}" | tr '[:upper:]' '[:lower:]')

        # 第一道筛选（零 fork）：名字门槛 → 系统组件 → 已装名单四级匹配
        for ((i = 0; i < n; i++)); do
            entry="${entries[$i]}"
            base="${names[$i]}"
            lc="${lowers[$i]:-}"
            case "$root" in
                "$HOME/Library/Preferences"|"/Library/Preferences") lc="${lc%.plist}" ;;
            esac
            orphan_alnum_var "$lc"; nm="$ALNUM_OUT"
            orphan_skip "$lc" && continue
            if [[ "$tier" == "a" ]]; then
                # A 档只看反向 DNS 名；其余名字不列（~/Library/Caches 已由 caches 编码覆盖）
                orphan_name_is_reverse_dns "$base" || continue
                if [[ "$root" == "$HOME/Library/Caches" ]] && orphan_purge_cache_name "$base"; then
                    continue
                fi
            else
                # 目录名恰好是 $PATH 上的命令（CLI 工具的数据目录）不算 GUI App 残留
                case "$lc" in
                    *[!a-z0-9_-]*) ;;
                    *) command -v "$lc" >/dev/null 2>&1 && continue ;;
                esac
            fi
            orphan_ensure_apps
            entry_is_installed "$lc" "$nm" && continue
            keep+=("$entry")
            keep_names+=("$nm")
            keep_lc+=("$lc")
        done
        [[ ${#keep[@]} -gt 0 ]] || continue

        # A 档第二道：无写入满 ORPHANS_AGE_DAYS 天
        #   目录用 tree_active（O(1)，看树内最近文件；超时按活跃保守处理）
        #   文件没有「树」，退回自身 mtime
        if [[ "$tier" == "a" ]]; then
            t_keep=(); t_names=(); t_lc=()
            local mfile_age mfile_mtime
            for ((i = 0; i < ${#keep[@]}; i++)); do
                s="${keep[$i]}"
                if [[ -d "$s" ]]; then
                    tree_active "$s" "${ORPHANS_AGE_DAYS:-30}" && continue
                elif [[ -f "$s" ]]; then
                    mfile_mtime=$(stat -f '%m' "$s" 2>/dev/null) || mfile_mtime=0
                    [[ -n "$mfile_mtime" ]] || mfile_mtime=0
                    [[ "$mfile_mtime" -gt 0 ]] || continue
                    mfile_age=$(( (ORPHAN_NOW - mfile_mtime) / 86400 ))
                    [[ "$mfile_age" -ge "${ORPHANS_AGE_DAYS:-30}" ]] || continue
                else
                    continue
                fi
                t_keep+=("$s")
                t_names+=("${keep_names[$i]}")
                t_lc+=("${keep_lc[$i]}")
            done
            keep=(); keep_names=(); keep_lc=()
            if [[ ${#t_keep[@]} -gt 0 ]]; then
                keep=("${t_keep[@]}"); keep_names=("${t_names[@]}"); keep_lc=("${t_lc[@]}")
            fi
            [[ ${#keep[@]} -gt 0 ]] || continue
        fi

        # 只对本根幸存者批量取大小（一次 du 覆盖，不递归全盘）
        orphan_du_batch "${keep[@]}"

        for ((i = 0; i < ${#keep[@]}; i++)); do
            entry="${keep[$i]}"
            base="${entry##*/}"
            lc="${keep_lc[$i]:-}"
            nm="${keep_names[$i]:-}"
            resolved="${root_real}/${base}"
            # 归属证明（A 档必过；任一命中 = 其实还装着，直接不进 A 档）
            if [[ "$tier" == "a" ]]; then
                orphan_owned_by_installed "$lc" "$nm" && continue
            fi
            kb=$(orphan_size_kb "$resolved")
            mtime_now=$(stat -f '%m' "$resolved" 2>/dev/null) || mtime_now=0
            [[ -n "$mtime_now" ]] || mtime_now=0
            age=0
            [[ "$mtime_now" -gt 0 ]] && age=$(( (ORPHAN_NOW - mtime_now) / 86400 ))
            [[ "$age" -lt 0 ]] && age=0
            row_sudo=0
            row_un=0
            is_sudo_path "$resolved" && row_sudo=1
            [[ -z "$kb" ]] && { row_un=1; ORPHAN_UNKNOWN=$((ORPHAN_UNKNOWN + 1)); }
            kb="${kb:-0}"
            ORPHAN_CANDIDATE_PATHS+=("$resolved")
            if [[ "$tier" == "a" ]]; then
                ORPHAN_ROWS_A="${ORPHAN_ROWS_A}${kb}	${resolved}	${age}	${row_sudo}	${row_un}"$'\n'
                ORPHAN_A_KB=$((ORPHAN_A_KB + kb))
                ORPHAN_A_N=$((ORPHAN_A_N + 1))
            else
                ORPHAN_ROWS_B="${ORPHAN_ROWS_B}${kb}	${resolved}	${age}	${row_sudo}	${row_un}"$'\n'
                ORPHAN_B_KB=$((ORPHAN_B_KB + kb))
                ORPHAN_B_N=$((ORPHAN_B_N + 1))
            fi
        done
    done

    # --orphans-delete 的候选归属校验（第三重，必须在扫描之后）
    dc_orphans_validate_candidates

    say "  扫描根 ${#ORPHAN_ROOTS[@]} 个（A 档 ${#ORPHANS_A_ROOTS[@]} / B 档 ${#ORPHANS_B_ROOTS[@]}；只看每根顶层）"
    say "  A 档 ${ORPHAN_A_N} 项，合计 $(human "$ORPHAN_A_KB")  ← 可删候选（仍需点名）"
    say "  B 档 ${ORPHAN_B_N} 项，合计 $(human "$ORPHAN_B_KB")  ← 低置信，不计入可删量"
    if [[ "$ORPHAN_UNKNOWN" -gt 0 ]]; then
        say "  ⚠️ 另有 ${ORPHAN_UNKNOWN} 项大小读不到（TCC/权限拒绝），未计入合计——按未知处理，不是 0。"
    fi
    if [[ "$ORPHAN_A_N" -eq 0 && "$ORPHAN_B_N" -eq 0 ]]; then
        say "  未发现疑似残留。"
    fi
    if [[ "$ORPHAN_A_N" -gt 0 ]]; then
        say "  A 档（高置信 confidence=high：三根 + 反向 DNS 名 + ${ORPHANS_AGE_DAYS} 天无写入 + 归属证明全负）:"
        orphan_render_rows "$ORPHAN_ROWS_A" "$limit" "high" "0"
    fi
    if [[ "$ORPHAN_B_N" -gt 0 ]]; then
        say "  B 档（低置信 confidence=low：其余根，需人工确认，不计入可删量）:"
        orphan_render_rows "$ORPHAN_ROWS_B" "$limit" "low" "1"
    fi
    [[ "${ORPHANS_LIST_ALL:-0}" != "1" ]] && \
        say "  （每档只显示最大的 ${ORPHANS_MAX:-15} 项；--orphans-list 看全部）"
    say "  判据是反推（已装名单 + 运行中/内嵌/receipts/Spotlight 归属证明），不是系统卸载记录：可能误报或漏报。"
    say "  只报告、不自动删除，也不参与 --all；确认后按路径点名："
    say "    bash $0 --clean --dry-run --only orphans --orphans-delete <路径> [--orphans-delete <路径> ...]"

    STEP_TOTAL_KB="$ORPHAN_A_KB"
    STEP_DEL_KB="$ORPHAN_A_KB"
    STEP_PATH="$HOME/Library/Caches"
    STEP_SAMPLE=$(printf '%s' "$ORPHAN_ROWS_A" | cut -f2 | head -5)
    PLAN_CMD="逐条删除 --orphans-delete 点名的路径（走漏斗；/Library 下需 sudo）"

    if [[ -z "${ORPHANS_DELETE_LIST:-}" ]]; then
        if [[ "$CLEAN" == "1" ]]; then
            say "   [未删] 勾了 orphans 但没给 --orphans-delete 路径：本次只报告，不删除。"
            SKIPPED_STEPS+=("卸载残留：只报告未删除（需 --orphans-delete 点名路径）")
        fi
        STEP_REASON="ok"
        json_orphans_emit "reported" "ok"
        return 0
    fi
    if [[ "$CLEAN" != "1" ]]; then
        say "   [查询] 已给出 --orphans-delete 路径，但未加 --clean，本次不删除"
        STEP_REASON="ok"
        json_orphans_emit "reported" "ok"
        return 0
    fi
    n=0
    while IFS= read -r s; do
        [[ -n "$s" ]] && n=$((n + 1))
    done < <(printf '%s\n' "$ORPHANS_DELETE_LIST")
    if [[ "$DRY_RUN" == "1" ]]; then
        say "   [预览] 将删除 ${n} 项（已校验：扫描根直接子项 + 本次候选）："
        while IFS= read -r s; do
            [[ -n "$s" ]] || continue
            _plan_sudo=0
            if is_sudo_path "$s"; then
                _plan_sudo=1
                say "      [sudo] ${s}"
            else
                say "      ${s}"
            fi
            if [[ "${DC_PLAN_ENABLED:-0}" == "1" ]]; then
                DC_PLAN_CODE="orphans"
                dc_plan_probe "$s" "$_plan_sudo" || true
            fi
        done < <(printf '%s\n' "$ORPHANS_DELETE_LIST")
        if [[ "$ORPHANS_NEED_SUDO" == "1" && "$SUDO_OK" != "1" ]]; then
            say "      其中 /Library 下的路径需 sudo：当前环境取不到，执行时会跳过并提示终端重跑。"
        fi
        STEP_REASON="ok"
        json_orphans_emit "dry-run" "ok"
        return 0
    fi
    say "   [执行] 删除 --orphans-delete 点名的 ${n} 项残留"
    local rc=0
    dc_counters_reset
    if [[ "$JSON" == "1" ]]; then
        clean_orphans >&2 || rc=$?
    else
        clean_orphans || rc=$?
    fi
    if [[ "$rc" -eq 0 ]]; then
        ESTIMATED_FREED_KB=$((ESTIMATED_FREED_KB + ORPHAN_DELETED_KB))
        REPORT_STEPS+=("删除 ${n} 项卸载残留（${STEP_NOTE}）")
        STEP_REASON="ok"
        json_orphans_emit "done" "ok"
    else
        HAD_FAILURE=1
        FAILED_COUNT=$((FAILED_COUNT + 1))
        SKIPPED_STEPS+=("删除 ${n} 项卸载残留（${STEP_NOTE}）")
        STEP_REASON=$(dc_reason_from_counters)
        json_orphans_emit "partial" "$STEP_REASON"
    fi
    return 0
}
