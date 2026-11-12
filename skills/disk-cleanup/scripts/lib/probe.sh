#!/usr/bin/env bash
# 探测命令族：把「文件/App 现在是否真的在用」变成可判定的事实。
# 原则：探测不到 → 记为未知并被调用方按保守方向处理；绝不把未知当空闲。
[[ -n "${_DC_PROBE_LOADED:-}" ]] && return 0
_DC_PROBE_LOADED=1

DC_LSOF_MODE=""

# probe_lsof_mode：非 root 的 lsof 在 macOS 上会静默漏掉 root 进程（退出码 1、无诊断），
# 所以先探一次能力，再决定用哪种调用方式。
probe_lsof_mode() {
    local rc=0 out
    if [[ -n "$DC_LSOF_MODE" ]]; then printf '%s' "$DC_LSOF_MODE"; return; fi
    if ! command -v lsof >/dev/null 2>&1; then
        DC_LSOF_MODE="none"
        printf '%s' "$DC_LSOF_MODE"
        return
    fi
    out=$(run_timeout "$DC_TIMEOUT_QUICK" lsof -F pu -p 1 2>/dev/null) || rc=$?
    if [[ "$rc" -eq 0 && -n "$out" ]]; then
        DC_LSOF_MODE="direct"
    else
        out=$(run_timeout "$DC_TIMEOUT_QUICK" sudo -n lsof -F pu -p 1 2>/dev/null) || rc=$?
        if [[ "$rc" -eq 0 && -n "$out" ]]; then
            DC_LSOF_MODE="sudo"
        else
            DC_LSOF_MODE="none"
        fi
    fi
    printf '%s' "$DC_LSOF_MODE"
}

# is_path_in_use <path>：0 = 正在被打开
# 探测超时 → 当作在用（保守）；lsof 不可用 → 未知，不当在用但置 DC_PROBE_UNKNOWN。
is_path_in_use() {
    local p="${1:-}" mode rc=0 out
    [[ -e "$p" ]] || return 1
    mode=$(probe_lsof_mode)
    if [[ "$mode" == "none" ]]; then
        DC_PROBE_UNKNOWN=1
        return 1
    fi
    if [[ "$mode" == "sudo" ]]; then
        out=$(run_timeout "$DC_TIMEOUT_QUICK" sudo -n lsof -nP -F pn -- "$p" 2>/dev/null) || rc=$?
    else
        out=$(run_timeout "$DC_TIMEOUT_QUICK" lsof -nP -F pn -- "$p" 2>/dev/null) || rc=$?
    fi
    [[ "$rc" -eq 124 ]] && return 0
    [[ -n "$out" ]] && return 0
    return 1
}

# app_bundle_ids_running：运行中 App 的 bundle id（换行分隔）
# osascript 常被 TCC 拒绝，必须用 lsappinfo 兜底。
app_bundle_ids_running() {
    local out=""
    out=$(run_timeout "$DC_TIMEOUT_QUERY" osascript -e \
        'tell application "System Events" to get bundle identifier of every application process' 2>/dev/null) || out=""
    if [[ -n "$out" ]]; then
        printf '%s' "$out" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$'
        return 0
    fi
    if command -v lsappinfo >/dev/null 2>&1; then
        out=$(run_timeout "$DC_TIMEOUT_QUICK" lsappinfo list 2>/dev/null) || out=""
        [[ -z "$out" ]] && return 1
        printf '%s\n' "$out" | sed -n 's/.*bundleID="\([^"]*\)".*/\1/p' | grep -v '^$'
        return 0
    fi
    return 1
}

