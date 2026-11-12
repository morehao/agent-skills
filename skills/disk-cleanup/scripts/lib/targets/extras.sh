#!/usr/bin/env bash
# targets: targets_extras —— 「只报告」段（v1 mac_cleanup.sh 第 16 段整体迁移 + 第三方快照）
# 语义（与 v1 一致）：只报告、不代删、不改变退出码；读不到如实写「读不到」（kb=-1），绝不当 0。
# 入口在 lib/targets/*.sh 之后由 mac_cleanup.sh 统一调用，这里不参与 run()/勾选。
[[ -n "${_DC_T_EXTRAS_LOADED:-}" ]] && return 0
_DC_T_EXTRAS_LOADED=1

# ---------------- Apple Intelligence：三个位置合一条 ----------------
EX_AI_TOTAL_KB=0
EX_AI_SEEN=0
EX_AI_UNREADABLE=0

# 只读测量单条路径：存在才计；du 读不到置 UNREADABLE，且不把读不到累加成 0
ex_ai_measure() {
    local p="${1:-}" kb
    [[ -e "$p" ]] || return 0
    EX_AI_SEEN=1
    kb=$(du_kb_strict "$p")
    if [[ -z "$kb" || "$kb" -lt 0 ]]; then
        EX_AI_UNREADABLE=1
    else
        EX_AI_TOTAL_KB=$((EX_AI_TOTAL_KB + kb))
    fi
}

# ---------------- 只报告段 ----------------
targets_extras() {
    local kb n ai_hit
    dc_section extras
    say "  只报告：系统级大户（只读，不代删，不影响退出码；读不到的如实写「读不到」，不当 0）"

    # /cores：崩溃转储（root 属主，常见读不到）
    if [[ ! -d /cores ]]; then
        report_line cores "崩溃转储 /cores" 0 "未找到"
    else
        kb=$(du_kb_strict /cores)
        n=$(run_timeout "$DC_TIMEOUT_QUICK" find /cores -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
        [[ -n "$n" ]] || n="unknown"
        if [[ -z "$kb" || "$kb" -lt 0 ]]; then
            report_line cores "崩溃转储 /cores" -1 "root 属主，读不到；确认后交用户终端用 sudo 删 /cores/core.*"
        else
            report_line cores "崩溃转储 /cores" "$kb" "${n} 个 core 文件；确认后交用户终端用 sudo 删 /cores/core.*"
        fi
    fi

    # Apple Intelligence：三个位置，读不到按 SIP/TCC 处理
    EX_AI_TOTAL_KB=0
    EX_AI_SEEN=0
    EX_AI_UNREADABLE=0
    for ai_hit in /System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_*; do
        ex_ai_measure "$ai_hit"   # 无匹配时是字面量，-e 为假直接跳过
    done
    ex_ai_measure "/private/var/db/AppleIntelligencePlatform"
    ex_ai_measure "$HOME/Library/Caches/com.apple.intelligence"
    if [[ "$EX_AI_SEEN" -eq 0 ]]; then
        report_line apple_intelligence "Apple Intelligence" 0 "未找到"
    elif [[ "$EX_AI_UNREADABLE" -eq 1 ]]; then
        report_line apple_intelligence "Apple Intelligence" -1 "SIP/TCC"
    else
        report_line apple_intelligence "Apple Intelligence" "$EX_AI_TOTAL_KB" \
            "系统托管，只能看不能删；入口「系统设置 → 通用 → 储存空间」"
    fi

    report_path vm "交换/睡眠镜像 /private/var/vm" "/private/var/vm" \
        "不要手删，系统自行回收" "SIP/权限拒绝"
    report_path diagnostics "系统统一日志 /private/var/db/diagnostics" "/private/var/db/diagnostics" \
        "不要手删，系统自行轮转" "SIP/权限拒绝"
    report_path uuidtext "系统统一日志 /private/var/db/uuidtext" "/private/var/db/uuidtext" \
        "不要手删，系统自行轮转" "SIP/权限拒绝"
    report_path updates "系统更新暂存 /Library/Updates" "/Library/Updates" \
        "不要动" "权限拒绝"
    report_path applications "应用体积 /Applications" "/Applications" \
        "只报告；卸载不需要的 App 由用户决定" "权限拒绝"
    report_path icloud "iCloud 本地副本 ~/Library/Mobile Documents" "$HOME/Library/Mobile Documents" \
        "只报告；应用内「移除下载」" "权限拒绝"

    # 第三方快照统一由 target_snapshots 报告（同一事实只报一次，避免重复条目）
    say ""
}
