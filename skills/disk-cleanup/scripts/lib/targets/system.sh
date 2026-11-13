#!/usr/bin/env bash
# targets: system 组（用户缓存/日志/临时/快照/废纸篓/应用缓存/更新残留/系统日志）
# 约定（所有 target 文件一致）：
#   target_<id>()  只读测量：算 total/del、打印行、设置 STEP_* 与 PLAN_CMD，最后调 run
#   clean_<id>()   执行：只能用 lib/safety.sh 的漏斗原语，不得直接 rm
# 变量必须在函数间共享时用全局（run 在同一 shell 里稍后调用）。
[[ -n "${_DC_T_SYSTEM_LOADED:-}" ]] && return 0
_DC_T_SYSTEM_LOADED=1

# ---------------- caches ----------------
# 已知纯缓存/更新器：整目录清理，不套 mtime 阈值（浏览器会持续 touch 缓存条目）
is_purge_cache() {
    local n
    n=$(lower "$1")
    case "$n" in
        "microsoft edge"|"google"|"google/chrome"|"chromium"|"bravesoftware"|"vivaldi"|"opera"|"firefox") return 0 ;;
        *updater*|*-updater) return 0 ;;
        "com.apple.softwareupdate"|"com.apple.appstore"|"com.apple.appstoreagent") return 0 ;;
        "com.apple.safari"|"safari") return 0 ;;
    esac
    return 1
}

# Google 下还有别的 App 数据，只删 Chrome 子目录
cache_purge_targets() {
    local entry="${1:-}" n
    [[ -n "$entry" ]] || return 0
    n=$(lower "$(basename -- "$entry")")
    case "$n" in
        "google") printf '%s\n' "${entry}/Chrome" ;;
        "microsoft edge"|"chromium"|"bravesoftware"|"vivaldi"|"opera"|"firefox") printf '%s\n' "$entry" ;;
        *updater*|*-updater) printf '%s\n' "$entry" ;;
        "com.apple.softwareupdate"|"com.apple.appstore"|"com.apple.appstoreagent") printf '%s\n' "$entry" ;;
        "com.apple.safari"|"safari") printf '%s\n' "$entry" ;;
    esac
}

CACHE_DIR=""
CACHE_PURGE_LIST=""
CACHE_AGED_LIST=""
CACHE_TOP=""
CACHE_PURGE_N=0

