#!/usr/bin/env bash
# targets: dev 组（开发者工具缓存与版本堆叠）
#   编码：xcode node go python rust jvm homebrew cocoapods xcode-ios docker jetbrains agentversions
#
# 约定（与 lib/targets/system.sh 一致）：
#   target_<id>()  只读测量：算 total/del、打印行、设置 STEP_* 与 PLAN_CMD，最后调 run
#   clean_<id>()   执行：只经 lib/safety.sh 的漏斗原语，本文件不出现任何直接删除
#   跨函数共享状态一律用全局（run 在同一 shell 里稍后调用 clean_*）
#
# 本文件额外遵守的口径（避免「把未知当 0、把保护项算进可删量」）：
#   1) 保护清单命中（dc_protected_reason）的路径**不计入** deletable_kb，只列出提示；
#      仍由漏斗在删除时二次拦截，这里只是不让估算虚高。
#   2) 外部命令一律 run_timeout；读不到记「未知」（reports[] 里 kb=-1），不当 0。
#   3) Go 模块缓存 / pnpm 工具仓库这类只读目录：先 chmod -R u+w 再交漏斗删除
#      （chmod 不是删除；被保护清单命中的路径不做 chmod）。
[[ -n "${_DC_T_DEV_LOADED:-}" ]] && return 0
_DC_T_DEV_LOADED=1

# 内核只给了 du/find/brew/docker 四档，这里补两档本文件专用（同数量级，不新增魔数散落）
DC_DEV_SIMCTL_TIMEOUT=300   # xcrun simctl delete unavailable
DC_DEV_PNPM_TIMEOUT=300     # pnpm store prune
# 版本堆叠保留份数：规格 §8「保留最新 + 1 个旧版 / N=2 + 活跃软链目标」
DC_DEV_KEEP_VERSIONS=2

# 跨函数共享状态（全部预置，避免 set -u 下未定义）
DC_DEV_TOTAL=0
DC_DEV_DEL=0
DC_DEV_N=0
DC_DEV_UNKNOWN=0
DC_DEV_PLAN=""
DC_DEV_PROT=""
DC_DEV_TOP=""
DC_DEV_FIX_PERM=0
DC_DEV_V_ALL=""
DC_DEV_V_DEL=""
DC_DEV_V_KEEP=""
DC_DEV_SIMCTL=""
DC_DEV_BREW_CACHE=""
DC_DEV_XCODE_DIR=""
DC_JB_DEL=""
DC_JB_LOGDIRS=""
DC_JB_TOP=""
DC_JB_PROT=""
DC_AGV_DEL=""
DC_AGV_VERSIONS=""
DC_AGV_TOP=""
DC_AGV_PROT=""
DC_DOCKER_SIZE_KB=-1
DC_DOCKER_RECLAIM_KB=-1
DC_DOCKER_UNREACHABLE=0

# ---------------- 本文件共用小工具 ----------------

# dc_dev_kb_parse <"996.6MB (55%)">：人类格式 → KB；解析不出输出 -1（未知，不是 0）
# 全用 awk 的 ERE：macOS 的 sed 是 BSD 版，BRE 不支持 \? （用它会静默解析失败）
dc_dev_kb_parse() {
    awk -v s="${1:-}" 'BEGIN{
        if (match(s, /[0-9]+(\.[0-9]+)?/) == 0) { printf "%s", "-1"; exit }
        n = substr(s, RSTART, RLENGTH) + 0
        rest = substr(s, RSTART + RLENGTH)
        sub(/^[ \t]+/, "", rest)
        u = ""
        if (match(rest, /^[A-Za-z]+/) > 0) u = toupper(substr(rest, RSTART, RLENGTH))
        m = -1
        if (u == "B") m = 1 / 1024
        else if (u == "K" || u == "KB" || u == "KIB") m = 1
        else if (u == "M" || u == "MB" || u == "MIB") m = 1024
        else if (u == "G" || u == "GB" || u == "GIB") m = 1048576
        else if (u == "T" || u == "TB" || u == "TIB") m = 1073741824
        else if (u == "P" || u == "PB" || u == "PIB") m = 1099511627776
        if (m < 0) { printf "%s", "-1"; exit }
        printf "%d", n * m
    }'
}

# dc_dev_chmod_u_w <path>：只读缓存（go/pkg/mod、pnpm 工具仓库）先补写权限，
# 否则漏斗里的删除无法 unlink 子项。被保护清单命中的路径不动。
dc_dev_chmod_u_w() {
    local p="${1:-}"
    [[ -e "$p" ]] || return 0
    if dc_protected_reason "$p" >/dev/null 2>&1; then return 0; fi
    # BSD chmod 不认 --，路径由调用方保证是绝对路径
    run_timeout "$DC_TIMEOUT_DU" chmod -R u+w "$p" >/dev/null 2>&1 || true
    return 0
}