# app_is_installed <bundle-id>：0 = 仍装着。
# mdfind 非 0 退出码必须当「装着」（Mole #1584 的教训：把查询失败缓存成没装 → 误删）。
app_is_installed() {
    local id="${1:-}" out rc=0
    [[ -n "$id" ]] || return 0
    if command -v mdfind >/dev/null 2>&1; then
        out=$(run_timeout "$DC_TIMEOUT_QUERY" mdfind "kMDItemCFBundleIdentifier == '$id'" 2>/dev/null) || rc=$?
        [[ "$rc" -ne 0 ]] && return 0
        [[ -n "$out" ]] && return 0
    fi
    # 没有 Spotlight 结果时再按标准位置兜一层
    local d
    for d in /Applications "$HOME/Applications" /Applications/Setapp "$HOME/Applications/Setapp"; do
        [[ -d "$d" ]] || continue
        if find "$d" -maxdepth 3 -name '*.app' -type d -print 2>/dev/null | while IFS= read -r a; do
            plutil -extract CFBundleIdentifier raw -o - "$a/Contents/Info.plist" 2>/dev/null
        done | grep -qx "$id"; then
            return 0
        fi
    done
    return 1
}

# pkg_apps：pkgutil receipts 里登记的 .app（装在 /opt、/usr/local 等非标准位置）
DC_PKG_APPS=""
DC_PKG_APPS_DONE=0

pkg_apps() {
    local pkgs p files out=""
    if [[ "$DC_PKG_APPS_DONE" == "1" ]]; then
        printf '%s\n' "$DC_PKG_APPS"
        return 0
    fi
    DC_PKG_APPS_DONE=1
    command -v pkgutil >/dev/null 2>&1 || return 0
    pkgs=$(run_timeout "$DC_TIMEOUT_QUERY" pkgutil --pkgs 2>/dev/null) || pkgs=""
    [[ -n "$pkgs" ]] || return 0
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        files=$(run_timeout "$DC_TIMEOUT_QUERY" pkgutil --files "$p" 2>/dev/null) || continue
        out="${out}$(printf '%s\n' "$files" | grep -E '\.app/Contents/Info\.plist$' | sed -e 's#/Contents/Info.plist$##' | sed -e 's#^/*#/#' )
"
    done <<EOF
$pkgs
EOF
    DC_PKG_APPS=$(printf '%s' "$out" | grep -v '^$')
    printf '%s\n' "$DC_PKG_APPS"
}

# tree_active <dir> <days>：树内是否有 days 天内改动过的文件（0 = 活跃）
# 只看目录自身 mtime 会漏判：构建产物的 mtime 停在上次生成时间。
tree_active() {
    local dir="${1:-}" days="${2:-30}" mins out rc=0
    [[ -d "$dir" ]] || return 1
    mins=$((days * 1440))
    out=$(run_timeout "$DC_TIMEOUT_FIND" find "$dir" -type f -mmin -"$mins" -print -quit 2>/dev/null) || rc=$?
    [[ "$rc" -eq 124 ]] && return 0   # 超时按活跃处理（保守）
    [[ -n "$out" ]]
}

# write_probe <dir>：真实写权限。输出 writable|readonly|denied|missing
write_probe() {
    local dir="${1:-}" tmp err=""
    [[ -d "$dir" ]] || { printf 'missing'; return; }
    err=$(mktemp -d "$dir/.dc-write-probe.XXXXXX" 2>&1) || {
        case "$err" in
            *"Read-only file system"*) printf 'readonly' ;;
            *"Operation not permitted"*|*"Permission denied"*) printf 'denied' ;;
            *) printf 'denied' ;;
        esac
        return
    }
    rmdir -- "$err" 2>/dev/null || true
    printf 'writable'
}

# embedded_bundle_ids <app 路径>：App 内嵌次级 bundle id（xpc/appex/LoginItems/PlugIns）
embedded_bundle_ids() {
    local app="${1:-}" plist out
    [[ -d "$app/Contents" ]] || return 1
    while IFS= read -r plist; do
        out=$(plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null) || continue
        [[ -n "$out" ]] && printf '%s\n' "$out"
    done < <(find "$app/Contents" -maxdepth 12 -name Info.plist -path '*/Contents/Info.plist' 2>/dev/null)
}

# app_version_count <dir>：目录下的版本型子目录数量（浏览器旧版本判定用）
app_version_dirs() {
    local dir="${1:-}"
    [[ -d "$dir" ]] || return 0
    find "$dir" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | sort -V
}

# dc_is_network_path <path>：外接/网络卷不参与自动删除
dc_is_network_path() {
    case "${1:-}" in
        /Volumes/*) return 0 ;;
    esac
    return 1
}