clean_caches() {
    local tgt
    while IFS= read -r tgt; do
        [[ -n "$tgt" ]] || continue
        dc_delete_one "$tgt" >/dev/null 2>&1 || true
    done < <(printf '%s\n' "$CACHE_PURGE_LIST")
    while IFS= read -r tgt; do
        [[ -n "$tgt" ]] || continue
        dc_delete_aged "$tgt" "$CACHE_AGE_DAYS" >/dev/null 2>&1 || true
    done < <(printf '%s\n' "$CACHE_AGED_LIST")
    STEP_NOTE="$(dc_deleted_summary)"
    [[ "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

target_caches() {
    local entry name sz tgt purge_targets purge_used denied total del
    dc_section caches
    CACHE_DIR="$HOME/Library/Caches"
    CACHE_PURGE_LIST=""
    CACHE_AGED_LIST=""
    CACHE_TOP=""
    CACHE_PURGE_N=0
    if [[ ! -d "$CACHE_DIR" ]]; then
        say "  未找到 ~/Library/Caches，跳过"
        return 0
    fi
    total=$(du_kb "$CACHE_DIR")
    del=0
    denied=$(denied_count "$CACHE_DIR")
    for entry in "$CACHE_DIR"/*; do
        [[ -e "$entry" ]] || continue
        name=$(basename "$entry")
        purge_used=0
        purge_targets=$(cache_purge_targets "$entry")
        if [[ -n "$purge_targets" ]]; then
            while IFS= read -r tgt; do
                [[ -n "$tgt" ]] || continue
                [[ -e "$tgt" ]] || continue
                purge_used=1
                sz=$(du_kb "$tgt")
                del=$((del + sz))
                CACHE_PURGE_LIST="${CACHE_PURGE_LIST}${tgt}"$'\n'
                CACHE_PURGE_N=$((CACHE_PURGE_N + 1))
                CACHE_TOP="${CACHE_TOP}${sz}	${tgt#"$CACHE_DIR"/}（纯缓存，整删）"$'\n'
            done < <(printf '%s\n' "$purge_targets")
        fi
        if [[ "$purge_used" == "0" ]]; then
            sz=$(subset_kb "$entry" "$CACHE_AGE_DAYS")
            del=$((del + sz))
            [[ "$sz" -gt 0 ]] && CACHE_AGED_LIST="${CACHE_AGED_LIST}${entry}"$'\n'
            CACHE_TOP="${CACHE_TOP}${sz}	${name}（${CACHE_AGE_DAYS} 天前可删）"$'\n'
        fi
    done
    say "  目录总量: $(human "$total") / 本次可删（按阈值实测）: $(human "$del")"
    say "  最大子项（按可删量）:"
    printf '%s' "$CACHE_TOP" | sort -rn | head -5 | while IFS=$'\t' read -r kb nm; do
        [[ -n "${nm:-}" ]] && say "    - $(human "$kb")  ${nm}"
    done
    [[ "$denied" -gt 0 ]] && say "  ⚠️ ${denied} 个受保护子目录未计入（TCC）"
    STEP_TOTAL_KB="$total"
    STEP_DEL_KB="$del"
    STEP_PATH="$CACHE_DIR"
    STEP_SAMPLE=$(printf '%s' "$CACHE_PURGE_LIST" | head -5)
    PLAN_CMD="整删 ${CACHE_PURGE_N} 个纯缓存目录；其余按 ${CACHE_AGE_DAYS} 天阈值删过期文件"
    run caches "清理用户缓存（纯缓存整删 + 其余按 mtime 阈值）" clean_caches
}

# ---------------- logs ----------------
LOG_DIR=""

clean_logs() {
    dc_delete_aged "$LOG_DIR" "$LOG_AGE_DAYS"
}

target_logs() {
    local total del denied
    dc_section logs
    LOG_DIR="$HOME/Library/Logs"
    if [[ ! -d "$LOG_DIR" ]]; then
        say "  未找到 ~/Library/Logs，跳过"
        return 0
    fi
    total=$(du_kb "$LOG_DIR")
    del=$(subset_kb "$LOG_DIR" "$LOG_AGE_DAYS")
    denied=$(denied_count "$LOG_DIR")
    say "  目录总量: $(human "$total") / 本次可删（${LOG_AGE_DAYS} 天前）: $(human "$del")"
    [[ "$denied" -gt 0 ]] && say "  ⚠️ ${denied} 个受保护条目未计入"
    STEP_TOTAL_KB="$total"
    STEP_DEL_KB="$del"
    STEP_PATH="$LOG_DIR"
    PLAN_CMD="只删 ${LOG_AGE_DAYS} 天前的日志文件，再清掉因此变空的目录"
    run logs "清理 ${LOG_AGE_DAYS} 天前未改动的用户日志文件" clean_logs
}

# ============================================================
# system 组共用小工具（只在本文件内使用）
# ============================================================

# sys_total_kb <dir>：目录总量；读不到输出 -1（JSON 语义：-1 = 读不到，不是 0）
sys_total_kb() {
    local dir="${1:-}" kb
    [[ -n "$dir" && -d "$dir" ]] || { printf '0'; return 0; }
    kb=$(du_kb "$dir")
    if [[ "${kb:-0}" -eq 0 ]] && ! run_timeout "$DC_TIMEOUT_QUICK" ls -A "$dir" >/dev/null 2>&1; then
        printf '%s' -1
        return 0
    fi
    printf '%s' "${kb:-0}"
}

# sys_top_kb <dir> <find 谓词...>：把「会被整删的顶层条目」逐个 du 求和（KB）
# 谓词必须与 clean_* 里的 find 完全一致，保证测量与执行同一口径。
sys_top_kb() {
    local dir="${1:-}" kb=0 p sz
    shift
    [[ -n "$dir" && -d "$dir" ]] || { printf '0'; return 0; }
    while IFS= read -r -d '' p; do
        sz=$(du_kb "$p")
        kb=$((kb + ${sz:-0}))
    done < <(run_timeout "$DC_TIMEOUT_FIND" find "$dir" -mindepth 1 -maxdepth 1 "$@" -print0 2>/dev/null)
    printf '%s' "$kb"
}

# sys_sample_aged <dir> <days> <n>：dry-run/clean 回执里给 agent 核对的 sample_paths
sys_sample_aged() {
    local dir="${1:-}" days="${2:-1}" n="${3:-5}"
    [[ -n "$dir" && -d "$dir" ]] || return 0
    run_timeout "$DC_TIMEOUT_FIND" find "$dir" -mindepth 1 \( -type f -o -type l \) -mtime +"$days" -print 2>/dev/null | head -"$n"
}

# ---------------- tmp ----------------
# /tmp 是 /private/tmp 的软链：find 对作为起始点的软链默认不跟进（`find /tmp -mindepth 1`
# 恒为 0 条，清理会静默空转），所以统一走真实路径。
TMP_DIR="/private/tmp"
TMP_AGE_DAYS=1

clean_tmp() {
    # sudo 由 run 的 gate 决定是否放行；这里只声明本次删除需要 root
    dc_delete_aged "$TMP_DIR" "$TMP_AGE_DAYS" 1
}

target_tmp() {
    local total del denied
    dc_section tmp
    TMP_DIR="/private/tmp"
    TMP_AGE_DAYS="${CACHE_AGE_DAYS:-1}"
    if [[ ! -d "$TMP_DIR" ]]; then
        say "  未找到 ${TMP_DIR}，跳过"
        return 0
    fi
    total=$(sys_total_kb "$TMP_DIR")
    del=$(subset_kb "$TMP_DIR" "$TMP_AGE_DAYS")
    denied=$(denied_count "$TMP_DIR")
    if [[ "$total" -lt 0 ]]; then
        say "  目录总量: 需 sudo（当前用户读不到 ${TMP_DIR}；已可读部分按 ${TMP_AGE_DAYS} 天阈值估算可删 $(human "$del")）"
    else
        say "  目录总量: $(human "$total") / 本次可删（${TMP_AGE_DAYS} 天前，近似）: $(human "$del")"
    fi
    say "  注：/tmp 是 /private/tmp 的软链，脚本统一走真实路径；完整总量需 sudo 才可读。"
    [[ "$denied" -gt 0 ]] && say "  ⚠️ ${denied} 个条目因权限未计入（root 专有目录 / TCC）"
    STEP_TOTAL_KB="$total"
    STEP_DEL_KB="$del"
    STEP_PATH="$TMP_DIR"
    STEP_SAMPLE=$(sys_sample_aged "$TMP_DIR" "$TMP_AGE_DAYS" 5)
    PLAN_CMD="sudo bash ${DC_SCRIPT_DIR}/mac_cleanup.sh --clean --only tmp（只删 ${TMP_AGE_DAYS} 天前的内容，逐条走删除漏斗）"
    run tmp "清理 ${TMP_DIR} 中 ${TMP_AGE_DAYS} 天前的临时内容" clean_tmp
}

# ---------------- varfolders ----------------
# /var/folders 是系统临时/缓存容器。只清当前用户（uid）容器下的明确残留，
# 系统/他人沙箱目录（如 _zz）不碰，避免权限噪音。
VF_DIR=""
VF_AGE_DAYS=7
VF_GO_AGE_DAYS=1

find_user_varfolders() {
    local uid d u
    uid=$(id -u 2>/dev/null)
    [[ -n "$uid" ]] || return 1
    for d in /var/folders/*/*/; do
        [[ -d "$d" ]] || continue
        u=$(run_timeout "$DC_TIMEOUT_QUICK" stat -f %u "$d" 2>/dev/null) || u=""
        if [[ "$u" == "$uid" ]]; then
            printf '%s' "${d%/}"
            return 0
        fi
    done
    return 1
}

clean_varfolders() {
    # T/C：删 7 天前的文件/链接，再清掉因此变空的目录
    dc_delete_aged "$VF_DIR/T" "$VF_AGE_DAYS"
    dc_delete_aged "$VF_DIR/C" "$VF_AGE_DAYS"
    # X：只删顶层条目（*code_sign_clone* 整个目录 + 7 天前条目）；非空目录必须整棵删，
    # 所以列出来逐条走漏斗，而不是靠 find 的浅层删除。
    dc_delete_paths_stdin < <(run_timeout "$DC_TIMEOUT_FIND" find "$VF_DIR/X" -mindepth 1 -maxdepth 1 \
        \( -name '*code_sign_clone*' -o -mtime +"$VF_AGE_DAYS" \) -print0 2>/dev/null)
    # T/go-build*：同样是顶层目录，超 ${VF_GO_AGE_DAYS} 天整棵删
    dc_delete_paths_stdin < <(run_timeout "$DC_TIMEOUT_FIND" find "$VF_DIR/T" -mindepth 1 -maxdepth 1 \
        -type d -name 'go-build*' -mtime +"$VF_GO_AGE_DAYS" -print0 2>/dev/null)
    STEP_NOTE="$(dc_deleted_summary)"
    [[ "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

target_varfolders() {
    local total del denied whole
    dc_section varfolders
    VF_DIR=$(find_user_varfolders)
    if [[ -z "$VF_DIR" ]]; then
        say "  ⚠️ 未定位到当前用户的 /var/folders 容器目录，跳过本步清理。"
        return 0
    fi
    total=$(du_kb "$VF_DIR")
    # 测量与删除谓词一致：T/C 按 mtime 求文件大小；X 与 go-build 按「会被整删的顶层条目」du 求和
    del=$(( $(subset_kb "$VF_DIR/T" "$VF_AGE_DAYS") + $(subset_kb "$VF_DIR/C" "$VF_AGE_DAYS") \
        + $(sys_top_kb "$VF_DIR/X" "(" -name '*code_sign_clone*' -o -mtime +"$VF_AGE_DAYS" ")") \
        + $(sys_top_kb "$VF_DIR/T" -type d -name 'go-build*' -mtime +"$VF_GO_AGE_DAYS") ))
    denied=$(denied_count "$VF_DIR")
    whole=$(du_kb /var/folders)
    say "  当前用户容器目录: ${VF_DIR}（uid $(id -u 2>/dev/null)）"
    say "  目录总量: $(human "$total") / 本次可删（T/C/X 超 ${VF_AGE_DAYS} 天 + go-build 超 ${VF_GO_AGE_DAYS} 天，顶层条目实测）: $(human "$del")"
    say "  参考：/var/folders 全量占用 $(human "$whole")（含他人沙箱，仅当前用户部分可读、可清）"
    [[ "$denied" -gt 0 ]] && say "  ⚠️ ${denied} 个条目因权限未计入"
    STEP_TOTAL_KB="$total"
    STEP_DEL_KB="$del"
    STEP_PATH="$VF_DIR"
    STEP_SAMPLE=$(sys_sample_aged "$VF_DIR/T" "$VF_AGE_DAYS" 5)
    PLAN_CMD="T/C 删超 ${VF_AGE_DAYS} 天的文件与空目录；X 删 *code_sign_clone* 与超 ${VF_AGE_DAYS} 天的顶层条目；T/go-build* 删超 ${VF_GO_AGE_DAYS} 天的整棵目录（全部逐条走删除漏斗）"
    run varfolders "清理当前用户 /var/folders 的过期残留" clean_varfolders
}

# ---------------- snapshots ----------------
# v1 只数 com.apple.*，会漏报第三方本地快照（Synology / CCC 等）：它们不由 tmutil 管理，
# thinlocalsnapshots 不会处理，必须单独报出来让用户去对应 App 里删。
SNAP_APPLE_N=0
SNAP_THIRD_N=0
SNAP_THIRD_DESC=""
SNAP_LIST_OK=0
DC_TIMEOUT_SNAPSHOT="${DC_TIMEOUT_SNAPSHOT:-300}"

# snapshot_kind <快照名>：apple | Synology | CCC | 其它备份工具 | 未知来源
snapshot_kind() {
    local n
    n=$(lower "${1:-}")
    case "$n" in
        com.apple.*) printf 'apple' ;;
        *synology*|*activebackup*) printf 'Synology' ;;
        *bombich*|*carboncopy*|*carbon-copy*) printf 'CCC' ;;
        *arq*|*backblaze*|*druva*) printf '其它备份工具' ;;
        *) printf '未知来源' ;;
    esac
}

clean_snapshots() {
    local rc=0
    if [[ "$SNAP_APPLE_N" -le 0 ]]; then
        if [[ "$SNAP_LIST_OK" != "1" ]]; then
            STEP_NOTE="未能列出本地快照（需 sudo 或完全磁盘访问权限），未执行 thinlocalsnapshots"
        else
            STEP_NOTE="无 Apple 本地快照，未执行 thinlocalsnapshots；第三方 ${SNAP_THIRD_N} 个需在对应 App 内删除"
        fi
        return 0
    fi
    if [[ "${DC_PLAN_MODE:-0}" == "1" ]]; then
        dc_plan_command "sudo tmutil thinlocalsnapshots / 999999999999 4（Apple 本地快照 ${SNAP_APPLE_N} 个）"
        return 0
    fi
    run_timeout "$DC_TIMEOUT_SNAPSHOT" sudo -n tmutil thinlocalsnapshots / 999999999999 4 || rc=$?
    if [[ "$rc" -eq 124 ]]; then
        STEP_NOTE="thinlocalsnapshots 超时（系统会继续在后台精简，可稍后复查快照数）"
        return 1
    fi
    if [[ "$rc" -ne 0 ]]; then
        STEP_NOTE="thinlocalsnapshots 失败（退出码 ${rc}）：需在用户自己的终端执行（可能要完全磁盘访问权限）"
        return 1
    fi
    STEP_NOTE="已请求精简 Apple 快照 ${SNAP_APPLE_N} 个（回滚粒度变粗，系统会重建）；第三方 ${SNAP_THIRD_N} 个不在 tmutil 管辖内"
    return 0
}

target_snapshots() {
    local out="" line kind rc=0 syn=0 ccc=0 other=0 s
    dc_section snapshots
    SNAP_APPLE_N=0
    SNAP_THIRD_N=0
    SNAP_THIRD_DESC=""
    SNAP_LIST_OK=0
    if ! command -v tmutil >/dev/null 2>&1; then
        say "  未找到 tmutil，跳过"
        return 0
    fi
    out=$(run_timeout "$DC_TIMEOUT_QUERY" tmutil listlocalsnapshots / 2>/dev/null) || rc=$?
    [[ "$rc" -eq 0 ]] && SNAP_LIST_OK=1
    while IFS= read -r line; do
        line=$(printf '%s' "$line" | tr -d '\r')
        case "$line" in ''|'Snapshots for'*) continue ;; esac
        kind=$(snapshot_kind "$line")
        case "$kind" in
            apple)
                SNAP_APPLE_N=$((SNAP_APPLE_N + 1))
                continue ;;
            Synology) syn=$((syn + 1)) ;;
            CCC) ccc=$((ccc + 1)) ;;
            *) other=$((other + 1)) ;;
        esac
        SNAP_THIRD_N=$((SNAP_THIRD_N + 1))
    done < <(printf '%s\n' "$out")
    [[ "$syn" -gt 0 ]] && SNAP_THIRD_DESC="${SNAP_THIRD_DESC}${SNAP_THIRD_DESC:+、}Synology ${syn} 个"
    [[ "$ccc" -gt 0 ]] && SNAP_THIRD_DESC="${SNAP_THIRD_DESC}${SNAP_THIRD_DESC:+、}CCC ${ccc} 个"
    [[ "$other" -gt 0 ]] && SNAP_THIRD_DESC="${SNAP_THIRD_DESC}${SNAP_THIRD_DESC:+、}其它/未知来源 ${other} 个"
    STEP_TOTAL_KB=0
    STEP_DEL_KB=0
    STEP_PATH="/"
    # 一个快照都没有也要走 run：编码必须出现在 items[]/codes[] 里，
    # 否则 agent 无法区分「没有快照」和「这项没跑」。
    if [[ "$SNAP_APPLE_N" -eq 0 && "$SNAP_THIRD_N" -eq 0 ]]; then
        if [[ "$rc" -ne 0 ]]; then
            say "  未能列出本地快照（tmutil 需要 sudo 或「完全磁盘访问权限」），不执行 thinlocalsnapshots"
            PLAN_CMD="tmutil listlocalsnapshots / 需要 sudo 或完全磁盘访问权限；列不出来时不执行 thinlocalsnapshots"
        else
            say "  未发现本地快照（或 tmutil 需要「完全磁盘访问权限」才能列出），无需精简"
            PLAN_CMD="未发现本地快照，thinlocalsnapshots 无需执行"
        fi
        run snapshots "精简本地快照（快速模式）" clean_snapshots
        return 0
    fi
    say "  Apple 本地快照: ${SNAP_APPLE_N} 个（占用由系统按快照策略计算，脚本不估算）"
    if [[ "$SNAP_THIRD_N" -gt 0 ]]; then
        say "  第三方本地快照: ${SNAP_THIRD_N} 个（${SNAP_THIRD_DESC}）"
        say "     不是 Time Machine 快照，thinlocalsnapshots 不会处理；请在 Synology Active Backup / CCC 等 App 内清理。"
    fi
    if [[ "$SNAP_APPLE_N" -gt 0 ]]; then
        s=$(printf 'Apple 快照 %s 个；thinlocalsnapshots 快速模式' "$SNAP_APPLE_N")
        PLAN_CMD="sudo tmutil thinlocalsnapshots / 999999999999 4（${s}）"
    else
        PLAN_CMD="无 Apple 本地快照，不执行 thinlocalsnapshots；第三方 ${SNAP_THIRD_N} 个需在对应 App 内清理"
    fi
    run snapshots "精简本地快照（快速模式）" clean_snapshots
}