# dc_dev_measure_group <换行分隔目录列表>：填 DC_DEV_*（total/del/命中数/计划/保护/明细）
dc_dev_measure_group() {
    local list="${1:-}" d sz r
    DC_DEV_TOTAL=0; DC_DEV_DEL=0; DC_DEV_N=0; DC_DEV_UNKNOWN=0
    DC_DEV_PLAN=""; DC_DEV_PROT=""; DC_DEV_TOP=""
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        [[ -e "$d" ]] || continue
        sz=$(du_kb "$d")
        DC_DEV_TOTAL=$((DC_DEV_TOTAL + sz))
        DC_DEV_N=$((DC_DEV_N + 1))
        if r=$(dc_protected_reason "$d"); then
            DC_DEV_PROT="${DC_DEV_PROT}${d}"$'\n'
            DC_DEV_TOP="${DC_DEV_TOP}${sz}	${d#"$HOME"/}（保护清单：${r}，不计入可删）"$'\n'
        else
            DC_DEV_DEL=$((DC_DEV_DEL + sz))
            DC_DEV_PLAN="${DC_DEV_PLAN}${d}"$'\n'
            DC_DEV_TOP="${DC_DEV_TOP}${sz}	${d#"$HOME"/}"$'\n'
        fi
    done <<EOF
$list
EOF
    # 有目录但统计为 0：du 超时/权限不足，不能当 0 报
    if [[ "$DC_DEV_N" -gt 0 && "$DC_DEV_TOTAL" -eq 0 ]]; then DC_DEV_UNKNOWN=1; fi
}

# dc_dev_group_print：文本明细（最大几项 + 保护命中 + 未知提示）
dc_dev_group_print() {
    local kb nm p
    say "  命中 ${DC_DEV_N} 个目录，合计 $(human "$DC_DEV_TOTAL") / 本次可删 $(human "$DC_DEV_DEL")"
    if [[ -n "$DC_DEV_TOP" ]]; then
        say "  最大的几项:"
        printf '%s' "$DC_DEV_TOP" | sort -rn | head -5 | while IFS=$'\t' read -r kb nm; do
            [[ -n "${nm:-}" ]] || continue
            say "    - $(human "$kb")  ${nm}"
        done
    fi
    if [[ -n "$DC_DEV_PROT" ]]; then
        say "  ⚠️ 以下路径在 data/protect.tsv 保护内，已从可删量剔除（要删需先解保护）："
        printf '%s' "$DC_DEV_PROT" | while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            say "    - ${p#"$HOME"/}"
        done
    fi
    if [[ "$DC_DEV_UNKNOWN" == "1" ]]; then
        say "  ⚠️ 目录存在但统计为 0：du 超时或权限不足（未知，不当作 0）"
    fi
}

# dc_dev_scope <列表> <plan> [0|1 补写权限]：测量并填 STEP_*/PLAN_CMD；无命中返回 1
dc_dev_scope() {
    DC_DEV_FIX_PERM="${3:-0}"
    dc_dev_measure_group "${1:-}"
    if [[ "$DC_DEV_N" -eq 0 ]]; then
        say "  未找到本组目标目录，跳过"
        return 1
    fi
    dc_dev_group_print
    STEP_TOTAL_KB="$DC_DEV_TOTAL"
    STEP_DEL_KB="$DC_DEV_DEL"
    STEP_SAMPLE=$(printf '%s' "$DC_DEV_PLAN" | head -5)
    PLAN_CMD="${2:-}"
    [[ "$DC_DEV_UNKNOWN" == "1" ]] && STEP_SAMPLE=""
    return 0
}

