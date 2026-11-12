#!/usr/bin/env bash
# targets: 新编码组（规格 §8）—— browserold / groupcontainers / halfdownloads / installers
# 约定与 system.sh 一致：
#   target_<id>()  只读测量：算 total/del、打印行、设置 STEP_* 与 PLAN_CMD，最后调 run
#   clean_<id>()   执行：只能走 lib/safety.sh 的漏斗原语，不得直接 rm
# 硬规则：bash 3.2；所有外部命令经 run_timeout；读不到写「读不到」，绝不当 0。
[[ -n "${_DC_T_NEWCODES_LOADED:-}" ]] && return 0
_DC_T_NEWCODES_LOADED=1

# 阈值：HALFDL / INSTALLER 由 mac_cleanup.sh 的参数表接管（同名变量），GC 只在本文件定义。
GC_AGE_DAYS="${GC_AGE_DAYS:-7}"
HALFDL_AGE_DAYS="${HALFDL_AGE_DAYS:-30}"
INSTALLER_AGE_DAYS="${INSTALLER_AGE_DAYS:-30}"
INSTALLER_MIN_MB="${INSTALLER_MIN_MB:-100}"

# ---------------- 公用小工具 ----------------

# dc_dir_listable <dir>：0 = 目录能列出来。
# 读不到（TCC/沙箱/权限）必须与「空目录」区分开，否则会把读不到当成 0。
dc_dir_listable() {
    local d="${1:-}"
    [[ -d "$d" ]] || return 1
    run_timeout "$DC_TIMEOUT_QUICK" ls -A "$d" >/dev/null 2>&1
}

# ---------------- 运行中 App 列表（browserold / groupcontainers 共用） ----------------
DC_RUN_IDS=""
DC_RUN_IDS_LOADED=0
DC_RUN_IDS_KNOWN=1

dc_running_ids_load() {
    local out="" rc=0
    [[ "$DC_RUN_IDS_LOADED" == "1" ]] && return 0
    DC_RUN_IDS_LOADED=1
    out=$(app_bundle_ids_running 2>/dev/null) || rc=$?
    if [[ "$rc" -ne 0 || -z "$out" ]]; then
        DC_RUN_IDS_KNOWN=0
        DC_RUN_IDS=""
        return 0
    fi
    DC_RUN_IDS="$out"
    return 0
}

# dc_app_running <bundle-id>：0 = 运行中。父子 bundle id 前缀互含也算（com.foo 命中 com.foo.bar）。
dc_app_running() {
    local want="${1:-}" id
    [[ -n "$want" ]] || return 1
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        [[ "$id" == "$want" ]] && return 0
        case "$id" in "$want".*) return 0 ;; esac
        case "$want" in "$id".*) return 0 ;; esac
    done < <(printf '%s\n' "$DC_RUN_IDS")
    return 1
}

# ================= browserold =================
# 判定：Chrome/Edge/Brave 的 Application Support 与 Caches 下「纯数字版本目录」，
# 每个浏览器每个根保留 最新 1 个（sort -V 末位）+ 正在运行的那个版本；其余整删。
# 运行中版本 = App 的 CFBundleShortVersionString 与目录名同前缀（拿不到版本就只保留最新）。
BROWSER_KEYS="chrome edge brave"
BROWSER_DEL_LIST=""
BROWSER_DEL_N=0
BROWSER_KEEP_N=0
BROWSER_KEEP_RUN_N=0
BROWSER_UNREADABLE_N=0
BROWSER_EMPTY_N=0

browser_label() {
    case "$1" in
        chrome) printf '%s' "Chrome" ;;
        edge) printf '%s' "Edge" ;;
        brave) printf '%s' "Brave" ;;
    esac
}

browser_bundle_id() {
    case "$1" in
        chrome) printf '%s' "com.google.Chrome" ;;
        edge) printf '%s' "com.microsoft.edgemac" ;;
        brave) printf '%s' "com.brave.Browser" ;;
    esac
}

browser_app_path() {
    case "$1" in
        chrome) printf '%s' "/Applications/Google Chrome.app" ;;
        edge) printf '%s' "/Applications/Microsoft Edge.app" ;;
        brave) printf '%s' "/Applications/Brave Browser.app" ;;
    esac
}

# 两个根（Application Support / Caches）下的相对目录；与 macOS 真实布局一致
browser_rel_dirs() {
    case "$1" in
        chrome) printf '%s\n' "Google/Chrome" ;;
        edge) printf '%s\n' "Microsoft Edge" ;;
        brave) printf '%s\n' "BraveSoftware/Brave-Browser" ;;
    esac
}