# ---------------- trash ----------------
TRASH_DIR=""

clean_trash() {
    local left=0 p
    # 用 NUL 分隔遍历，覆盖 .Trash 里的隐藏项（glob * 不匹配 dotfile）
    dc_delete_paths_stdin < <(run_timeout "$DC_TIMEOUT_QUICK" find "$TRASH_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    # 回读：仍有条目（受保护/被占用/并发写入）如实报出来，不当成功
    while IFS= read -r -d '' p; do
        left=$((left + 1))
    done < <(run_timeout "$DC_TIMEOUT_QUICK" find "$TRASH_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    STEP_NOTE="$(dc_deleted_summary)；仍剩 ${left} 项"
    [[ "$left" -le "$DC_DEL_PROTECTED" && "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

target_trash() {
    local total del denied
    dc_section trash
    TRASH_DIR="$HOME/.Trash"
    if [[ ! -d "$TRASH_DIR" ]]; then
        say "  未找到废纸篓，跳过"
        return 0
    fi
    total=$(sys_total_kb "$TRASH_DIR")
    denied=$(denied_count "$TRASH_DIR")
    del="$total"
    [[ "$total" -lt 0 ]] && del=0
    if [[ "$total" -lt 0 ]]; then
        # ~/.Trash 由 TCC 保护：读不到通常是缺「完全磁盘访问权限」，与 sudo 无关
        say "  占用大小: 读不到（TCC/沙箱拒绝访问废纸篓，不是缺 sudo；清后不可恢复，请确认再执行）"
    else
        say "  占用大小: $(human "$total")（清空后不可恢复）"
    fi
    [[ "$denied" -gt 0 ]] && say "  ⚠️ ${denied} 个条目因权限未计入"
    STEP_TOTAL_KB="$total"
    STEP_DEL_KB="$del"
    STEP_PATH="$TRASH_DIR"
    STEP_SAMPLE=$(run_timeout "$DC_TIMEOUT_QUICK" find "$TRASH_DIR" -mindepth 1 -maxdepth 1 -print 2>/dev/null | head -5)
    PLAN_CMD="清空 ${TRASH_DIR} 下的全部条目（含隐藏项，逐条走删除漏斗；清后不可恢复）"
    run trash "清空废纸篓" clean_trash
}

# ---------------- appcache ----------------
# 只清 Electron/Chromium 型的渲染与 JS 缓存；配置、登录态、Local Storage、IndexedDB 一律不动。
APP_SUPPORT=""
APPCACHE_LIST=""
APPCACHE_TOP=""
APPCACHE_TOTAL_KB=0
APPCACHE_MIN_KB=10240

# appcache_subdirs：可清缓存子目录（名字含空格，必须逐行读，不能按 $IFS 切）
appcache_subdirs() {
    printf '%s\n' \
        "Cache" \
        "GPUCache" \
        "Code Cache" \
        "CachedData" \
        "CachedExtensionVSIXs" \
        "DawnGraphiteCache" \
        "DawnWebGPUCache" \
        "GrShaderCache" \
        "ShaderCache" \
        "Service Worker/CacheStorage"
}

clean_appcache() {
    local tgt
    while IFS= read -r tgt; do
        [[ -n "$tgt" ]] || continue
        dc_delete_one "$tgt" >/dev/null 2>&1 || true
    done < <(printf '%s\n' "$APPCACHE_LIST")
    STEP_NOTE="$(dc_deleted_summary)（app 首次启动会重建）"
    [[ "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

target_appcache() {
    local app sub d sz n=0
    dc_section appcache
    APP_SUPPORT="$HOME/Library/Application Support"
    APPCACHE_LIST=""
    APPCACHE_TOP=""
    APPCACHE_TOTAL_KB=0
    if [[ ! -d "$APP_SUPPORT" ]]; then
        say "  未找到 ~/Library/Application Support，跳过"
        return 0
    fi
    for app in "$APP_SUPPORT"/*; do
        [[ -d "$app" ]] || continue
        while IFS= read -r sub; do
            [[ -n "$sub" ]] || continue
            d="$app/$sub"
            [[ -d "$d" ]] || continue
            sz=$(du_kb "$d")
            # < 10MB 不进清单：减少噪音，也避免把 app 频繁重建的小缓存当目标
            [[ "$sz" -lt "$APPCACHE_MIN_KB" ]] && continue
            APPCACHE_TOTAL_KB=$((APPCACHE_TOTAL_KB + sz))
            APPCACHE_LIST="${APPCACHE_LIST}${d}"$'\n'
            APPCACHE_TOP="${APPCACHE_TOP}${sz}	${d#"$APP_SUPPORT"/}"$'\n'
            n=$((n + 1))
        done < <(appcache_subdirs)
    done
    say "  本次可删合计: $(human "$APPCACHE_TOTAL_KB")（>10MB 的 app 内缓存目录，共 ${n} 个）"
    printf '%s' "$APPCACHE_TOP" | sort -rn | head -8 | while IFS=$'\t' read -r kb nm; do
        [[ -n "${nm:-}" ]] && say "    - $(human "$kb")  ${nm}"
    done
    say "  注：这些是 app 自己的渲染/JS 缓存，删除后首次启动会重建（不动配置与登录态）。"
    STEP_TOTAL_KB="$APPCACHE_TOTAL_KB"
    STEP_DEL_KB="$APPCACHE_TOTAL_KB"
    STEP_PATH="$APP_SUPPORT"
    STEP_SAMPLE=$(printf '%s' "$APPCACHE_LIST" | head -5)
    PLAN_CMD="整删上列 ${n} 个 >10MB 的 Cache / GPUCache / Code Cache / CachedData 目录（逐条走删除漏斗，不碰配置与登录态）"
    run appcache "清理 app 内嵌缓存目录" clean_appcache
}

# ---------------- updaters ----------------
UPD_LIST=""
UPD_TOP=""
UPD_TOTAL_KB=0

clean_updaters() {
    local tgt
    while IFS= read -r tgt; do
        [[ -n "$tgt" ]] || continue
        dc_delete_one "$tgt" >/dev/null 2>&1 || true
    done < <(printf '%s\n' "$UPD_LIST")
    STEP_NOTE="$(dc_deleted_summary)"
    [[ "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

target_updaters() {
    local d sz n=0
    dc_section updaters
    APP_SUPPORT="$HOME/Library/Application Support"
    UPD_LIST=""
    UPD_TOP=""
    UPD_TOTAL_KB=0
    if [[ ! -d "$APP_SUPPORT" ]]; then
        say "  未找到 ~/Library/Application Support，跳过"
        return 0
    fi
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        [[ -d "$d" ]] || continue
        sz=$(du_kb "$d")
        [[ "$sz" -lt "$APPCACHE_MIN_KB" ]] && continue
        UPD_TOTAL_KB=$((UPD_TOTAL_KB + sz))
        UPD_LIST="${UPD_LIST}${d}"$'\n'
        UPD_TOP="${UPD_TOP}${sz}	${d#"$APP_SUPPORT"/}"$'\n'
        n=$((n + 1))
    done < <(run_timeout "$DC_TIMEOUT_FIND" find "$APP_SUPPORT" -maxdepth 4 -type d \
        \( -name crx_cache -o -name auto-updater -o -name app-recovery-cache -o -name UpdateCache \) \
        -prune -print 2>/dev/null)
    say "  本次可删合计: $(human "$UPD_TOTAL_KB")（>10MB 的更新残留目录，共 ${n} 个）"
    printf '%s' "$UPD_TOP" | sort -rn | head -8 | while IFS=$'\t' read -r kb nm; do
        [[ -n "${nm:-}" ]] && say "    - $(human "$kb")  ${nm}"
    done
    say "  注：crx_cache / auto-updater / app-recovery-cache 是更新下载残留，删后下次更新会重新下载。"
    STEP_TOTAL_KB="$UPD_TOTAL_KB"
    STEP_DEL_KB="$UPD_TOTAL_KB"
    STEP_PATH="$APP_SUPPORT"
    STEP_SAMPLE=$(printf '%s' "$UPD_LIST" | head -5)
    PLAN_CMD="整删上列 ${n} 个 >10MB 的 crx_cache / auto-updater / app-recovery-cache / UpdateCache 目录（逐条走删除漏斗）"
    run updaters "清理应用自动更新下载残留" clean_updaters
}

# ---------------- systemlogs（v2 新增） ----------------
# 7 天前的崩溃报告与系统日志（系统会重建）。削量分批判，单批不超过 5 条：
# 一条命令删几百个文件既难复盘也难中断，分批走漏斗能把每次动作留在台账里。
SYSLOG_REPORTS="/Library/Logs/DiagnosticReports"
SYSLOG_VARLOG="/private/var/log"
SYSLOG_AGE_DAYS=7
SYSLOG_BATCH_MAX=5
SYSLOG_BATCH=()

# syslog_flush_batch：把当前批（≤ SYSLOG_BATCH_MAX 条）交给漏斗，然后清空批
syslog_flush_batch() {
    [[ ${#SYSLOG_BATCH[@]} -gt 0 ]] || return 0
    dc_delete_paths_stdin 1 < <(printf '%s\0' "${SYSLOG_BATCH[@]}")
    SYSLOG_BATCH=()
}

clean_systemlogs() {
    local root p
    for root in "$SYSLOG_REPORTS" "$SYSLOG_VARLOG"; do
        [[ -d "$root" ]] || continue
        SYSLOG_BATCH=()
        while IFS= read -r -d '' p; do
            SYSLOG_BATCH[${#SYSLOG_BATCH[@]}]="$p"
            if [[ ${#SYSLOG_BATCH[@]} -ge "$SYSLOG_BATCH_MAX" ]]; then
                syslog_flush_batch
            fi
        done < <(run_timeout "$DC_TIMEOUT_FIND" find "$root" -mindepth 1 \( -type f -o -type l \) \
            -mtime +"$SYSLOG_AGE_DAYS" -print0 2>/dev/null)
        syslog_flush_batch
    done
    STEP_NOTE="$(dc_deleted_summary)（单批 ≤${SYSLOG_BATCH_MAX} 条）"
    [[ "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

target_systemlogs() {
    local root t d n denied=0 total=0 del=0 sample="" s
    dc_section systemlogs
    SYSLOG_AGE_DAYS="${SYSTEMLOG_AGE_DAYS:-7}"
    is_pos_int "$SYSLOG_AGE_DAYS" || SYSLOG_AGE_DAYS=7
    SYSLOG_BATCH=()
    for root in "$SYSLOG_REPORTS" "$SYSLOG_VARLOG"; do
        if [[ ! -d "$root" ]]; then
            say "  未找到 ${root}，跳过"
            continue
        fi
        t=$(sys_total_kb "$root")
        d=$(subset_kb "$root" "$SYSLOG_AGE_DAYS")
        n=$(denied_count "$root")
        denied=$((denied + n))
        if [[ "$t" -lt 0 ]]; then
            say "  ${root}: 需 sudo（当前用户读不到总量）/ 已可读部分 ${SYSLOG_AGE_DAYS} 天前可删 $(human "$d")"
            total=-1
        else
            say "  ${root}: $(human "$t") / 本次可删（${SYSLOG_AGE_DAYS} 天前）: $(human "$d")"
            [[ "$total" -ge 0 ]] && total=$((total + t))
        fi
        del=$((del + d))
        s=$(sys_sample_aged "$root" "$SYSLOG_AGE_DAYS" 5)
        if [[ -n "$s" ]]; then
            if [[ -n "$sample" ]]; then sample="${sample}"$'\n'"${s}"; else sample="$s"; fi
        fi
    done
    [[ "$denied" -gt 0 ]] && say "  ⚠️ ${denied} 个条目因权限未计入（root 专有）"
    sample=$(printf '%s\n' "$sample" | head -5)
    STEP_TOTAL_KB="$total"
    STEP_DEL_KB="$del"
    STEP_PATH="$SYSLOG_REPORTS"
    STEP_SAMPLE="$sample"
    PLAN_CMD="sudo bash ${DC_SCRIPT_DIR}/mac_cleanup.sh --clean --only systemlogs（只删 ${SYSLOG_AGE_DAYS} 天前的文件，单批 ≤${SYSLOG_BATCH_MAX} 条）"
    run systemlogs "清理 ${SYSLOG_AGE_DAYS} 天前的系统崩溃报告与系统日志（单批 ≤${SYSLOG_BATCH_MAX} 条）" clean_systemlogs
}