# dc_dev_group_clean：按 DC_DEV_PLAN 逐条走漏斗；只有真实失败/超时算非 0
# （保护命中、在用跳过不算失败——与规格 §5 I5 一致）
dc_dev_group_clean() {
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        [[ -e "$p" ]] || continue
        [[ "${DC_DEV_FIX_PERM:-0}" == "1" ]] && dc_dev_chmod_u_w "$p"
        dc_delete_one "$p" >/dev/null 2>&1 || true
    done <<EOF
$DC_DEV_PLAN
EOF
    STEP_NOTE="$(dc_deleted_summary)"
    [[ "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

clean_dev_group() {
    dc_dev_group_clean
}

# dc_dev_version_dirs <父目录>：版本型子目录名，按修改时间从新到旧（一行一个）
dc_dev_version_dirs() {
    local parent="${1:-}"
    [[ -d "$parent" ]] || return 0
    run_timeout "$DC_TIMEOUT_QUICK" ls -1t -- "$parent" 2>/dev/null
}

# dc_dev_live_targets <maxdepth> <目录...>：这些目录里被软链指到的目标（规范化后的绝对路径）
# 用于「正在被软链指向的那份」必须保留
dc_dev_live_targets() {
    local depth="${1:-1}" root p t
    shift
    for root in "$@"; do
        [[ -d "$root" ]] || continue
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            t=$(readlink -- "$p" 2>/dev/null) || continue
            [[ -n "$t" ]] || continue
            case "$t" in
                /*) ;;
                *) t="$(dirname -- "$p")/$t" ;;
            esac
            resolve_path "$t"
            printf '\n'
        done <<EOF
$(run_timeout "$DC_TIMEOUT_QUICK" find "$root" -maxdepth "$depth" -type l 2>/dev/null)
EOF
    done
}

# dc_dev_version_split <versions 目录> <保留份数> <活跃目标换行列表>
# 填 DC_DEV_V_ALL / DC_DEV_V_DEL / DC_DEV_V_KEEP（换行分隔）
dc_dev_version_split() {
    local parent="${1:-}" keep_n="${2:-2}" live="${3:-}" name p p_real t idx=0 kept=0
    DC_DEV_V_ALL=""; DC_DEV_V_DEL=""; DC_DEV_V_KEEP=""
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        p="$parent/$name"
        [[ -d "$p" ]] || continue
        DC_DEV_V_ALL="${DC_DEV_V_ALL}${p}"$'\n'
        idx=$((idx + 1))
        if [[ "$idx" -le "$keep_n" ]]; then
            kept=1
        else
            kept=0
            p_real=$(resolve_path "$p")
            while IFS= read -r t; do
                [[ -n "$t" ]] || continue
                if dc_under "$t" "$p_real"; then kept=1; break; fi
            done <<EOF
$live
EOF
        fi
        if [[ "$kept" == "1" ]]; then
            DC_DEV_V_KEEP="${DC_DEV_V_KEEP}${p}"$'\n'
        else
            DC_DEV_V_DEL="${DC_DEV_V_DEL}${p}"$'\n'
        fi
    done <<EOF
$(dc_dev_version_dirs "$parent")
EOF
}

# dc_dev_docker_df：解析 docker system df，填 DC_DOCKER_SIZE_KB / DC_DOCKER_RECLAIM_KB
# 读不到两个都保持 -1（未知，不当 0）；返回 1 表示没解析出任何一行
dc_dev_docker_df() {
    local out="" rc=0 t sz rec k1 k2 total_sz=0 total_rec=0 seen=0 parsed=0
    DC_DOCKER_SIZE_KB=-1
    DC_DOCKER_RECLAIM_KB=-1
    out=$(run_timeout "$DC_TIMEOUT_DU" docker system df --format '{{.Type}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null) || out=""
    if [[ -z "$out" ]]; then
        # 老版本 docker 没有 --format：退回解析表格（RECLAIMABLE 列形如 "5.1GB (62%)"）
        out=$(run_timeout "$DC_TIMEOUT_DU" docker system df 2>/dev/null) || out=""
        [[ -n "$out" ]] || return 1
        out=$(printf '%s\n' "$out" | awk 'NR > 1 && NF >= 4 {
            rec = ""
            for (i = NF; i >= 2; i--) { if ($i ~ /^[0-9.]+[KMGTP]?B$/) { rec = $i; break } }
            if (rec != "") printf "%s|%s|%s\n", $1, $4, rec
        }')
        [[ -n "$out" ]] || return 1
    fi
    while IFS='|' read -r t sz rec; do
        [[ -n "${t:-}" ]] || continue
        seen=$((seen + 1))
        k1=$(dc_dev_kb_parse "${sz:-}")
        k2=$(dc_dev_kb_parse "${rec:-}")
        if [[ "$k1" -ge 0 ]]; then total_sz=$((total_sz + k1)); parsed=$((parsed + 1)); fi
        if [[ "$k2" -ge 0 ]]; then total_rec=$((total_rec + k2)); parsed=$((parsed + 1)); fi
    done <<EOF
$out
EOF
    [[ "$seen" -gt 0 && "$parsed" -gt 0 ]] || return 1
    DC_DOCKER_SIZE_KB="$total_sz"
    DC_DOCKER_RECLAIM_KB="$total_rec"
    return 0
}

# ---------------- xcode ----------------
# DerivedData 整删：下次构建全量重编（无阈值，构建产物本身就是缓存）
target_xcode() {
    dc_section xcode
    DC_DEV_XCODE_DIR="$HOME/Library/Developer/Xcode/DerivedData"
    if [[ ! -d "$DC_DEV_XCODE_DIR" ]]; then
        say "  未找到 Xcode DerivedData（${DC_DEV_XCODE_DIR}），跳过"
        return 0
    fi
    dc_dev_scope "$DC_DEV_XCODE_DIR" \
        "整删 ${DC_DEV_XCODE_DIR}（下次构建全量重编）" 0 || return 0
    if [[ "$DC_DEV_DEL" -gt 0 ]]; then
        say "  代价：下次构建要全量重编，Xcode 会重建该目录"
    fi
    run xcode "清理 Xcode DerivedData（整删，下次构建全量重编）" clean_dev_group
}

# ---------------- node ----------------
# npm/yarn/bun/pnpm 缓存 + 无头运行时（playwright/cypress/electron/puppeteer 等）
# 只读目录（pnpm 工具仓库）先补写权限
target_node() {
    local list kb=0
    dc_section node
    list="$HOME/.npm/_npx
$HOME/.npm/_cacache
$HOME/.npm/_logs
$HOME/.cache/yarn
$HOME/.cache/bun
$HOME/.bun/install/cache
$HOME/.cache/node
$HOME/.cache/puppeteer
$HOME/.cache/codex-runtimes
$HOME/.cache/opencode
$HOME/Library/Caches/Yarn
$HOME/Library/Caches/node-gyp
$HOME/Library/Caches/electron
$HOME/Library/Caches/ms-playwright
$HOME/Library/Caches/Cypress
$HOME/Library/pnpm/package-manager-store"
    dc_dev_scope "$list" \
        "整删 npm/yarn/bun/pnpm 缓存与无头运行时缓存；再跑 pnpm store prune（只回收未引用包）" 1 || return 0
    # pnpm 的另一套 store（包内容）：本编码只 prune 不整删，单独报告体积
    if [[ -d "$HOME/Library/pnpm/store" ]]; then
        kb=$(du_kb "$HOME/Library/pnpm/store")
        report_line node "pnpm store（包内容，只 prune 不整删）" "$kb" \
            "整删会丢已下载包；本编码用 pnpm store prune 回收未引用部分"
    fi
    run node "清理 Node 生态缓存（npm/yarn/bun/pnpm + 无头运行时）" clean_node
}

clean_node() {
    local ok=0 rc=0 extra=""
    dc_dev_group_clean || ok=1
    # pnpm store：只回收未被引用的包，不删实体目录
    # 有 pnpm 就直接用；只有 corepack + 已存在 store 时才走 shim（避免顺手下载 pnpm）
    if command -v pnpm >/dev/null 2>&1; then
        run_timeout "$DC_DEV_PNPM_TIMEOUT" pnpm store prune >&2 || rc=$?
    elif [[ -d "$HOME/Library/pnpm/store" ]] && command -v corepack >/dev/null 2>&1; then
        run_timeout "$DC_DEV_PNPM_TIMEOUT" env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
            corepack pnpm store prune >&2 || rc=$?
    else
        extra="；未发现 pnpm，跳过 store prune"
    fi
    if [[ "$rc" -eq 124 ]]; then
        extra="${extra}；pnpm store prune 超时（${DC_DEV_PNPM_TIMEOUT}s）"
    elif [[ "$rc" -ne 0 ]]; then
        extra="${extra}；pnpm store prune 未成功（rc=${rc}）"
    fi
    [[ -n "$extra" ]] && STEP_NOTE="${STEP_NOTE}${extra}"
    [[ "$ok" -eq 0 ]]
}

# ---------------- go ----------------
# 全局模块缓存（~/go/pkg/mod，只读权限）+ 构建/工具缓存
target_go() {
    local list
    dc_section go
    list="$HOME/go/pkg/mod
$HOME/Library/Caches/go-build
$HOME/Library/Caches/goimports
$HOME/Library/Caches/gopls
$HOME/Library/Caches/golangci-lint"
    dc_dev_scope "$list" \
        "整删 go 模块缓存 / go-build / goimports / gopls / golangci-lint（删后重新下载与编译）" 1 || return 0
    say "  说明：~/go/pkg/mod 是只读目录，删除前先 chmod -R u+w"
    run go "清理 Go 缓存（模块 / 构建 / 工具）" clean_dev_group
}

# ---------------- python ----------------
target_python() {
    local list
    dc_section python
    list="$HOME/.cache/uv
$HOME/Library/Caches/pip"
    dc_dev_scope "$list" "整删 uv / pip 缓存（删后重新下载）" 0 || return 0
    run python "清理 Python 缓存（uv / pip）" clean_dev_group
}

# ---------------- rust ----------------
target_rust() {
    local list
    dc_section rust
    list="$HOME/.cargo/registry/cache"
    dc_dev_scope "$list" "整删 cargo registry 的 .crate 缓存（删后重新下载 crate）" 0 || return 0
    run rust "清理 Rust 缓存（cargo registry）" clean_dev_group
}

# ---------------- jvm ----------------
target_jvm() {
    local list
    dc_section jvm
    list="$HOME/.m2/repository
$HOME/.gradle/caches"
    dc_dev_scope "$list" "整删 Maven ~/.m2/repository 与 Gradle ~/.gradle/caches（删后重新下载依赖）" 0 || return 0
    run jvm "清理 JVM 缓存（Maven .m2 / Gradle caches）" clean_dev_group
}

# ---------------- homebrew ----------------
target_homebrew() {
    local cache="" kb=0
    dc_section homebrew
    DC_DEV_BREW_CACHE=""
    if ! command -v brew >/dev/null 2>&1; then
        say "  未安装 Homebrew，跳过"
        return 0
    fi
    cache=$(run_timeout "$DC_TIMEOUT_QUERY" env HOMEBREW_NO_AUTO_UPDATE=1 brew --cache 2>/dev/null) || cache=""
    if [[ -z "$cache" || ! -d "$cache" ]]; then
        say "  Homebrew 缓存目录读不到（brew --cache 失败：未知，不当作 0）"
        report_line homebrew "Homebrew 缓存目录" -1 "brew --cache 读不到"
        STEP_TOTAL_KB=0
        STEP_DEL_KB=0
        PLAN_CMD="brew cleanup --prune=all && brew autoremove"
        run homebrew "清理 Homebrew 缓存与旧版本" clean_homebrew
        return 0
    fi
    DC_DEV_BREW_CACHE="$cache"
    kb=$(du_kb "$cache")
    say "  Homebrew 缓存: $(human "$kb")"
    say "  说明：cleanup --prune=all 还会删 Cellar 里的旧版本，那部分未计入上面的缓存体积"
    STEP_TOTAL_KB="$kb"
    STEP_DEL_KB="$kb"
    STEP_PATH="$cache"
    STEP_SAMPLE="$cache"
    PLAN_CMD="brew cleanup --prune=all && brew autoremove"
    run homebrew "清理 Homebrew 缓存与旧版本" clean_homebrew
}

clean_homebrew() {
    local rc1=0 rc2=0
    say "  正在运行 brew cleanup --prune=all（超时 ${DC_TIMEOUT_BREW}s）..."
    run_timeout "$DC_TIMEOUT_BREW" env HOMEBREW_NO_AUTO_UPDATE=1 brew cleanup --prune=all >&2 || rc1=$?
    say "  正在运行 brew autoremove（超时 ${DC_TIMEOUT_BREW}s）..."
    run_timeout "$DC_TIMEOUT_BREW" env HOMEBREW_NO_AUTO_UPDATE=1 brew autoremove >&2 || rc2=$?
    if [[ "$rc1" -eq 124 || "$rc2" -eq 124 ]]; then
        STEP_NOTE="brew 超时（cleanup rc=${rc1} / autoremove rc=${rc2}），未确认完成"
        return 1
    fi
    if [[ "$rc1" -ne 0 || "$rc2" -ne 0 ]]; then
        STEP_NOTE="brew 返回非 0（cleanup ${rc1} / autoremove ${rc2}）"
        return 1
    fi
    STEP_NOTE="brew cleanup --prune=all + autoremove 完成（旧版本不可回滚）"
    return 0
}

# ---------------- cocoapods ----------------
target_cocoapods() {
    dc_section cocoapods
    dc_dev_scope "$HOME/Library/Caches/CocoaPods" \
        "整删 CocoaPods 缓存（下次 pod install 重新下载）" 0 || return 0
    run cocoapods "清理 CocoaPods 缓存" clean_dev_group
}

# ---------------- xcode-ios ----------------
# ipsw 固件 / iOS DeviceSupport 符号文件 / CoreSimulator Caches / 不可用模拟器
target_xcode_ios() {
    local list out="" sims=-1 total=0 del=0
    dc_section xcode-ios
    list="$HOME/Library/iTunes/iPhone Software Updates
$HOME/Library/Developer/Xcode/iOS DeviceSupport
$HOME/Library/Developer/CoreSimulator/Caches"

    # simctl 可用性：xcrun 在但 simctl 缺（只装了 CLT）时不能当失败
    DC_DEV_SIMCTL=""
    if command -v xcrun >/dev/null 2>&1; then
        if run_timeout "$DC_TIMEOUT_QUERY" xcrun --find simctl >/dev/null 2>&1; then
            DC_DEV_SIMCTL="yes"
        fi
    fi
    if [[ -n "$DC_DEV_SIMCTL" ]]; then
        out=$(run_timeout "$DC_DEV_SIMCTL_TIMEOUT" xcrun simctl list devices unavailable 2>/dev/null) || out=""
        if [[ -n "$out" ]]; then
            sims=$(printf '%s\n' "$out" | grep -cE '\([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\)')
            sims="${sims:-0}"
        fi
    else
        say "  xcrun simctl 不可用（未装 Xcode 或未选中开发者目录）：不可用模拟器记未知"
    fi

    dc_dev_measure_group "$list"
    if [[ "$DC_DEV_N" -gt 0 ]]; then dc_dev_group_print; fi
    total="$DC_DEV_TOTAL"
    del="$DC_DEV_DEL"

    if [[ "$DC_DEV_N" -eq 0 && -z "$DC_DEV_SIMCTL" ]]; then
        say "  未找到 iOS 大件，且 xcrun/simctl 不可用，跳过"
        return 0
    fi
    if [[ "$sims" -ge 0 ]]; then
        say "  不可用的旧模拟器: ${sims} 台（simctl 只给台数不给体积，未计入可删量）"
        report_line xcode-ios "不可用模拟器（只报告台数）" -1 "台数 ${sims}，simctl 不提供体积"
    fi
    STEP_TOTAL_KB="$total"
    STEP_DEL_KB="$del"
    STEP_SAMPLE=$(printf '%s' "$DC_DEV_PLAN" | head -5)
    if [[ -n "$DC_DEV_SIMCTL" ]]; then
        PLAN_CMD="整删 ipsw 固件 / iOS DeviceSupport / CoreSimulator Caches；再跑 xcrun simctl delete unavailable"
    else
        PLAN_CMD="整删 ipsw 固件 / iOS DeviceSupport / CoreSimulator Caches（simctl 不可用，跳过模拟器）"
    fi
    DC_DEV_FIX_PERM=0
    run xcode-ios "清理 iOS 大件（ipsw / DeviceSupport / CoreSimulator / 不可用模拟器）" clean_xcode_ios
}

clean_xcode_ios() {
    local ok=0 rc=0
    dc_dev_group_clean || ok=1
    STEP_NOTE="$(dc_deleted_summary)"
    if [[ -n "$DC_DEV_SIMCTL" ]]; then
        say "  正在运行 xcrun simctl delete unavailable（超时 ${DC_DEV_SIMCTL_TIMEOUT}s）..."
        run_timeout "$DC_DEV_SIMCTL_TIMEOUT" xcrun simctl delete unavailable >&2 || rc=$?
        if [[ "$rc" -eq 124 ]]; then
            STEP_NOTE="${STEP_NOTE}；simctl 超时（${DC_DEV_SIMCTL_TIMEOUT}s）"
        elif [[ "$rc" -ne 0 ]]; then
            STEP_NOTE="${STEP_NOTE}；simctl 未完成（rc=${rc}）"
        else
            STEP_NOTE="${STEP_NOTE}；simctl delete unavailable 已执行"
        fi
    fi
    [[ "$ok" -eq 0 ]]
}

# 内核分派用 target_<编码> 作函数名，而编码表里这一项是 xcode-ios（带连字符）。
# bash 允许用 `function name-with-dash` 形式定义这类函数名，这里补一个转发；
# 若内核改成把 - 映射成 _，target_xcode_ios 仍然直接可用。
function target_xcode-ios {
    target_xcode_ios "$@"
}

# ---------------- docker ----------------
# 只清「未使用」资源：镜像 / 停止的容器 / 构建缓存 / 未使用网络；**不删卷**（可能有用户数据）
# 关键期望管理：prune 回收的是虚拟磁盘内部空间，Docker.raw/OrbStack 稀疏镜像不会因此变小，
# 宿主 df 很可能不动。
target_docker() {
    dc_section docker
    DC_DOCKER_UNREACHABLE=0
    DC_DOCKER_SIZE_KB=-1
    DC_DOCKER_RECLAIM_KB=-1
    if ! command -v docker >/dev/null 2>&1; then
        say "  未安装 Docker CLI，跳过"
        return 0
    fi
    say "  说明：docker system prune 回收的是虚拟磁盘内部空间；Docker.raw 不会缩小，宿主 df 可能不变。"
    if ! dc_dev_docker_df; then
        DC_DOCKER_UNREACHABLE=1
        say "  docker system df 读不到（守护进程未运行？）：可回收量未知，不当作 0"
        report_line docker "Docker 可回收空间" -1 "docker system df 读不到（守护进程未运行或无权限）"
        STEP_TOTAL_KB=0
        STEP_DEL_KB=0
        PLAN_CMD="docker system prune -a --force（不删卷；不会缩小 Docker.raw，宿主 df 可能不变）"
        run docker "清理 Docker 无用资源（镜像/容器/构建缓存/网络）" clean_docker
        return 0
    fi
    say "  Docker 占用（虚拟磁盘内部）: $(human "$DC_DOCKER_SIZE_KB") / prune 可回收（估算）: $(human "$DC_DOCKER_RECLAIM_KB")"
    say "  不含卷（volumes 可能装用户数据，本编码刻意不删）"
    if [[ -f "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" ]]; then
        report_path docker "Docker 虚拟磁盘 Docker.raw" \
            "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" \
            "prune 不会缩小它（宿主 df 可能不变）" "读不到"
    fi
    STEP_TOTAL_KB="$DC_DOCKER_SIZE_KB"
    STEP_DEL_KB="$DC_DOCKER_RECLAIM_KB"
    STEP_PATH=""
    STEP_SAMPLE=""
    PLAN_CMD="docker system prune -a --force（不删卷；不会缩小 Docker.raw，宿主 df 可能不变）"
    run docker "清理 Docker 无用资源（镜像/容器/构建缓存/网络）" clean_docker
}

clean_docker() {
    local rc=0
    if [[ "${DC_DOCKER_UNREACHABLE:-0}" == "1" ]]; then
        STEP_NOTE="Docker 守护进程不可达，未执行（可回收量未知）；不会缩小 Docker.raw"
        return 1
    fi
    say "  正在运行 docker system prune -a --force（超时 ${DC_TIMEOUT_DOCKER}s）..."
    run_timeout "$DC_TIMEOUT_DOCKER" docker system prune -a --force >&2 || rc=$?
    if [[ "$rc" -eq 124 ]]; then
        STEP_NOTE="docker system prune 超时（${DC_TIMEOUT_DOCKER}s），未确认完成"
        return 1
    fi
    if [[ "$rc" -ne 0 ]]; then
        STEP_NOTE="docker system prune 失败（rc=${rc}，守护进程不可达或无权限）"
        return 1
    fi
    STEP_NOTE="已执行 docker system prune -a --force（不删卷）；不会缩小 Docker.raw，宿主 df 可能不变"
    return 0
}

# ---------------- jetbrains ----------------
# Toolbox 应用旧版本：每个产品保留最新 DC_DEV_KEEP_VERSIONS 份（+ 软链指向的那份），其余整删
# IDE logs：只删 ${LOG_AGE_DAYS} 天前的旧文件（跟随 --log-age-days，默认 7）
# 注意：Toolbox 应用目录在 ~/Library/Application Support/JetBrains 下，protect.tsv 默认 soft 保护，
# 所以「测量会列出、删除默认被拦」——这不是绕过，是保护清单优先。
target_jetbrains() {
    local apps="$HOME/Library/Application Support/JetBrains/Toolbox/apps"
    local logs="$HOME/Library/Logs/JetBrains"
    local prod vd p sz r live="" total=0 delkb=0 n_ver=0 n_log=0 log_days
    log_days="${LOG_AGE_DAYS:-7}"
    dc_section jetbrains
    DC_JB_DEL=""
    DC_JB_LOGDIRS=""
    DC_JB_TOP=""
    DC_JB_PROT=""

    # 活跃软链：Toolbox 的 current 链接 + 用户 bin 目录里的启动器
    live=$(dc_dev_live_targets 1 "$HOME/.local/bin" "$HOME/bin")
    if [[ -d "$apps" ]]; then
        live="${live}"$'\n'"$(dc_dev_live_targets 1 "$apps")"
        for prod in "$apps"/*; do
            [[ -d "$prod" ]] || continue
            live="${live}"$'\n'"$(dc_dev_live_targets 1 "$prod")"
        done
    fi

    if [[ -d "$apps" ]]; then
        for prod in "$apps"/*; do
            [[ -d "$prod" ]] || continue
            for vd in "$prod/versions" "$prod/ch-0"; do
                [[ -d "$vd" ]] || continue
                dc_dev_version_split "$vd" "$DC_DEV_KEEP_VERSIONS" "$live"
                while IFS= read -r p; do
                    [[ -n "$p" ]] || continue
                    n_ver=$((n_ver + 1))
                    sz=$(du_kb "$p")
                    total=$((total + sz))
                done <<EOF
$DC_DEV_V_ALL
EOF
                while IFS= read -r p; do
                    [[ -n "$p" ]] || continue
                    sz=$(du_kb "$p")
                    if r=$(dc_protected_reason "$p"); then
                        DC_JB_PROT="${DC_JB_PROT}${p}|${r}"$'\n'
                        DC_JB_TOP="${DC_JB_TOP}${sz}	${p#"$HOME"/}（保护清单：${r}，不计入可删）"$'\n'
                    else
                        DC_JB_DEL="${DC_JB_DEL}${p}"$'\n'
                        delkb=$((delkb + sz))
                        DC_JB_TOP="${DC_JB_TOP}${sz}	${p#"$HOME"/}（旧版本，保留最新 ${DC_DEV_KEEP_VERSIONS} 份）"$'\n'
                    fi
                done <<EOF
$DC_DEV_V_DEL
EOF
            done
        done
    fi

    if [[ -d "$logs" ]]; then
        for vd in "$logs"/*; do
            [[ -e "$vd" ]] || continue
            n_log=$((n_log + 1))
            sz=$(du_kb "$vd")
            r=$(subset_kb "$vd" "$log_days")
            total=$((total + sz))
            delkb=$((delkb + r))
            DC_JB_LOGDIRS="${DC_JB_LOGDIRS}${vd}"$'\n'
            DC_JB_TOP="${DC_JB_TOP}${r}	${vd#"$HOME"/}（${log_days} 天前可删 $(human "$r")）"$'\n'
        done
    fi

    if [[ "$n_ver" -eq 0 && "$n_log" -eq 0 ]]; then
        say "  未找到 JetBrains Toolbox 应用版本或 IDE 日志，跳过"
        return 0
    fi

    say "  Toolbox 版本目录: ${n_ver} 个 / IDE 日志目录: ${n_log} 个"
    say "  合计 $(human "$total") / 本次可删 $(human "$delkb")"
    say "  最大的几项:"
    printf '%s' "$DC_JB_TOP" | sort -rn | head -5 | while IFS=$'\t' read -r sz p; do
        [[ -n "${p:-}" ]] || continue
        say "    - $(human "$sz")  ${p}"
    done
    if [[ -n "$DC_JB_PROT" ]]; then
        say "  ⚠️ Toolbox 旧版本在 data/protect.tsv 的 soft 保护内，默认不删（已从可删量剔除）"
        say "     要删需在 ~/.config/disk-cleanup/protect.txt 里用 !pattern 解除对应保护"
    fi

    STEP_TOTAL_KB="$total"
    STEP_DEL_KB="$delkb"
    STEP_SAMPLE=$(printf '%s' "$DC_JB_DEL" | head -5)
    PLAN_CMD="Toolbox 每个产品保留最新 ${DC_DEV_KEEP_VERSIONS} 份旧版本后整删其余；IDE logs 只删 ${log_days} 天前的文件"
    run jetbrains "清理 JetBrains Toolbox 旧版本与 IDE 旧日志" clean_jetbrains
}

clean_jetbrains() {
    local p d
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        [[ -e "$p" ]] || continue
        dc_delete_one "$p" >/dev/null 2>&1 || true
    done <<EOF
$DC_JB_DEL
EOF
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        [[ -e "$d" ]] || continue
        dc_delete_aged "$d" "${LOG_AGE_DAYS:-7}" >/dev/null 2>&1 || true
    done <<EOF
$DC_JB_LOGDIRS
EOF
    STEP_NOTE="$(dc_deleted_summary)"
    [[ "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

# ---------------- agentversions ----------------
# AI agent 的旧版本堆叠：Claude Code / Cursor Agent / Copilot 等的 versions/ 目录
# 保留最新 DC_DEV_KEEP_VERSIONS 份 + 正在被软链指向的那份，其余整删
# 这类目录常见于 ~/.claude、~/.cursor-agent、~/.local/share/<agent>、~/Library/Caches/<agent>
dc_dev_agent_version_dirs() {
    local base d all=""
    # 只扫这些根，且只认「路径里带 agent 名字」的 versions 目录：
    # 普通工具也有 versions/ 堆叠（fnm、pnpm 等），名字过滤是范围约束，不是黑名单。
    for base in "$HOME/.claude" "$HOME/.claude-code" "$HOME/.cursor-agent" \
                "$HOME/.cursor" "$HOME/.copilot" "$HOME/.codex" \
                "$HOME/.local/share" "$HOME/.cache" \
                "$HOME/Library/Caches" "$HOME/Library/Application Support"
    do
        [[ -d "$base" ]] || continue
        while IFS= read -r d; do
            [[ -n "$d" ]] || continue
            case "$(lower "$d")" in
                *claude*|*cursor*|*copilot*|*codex*|*anthropic*|*openai*) all="${all}${d}"$'\n' ;;
            esac
        done <<EOF
$(run_timeout "$DC_TIMEOUT_FIND" find "$base" -maxdepth 3 -type d -name versions 2>/dev/null)
EOF
    done
    printf '%s' "$all" | grep -v '^$' | sort -u
}

target_agentversions() {
    local vdirs vd p sz r live="" total=0 delkb=0 n_ver=0 n_del=0
    dc_section agentversions
    DC_AGV_DEL=""
    DC_AGV_VERSIONS=""
    DC_AGV_TOP=""
    DC_AGV_PROT=""

    vdirs=$(dc_dev_agent_version_dirs)
    if [[ -z "$vdirs" ]]; then
        say "  未发现 AI agent 的版本堆叠目录（~/.claude、~/.cursor-agent、~/Library/Caches 等），跳过"
        return 0
    fi

    # 活跃软链：bin 目录里的启动器 + versions 目录自身与它的父目录里的 current 链接
    live=$(dc_dev_live_targets 1 "$HOME/.local/bin" "$HOME/bin" \
        "$HOME/.claude/bin" "$HOME/.cursor-agent/bin" "$HOME/.copilot/bin")
    while IFS= read -r vd; do
        [[ -n "$vd" ]] || continue
        live="${live}"$'\n'"$(dc_dev_live_targets 1 "$vd" "$(dirname -- "$vd")")"
    done <<EOF
$vdirs
EOF

    while IFS= read -r vd; do
        [[ -n "$vd" ]] || continue
        dc_dev_version_split "$vd" "$DC_DEV_KEEP_VERSIONS" "$live"
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            DC_AGV_VERSIONS="${DC_AGV_VERSIONS}${p}"$'\n'
            n_ver=$((n_ver + 1))
            sz=$(du_kb "$p")
            total=$((total + sz))
        done <<EOF
$DC_DEV_V_ALL
EOF
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            sz=$(du_kb "$p")
            if r=$(dc_protected_reason "$p"); then
                DC_AGV_PROT="${DC_AGV_PROT}${p}|${r}"$'\n'
                DC_AGV_TOP="${DC_AGV_TOP}${sz}	${p#"$HOME"/}（保护清单：${r}，不计入可删）"$'\n'
            else
                DC_AGV_DEL="${DC_AGV_DEL}${p}"$'\n'
                n_del=$((n_del + 1))
                delkb=$((delkb + sz))
                DC_AGV_TOP="${DC_AGV_TOP}${sz}	${p#"$HOME"/}（旧版本）"$'\n'
            fi
        done <<EOF
$DC_DEV_V_DEL
EOF
    done <<EOF
$vdirs
EOF

    say "  版本堆叠目录: $(printf '%s\n' "$vdirs" | grep -c . ) 个 / 版本目录: ${n_ver} 个"
    say "  合计 $(human "$total") / 本次可删 $(human "$delkb")（待删 ${n_del} 个旧版本）"
    if [[ -n "$DC_AGV_TOP" ]]; then
        say "  最大的几项:"
        printf '%s' "$DC_AGV_TOP" | sort -rn | head -5 | while IFS=$'\t' read -r sz p; do
            [[ -n "${p:-}" ]] || continue
            say "    - $(human "$sz")  ${p}"
        done
    fi
    if [[ -n "$DC_AGV_PROT" ]]; then
        say "  ⚠️ 部分版本目录命中保护清单，已从可删量剔除"
    fi
    if [[ "$n_ver" -le "$DC_DEV_KEEP_VERSIONS" ]]; then
        say "  版本数未超过保留份数，无需清理"
        return 0
    fi
    say "  保留规则：每个 versions/ 保留最近修改的 ${DC_DEV_KEEP_VERSIONS} 份 + 正在被软链指向的那份"

    STEP_TOTAL_KB="$total"
    STEP_DEL_KB="$delkb"
    STEP_SAMPLE=$(printf '%s' "$DC_AGV_DEL" | head -5)
    PLAN_CMD="每个 versions/ 保留最新 ${DC_DEV_KEEP_VERSIONS} 份与软链指向的那份，其余旧版本整删（回滚能力受限）"
    run agentversions "清理 AI agent 旧版本堆叠（Claude Code / Cursor Agent / Copilot）" clean_agentversions
}

clean_agentversions() {
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        [[ -e "$p" ]] || continue
        dc_delete_one "$p" >/dev/null 2>&1 || true
    done <<EOF
$DC_AGV_DEL
EOF
    STEP_NOTE="$(dc_deleted_summary)"
    [[ "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}