# browser_running_version <key>：输出运行中版本的短版本号；读不到返回 1
browser_running_version() {
    local key="$1" app v=""
    app=$(browser_app_path "$key")
    [[ -n "$app" && -d "$app" ]] || return 1
    v=$(run_timeout "$DC_TIMEOUT_QUICK" plutil -extract CFBundleShortVersionString raw -o - \
        "$app/Contents/Info.plist" 2>/dev/null) || v=""
    [[ -n "$v" ]] || return 1
    printf '%s' "$v"
}

clean_browserold() {
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        dc_delete_whole "$p" >/dev/null 2>&1 || true
    done < <(printf '%s\n' "$BROWSER_DEL_LIST")
    STEP_NOTE="$(dc_deleted_summary)"
    [[ "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

target_browserold() {
    local key label bid running runv rel base dir versions vn newest vdir bn sz kept kept_why
    local total=0 del=0 keep_desc
    dc_section browserold
    BROWSER_DEL_LIST=""; BROWSER_DEL_N=0; BROWSER_KEEP_N=0
    BROWSER_KEEP_RUN_N=0; BROWSER_UNREADABLE_N=0; BROWSER_EMPTY_N=0

    dc_running_ids_load
    if [[ "$DC_RUN_IDS_KNOWN" != "1" ]]; then
        say "  运行中 App 列表读不到：无法判定「正在运行的版本」，每个浏览器只保留最新 1 个版本目录"
    fi

    for key in $BROWSER_KEYS; do
        label=$(browser_label "$key")
        bid=$(browser_bundle_id "$key")
        running=0
        dc_app_running "$bid" && running=1
        runv=""
        if [[ "$running" -eq 1 && "$DC_RUN_IDS_KNOWN" == "1" ]]; then
            runv=$(browser_running_version "$key")
            [[ -n "$runv" ]] || say "  ${label}: 正在运行但版本读不到，只保留最新 1 个版本目录"
        fi
        while IFS= read -r rel; do
            [[ -n "$rel" ]] || continue
            for base in "$HOME/Library/Application Support" "$HOME/Library/Caches"; do
                dir="$base/$rel"
                [[ -d "$dir" ]] || continue
                if ! dc_dir_listable "$dir"; then
                    BROWSER_UNREADABLE_N=$((BROWSER_UNREADABLE_N + 1))
                    say "  ${label}: ${dir#"$HOME"/} 读不到（TCC/权限），未计入"
                    continue
                fi
                versions=$(run_timeout "$DC_TIMEOUT_FIND" app_version_dirs "$dir" 2>/dev/null) || versions=""
                vn=$(printf '%s\n' "$versions" | grep -c . 2>/dev/null || true)
                [[ -n "$vn" ]] || vn=0
                if [[ "$vn" -eq 0 ]]; then
                    BROWSER_EMPTY_N=$((BROWSER_EMPTY_N + 1))
                    continue
                fi
                newest=$(printf '%s\n' "$versions" | tail -1)
                say "  ${label}（${dir#"$HOME"/}）: ${vn} 个版本目录，最新 ${newest##*/}"
                while IFS= read -r vdir; do
                    [[ -n "$vdir" ]] || continue
                    bn=$(basename "$vdir")
                    sz=$(du_kb "$vdir")
                    total=$((total + sz))
                    kept=0
                    kept_why=""
                    if [[ "$vdir" == "$newest" ]]; then
                        kept=1
                        kept_why="最新"
                    fi
                    if [[ "$kept" -eq 0 && -n "$runv" ]]; then
                        case "$bn" in
                            "$runv"|"$runv".*) kept=1; kept_why="运行中" ;;
                        esac
                    fi
                    if [[ "$kept" -eq 1 ]]; then
                        BROWSER_KEEP_N=$((BROWSER_KEEP_N + 1))
                        [[ "$kept_why" == "运行中" ]] && BROWSER_KEEP_RUN_N=$((BROWSER_KEEP_RUN_N + 1))
                        say "    保留 ${bn}（$(human "$sz")，${kept_why}）"
                    else
                        BROWSER_DEL_LIST="${BROWSER_DEL_LIST}${vdir}"$'\n'
                        BROWSER_DEL_N=$((BROWSER_DEL_N + 1))
                        del=$((del + sz))
                        say "    可删 ${bn}（$(human "$sz")）"
                    fi
                done < <(printf '%s\n' "$versions")
            done
        done < <(browser_rel_dirs "$key")
    done

    say "  版本目录合计: $(human "$total") / 本次可删（整删旧版本目录）: $(human "$del")"
    say "  保留 ${BROWSER_KEEP_N} 个（其中运行中 ${BROWSER_KEEP_RUN_N} 个）/ 可删 ${BROWSER_DEL_N} 个"
    [[ "$BROWSER_UNREADABLE_N" -gt 0 ]] && say "  ⚠️ ${BROWSER_UNREADABLE_N} 个目录读不到（未计入，不是 0）"
    [[ "$BROWSER_EMPTY_N" -gt 0 ]] && say "  另有 ${BROWSER_EMPTY_N} 个位置没有版本目录（无历史版本可清）"

    STEP_TOTAL_KB="$total"
    STEP_DEL_KB="$del"
    STEP_PATH="$HOME/Library/Application Support"
    STEP_SAMPLE=$(printf '%s' "$BROWSER_DEL_LIST" | head -5)
    keep_desc="最新 1 个"
    [[ "$BROWSER_KEEP_RUN_N" -gt 0 ]] && keep_desc="最新 1 个与正在运行的版本"
    PLAN_CMD="整删 ${BROWSER_DEL_N} 个旧版本目录（每个浏览器每个位置保留${keep_desc}）"
    run browserold "清理浏览器旧版本目录（保留最新版本与正在运行的版本）" clean_browserold
}

# ================= groupcontainers =================
# 判定：~/Library/Group Containers/*/Library/Caches，仅当「按容器名反查出的 App 未运行」，
# 且只删 7 天前的文件。容器名猜不出 App → 标「需人工」跳过；读不到 → 记读不到。
# 已知局限：daemon 型容器（如 com.apple.bird）不在 lsappinfo 的 App 列表里，靠漏斗的
# 文件级 lsof 检测兜底——仍被进程打开的缓存文件会被记 in-use 跳过。
GC_LIST=""
GC_N=0
GC_RUNNING_N=0
GC_MANUAL_N=0
GC_UNKNOWN_N=0
GC_UNREADABLE_N=0

# gc_guess_bundle <容器名>：输出猜测的 bundle id；猜不到返回 1。
# 形如 ABC1234567.group.com.vendor.app 的名字要剥「团队 ID」与「group(s).」两层。
gc_guess_bundle() {
    local n="${1:-}" head10 first rest guard=0
    [[ -n "$n" ]] || return 1
    while [[ "$guard" -lt 6 ]]; do
        guard=$((guard + 1))
        case "$n" in
            group.*|groups.*) n="${n#*.}"; continue ;;
        esac
        if [[ ${#n} -gt 11 && "${n:10:1}" == "." ]]; then
            head10="${n:0:10}"
            case "$head10" in
                *[a-z]*|*[!A-Z0-9]*) ;;
                *) n="${n:11}"; continue ;;
            esac
        fi
        break
    done
    case "$n" in
        ''|*[[:space:]]*|*/*|*..*) return 1 ;;
    esac
    first="${n%%.*}"
    rest="${n#*.}"
    [[ "$rest" != "$n" ]] || return 1
    [[ ${#first} -ge 2 && ${#first} -le 10 ]] || return 1
    case "$first" in
        *[!a-z]*) return 1 ;;
    esac
    case "$rest" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    printf '%s' "$n"
    return 0
}

clean_groupcontainers() {
    local guess caches tab
    tab=$(printf '\t')
    while IFS="$tab" read -r guess caches; do
        [[ -n "${caches:-}" ]] || continue
        # 执行前再确认一次 App 仍未运行（用户可能刚打开）
        dc_app_running "$guess" && continue
        dc_delete_aged "$caches" "$GC_AGE_DAYS" >/dev/null 2>&1 || true
    done < <(printf '%s\n' "$GC_LIST")
    STEP_NOTE="$(dc_deleted_summary)"
    [[ "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

target_groupcontainers() {
    local root entry caches name guess sz d tab total=0 del=0
    dc_section groupcontainers
    GC_LIST=""; GC_N=0; GC_RUNNING_N=0; GC_MANUAL_N=0; GC_UNKNOWN_N=0; GC_UNREADABLE_N=0
    root="$HOME/Library/Group Containers"
    if [[ ! -d "$root" ]]; then
        say "  未找到 ~/Library/Group Containers，跳过"
        return 0
    fi
    tab=$(printf '\t')
    dc_running_ids_load
    if [[ "$DC_RUN_IDS_KNOWN" != "1" ]]; then
        say "  运行中 App 列表读不到：无法确认「该容器 App 未运行」，本项不删任何东西"
    fi

    for entry in "$root"/*; do
        [[ -d "$entry" ]] || continue
        caches="$entry/Library/Caches"
        [[ -d "$caches" ]] || continue
        name=$(basename "$entry")
        sz=$(du_kb_strict "$caches")
        if [[ -z "$sz" || "$sz" -lt 0 ]]; then
            GC_UNREADABLE_N=$((GC_UNREADABLE_N + 1))
            continue
        fi
        total=$((total + sz))
        guess=$(gc_guess_bundle "$name")
        if [[ -z "$guess" ]]; then
            GC_MANUAL_N=$((GC_MANUAL_N + 1))
            [[ "$GC_MANUAL_N" -le 5 ]] && say "  - 需人工：${name}（$(human "$sz")；容器名里猜不出 App，跳过）"
            continue
        fi
        if [[ "$DC_RUN_IDS_KNOWN" != "1" ]]; then
            GC_UNKNOWN_N=$((GC_UNKNOWN_N + 1))
            continue
        fi
        if dc_app_running "$guess"; then
            GC_RUNNING_N=$((GC_RUNNING_N + 1))
            continue
        fi
        d=$(subset_kb "$caches" "$GC_AGE_DAYS")
        del=$((del + d))
        if [[ "$d" -gt 0 ]]; then
            GC_LIST="${GC_LIST}${guess}${tab}${caches}"$'\n'
            GC_N=$((GC_N + 1))
            say "  可删 ${guess}（$(human "$sz") 中 $(human "$d") 为 ${GC_AGE_DAYS} 天前）"
        fi
    done

    say "  容器缓存合计（可读部分）: $(human "$total") / 本次可删（App 未运行且 ${GC_AGE_DAYS} 天前）: $(human "$del")"
    say "  命中 ${GC_N} 个容器；运行中跳过 ${GC_RUNNING_N} 个；需人工 ${GC_MANUAL_N} 个；运行状态未知 ${GC_UNKNOWN_N} 个；读不到 ${GC_UNREADABLE_N} 个"
    [[ "$GC_MANUAL_N" -gt 0 ]] && say "  （需人工只列前 5 个：容器名不是反向 DNS，猜不出对应 App）"
    if [[ "$GC_UNREADABLE_N" -gt 0 ]]; then
        say "  ⚠️ 读不到的容器未计入（不是 0）：Group Containers 受 TCC 保护，需授予完全磁盘访问或在用户终端重试"
    fi

    STEP_TOTAL_KB="$total"
    STEP_DEL_KB="$del"
    STEP_PATH="$root"
    STEP_SAMPLE=$(printf '%s' "$GC_LIST" | cut -f2 | head -5)
    PLAN_CMD="只删 ${GC_N} 个容器下 ${GC_AGE_DAYS} 天前的缓存文件（App 运行中、需人工、读不到的跳过）"
    run groupcontainers "清理 Group Containers 内的缓存（仅 App 未运行）" clean_groupcontainers
}

# ================= halfdownloads =================
# 判定：~/Downloads 顶层 *.download（Safari，可能是目录）/*.crdownload（Chrome）/*.part，
# 必须 mtime 超过 30 天、目录树内无近期改动、且 is_path_in_use 为假。
HD_LIST=""
HD_LSOF_OK=1

clean_halfdownloads() {
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if [[ "$HD_LSOF_OK" == "1" ]] && is_path_in_use "$p"; then
            continue
        fi
        dc_delete_one "$p" >/dev/null 2>&1 || true
    done < <(printf '%s\n' "$HD_LIST")
    STEP_NOTE="$(dc_deleted_summary)"
    [[ "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

target_halfdownloads() {
    local dl="$HOME/Downloads" p sz n=0 keep=0 total=0 del=0
    dc_section halfdownloads
    HD_LIST=""; HD_LSOF_OK=1
    if [[ ! -d "$dl" ]]; then
        say "  未找到 ~/Downloads，跳过"
        return 0
    fi
    if ! dc_dir_listable "$dl"; then
        say "  ~/Downloads 读不到（TCC/权限），未计入（不是 0）"
        return 0
    fi
    if [[ "$(probe_lsof_mode)" == "none" ]]; then
        HD_LSOF_OK=0
        say "  lsof 不可用：无法验证「是否被占用」，只按 ${HALFDL_AGE_DAYS} 天未改动判定"
    fi

    while IFS= read -r -d '' p; do
        [[ -n "$p" ]] || continue
        sz=$(du_kb "$p")
        if [[ "$HD_LSOF_OK" == "1" ]] && is_path_in_use "$p"; then
            keep=$((keep + 1))
            say "  保留 $(basename "$p")（$(human "$sz")，仍被进程打开）"
            continue
        fi
        if [[ -d "$p" ]] && tree_active "$p" "$HALFDL_AGE_DAYS"; then
            keep=$((keep + 1))
            say "  保留 $(basename "$p")（$(human "$sz")，目录内仍有近期改动）"
            continue
        fi
        n=$((n + 1))
        total=$((total + sz))
        del=$((del + sz))
        HD_LIST="${HD_LIST}${p}"$'\n'
        say "  可删 $(basename "$p")（$(human "$sz")，${HALFDL_AGE_DAYS} 天未改动）"
    done < <(run_timeout "$DC_TIMEOUT_FIND" find "$dl" -mindepth 1 -maxdepth 1 \
        \( -type f -o -type d \) \
        \( -name '*.download' -o -name '*.crdownload' -o -name '*.part' \) \
        -mtime +"$HALFDL_AGE_DAYS" -print0 2>/dev/null)

    say "  命中 ${n} 个 / 保留 ${keep} 个（在用或近期仍有改动）"
    [[ "$n" -eq 0 && "$keep" -eq 0 ]] && say "  没有未完成下载残留"
    STEP_TOTAL_KB="$total"
    STEP_DEL_KB="$del"
    STEP_PATH="$dl"
    STEP_SAMPLE=$(printf '%s' "$HD_LIST" | head -5)
    PLAN_CMD="整删 ${n} 个未完成下载（*.download/*.crdownload/*.part，${HALFDL_AGE_DAYS} 天未改动且无句柄）"
    run halfdownloads "清理未完成的下载残留（*.download/*.crdownload/*.part）" clean_halfdownloads
}

# ================= installers =================
# 判定：~/Downloads 与 ~/Desktop 下 .dmg/.pkg/.iso/.xip/.zip，>100MB 且 30 天未改动。
# 100MB 下限来自 data/codes.tsv 的 desc（规格 §8：阈值以 codes.tsv 为准），五种后缀统一适用。
INST_LIST=""

clean_installers() {
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if is_path_in_use "$p"; then
            continue
        fi
        dc_delete_one "$p" >/dev/null 2>&1 || true
    done < <(printf '%s\n' "$INST_LIST")
    STEP_NOTE="$(dc_deleted_summary)"
    [[ "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

target_installers() {
    local root p sz n=0 keep=0 total=0 del=0 roots=0
    dc_section installers
    INST_LIST=""
    for root in "$HOME/Downloads" "$HOME/Desktop"; do
        [[ -d "$root" ]] || continue
        roots=$((roots + 1))
        if ! dc_dir_listable "$root"; then
            say "  ${root#"$HOME"/} 读不到（TCC/权限），未计入（不是 0）"
            continue
        fi
        while IFS= read -r -d '' p; do
            [[ -n "$p" ]] || continue
            sz=$(du_kb "$p")
            if is_path_in_use "$p"; then
                keep=$((keep + 1))
                say "  保留 $(basename "$p")（$(human "$sz")，仍被进程打开）"
                continue
            fi
            n=$((n + 1))
            total=$((total + sz))
            del=$((del + sz))
            INST_LIST="${INST_LIST}${p}"$'\n'
            say "  可删 ${p#"$HOME"/}（$(human "$sz")，${INSTALLER_AGE_DAYS} 天未改动）"
        done < <(run_timeout "$DC_TIMEOUT_FIND" find "$root" -mindepth 1 -maxdepth 2 \
            -type f \
            \( -iname '*.dmg' -o -iname '*.pkg' -o -iname '*.iso' -o -iname '*.xip' -o -iname '*.zip' \) \
            -size +"${INSTALLER_MIN_MB}M" -mtime +"$INSTALLER_AGE_DAYS" -print0 2>/dev/null)
    done

    if [[ "$roots" -eq 0 ]]; then
        say "  未找到 ~/Downloads 与 ~/Desktop，跳过"
        return 0
    fi
    say "  命中 ${n} 个安装包 / 保留 ${keep} 个（在用）"
    [[ "$n" -eq 0 && "$keep" -eq 0 ]] && say "  没有 >${INSTALLER_MIN_MB}MB 且 ${INSTALLER_AGE_DAYS} 天未改动的安装包"
    STEP_TOTAL_KB="$total"
    STEP_DEL_KB="$del"
    STEP_PATH="$HOME/Downloads"
    STEP_SAMPLE=$(printf '%s' "$INST_LIST" | head -5)
    PLAN_CMD="整删 ${n} 个安装包（.dmg/.pkg/.iso/.xip/.zip，>${INSTALLER_MIN_MB}MB 且 ${INSTALLER_AGE_DAYS} 天未改动）"
    run installers "清理安装包残留（.dmg/.pkg/.iso/.xip/.zip）" clean_installers
}
