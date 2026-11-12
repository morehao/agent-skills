#!/usr/bin/env bash
# 用例 02：保护清单（protect.tsv + 用户 protect.txt）。
# hard 命中必须拦、soft 命中必须拦、用户 !pattern 只能解除 soft、hard 不能解除。
# 用户文件按「$HOME 字面量」写（lib/safety.sh 会把开头的 $HOME 还原成真实路径）。

dc_protect_user_file() {
    printf '%s/.config/disk-cleanup/protect.txt' "$HOME"
}

dc_case_protect_hard() {
    local reason rc
    dc_protect_load
    reason=$(dc_protected_reason "$HOME/Library/Caches/com.apple.spotlight")
    rc=$?
    dc_assert_eq 0 "$rc" 'hard 命中 Spotlight 缓存应被拦'
    dc_assert_eq 'spotlight-index' "$reason" 'hard Spotlight 的 reason 应来自 protect.tsv'
    reason=$(dc_protected_reason "$HOME/Library/Messages")
    rc=$?
    dc_assert_eq 0 "$rc" 'hard 命中 Messages（用户数据）应被拦'
    dc_assert_eq 'imessage-data' "$reason" 'hard Messages 的 reason 应为 imessage-data'
    dc_assert_nonzero '未命中的路径不应被拦' \
        dc_protected_reason "$HOME/Library/Caches/definitely-not-in-protect-tsv"
}

dc_case_protect_soft() {
    local reason rc
    dc_protect_load
    reason=$(dc_protected_reason "$HOME/Library/Caches/ms-playwright")
    rc=$?
    dc_assert_eq 0 "$rc" 'soft 命中 playwright 应被拦'
    dc_assert_eq 'playwright-browsers' "$reason" 'soft playwright 的 reason 应来自 protect.tsv'
    reason=$(dc_protected_reason "$HOME/.ollama/models/llama3")
    rc=$?
    dc_assert_eq 0 "$rc" 'soft 命中 ollama models 应被拦'
    dc_assert_eq 'ollama-models' "$reason" 'soft ollama 的 reason 应为 ollama-models'
}

dc_case_protect_user_override() {
    local uf reason rc
    uf=$(dc_protect_user_file)
    mkdir -p -- "$(dirname -- "$uf")" || {
        dc_fail "无法创建 ${uf} 的父目录"
        return 1
    }
    {
        printf '%s\n' '!$HOME/Library/Caches/ms-playwright*'
        printf '%s\n' '!$HOME/Library/Caches/com.apple.spotlight*'
        printf '%s\n' '/opt/dc-keep-me'
    } >"$uf"
    dc_protect_load

    reason=$(dc_protected_reason "$HOME/Library/Caches/ms-playwright")
    rc=$?
    dc_assert_rc_nonzero "$rc" '用户 !pattern 应能解除 soft 保护（playwright）'

    reason=$(dc_protected_reason "$HOME/Library/Caches/com.apple.spotlight")
    rc=$?
    dc_assert_eq 0 "$rc" 'hard 不能被打 ! 解除（spotlight 仍应被拦）'
    dc_assert_eq 'spotlight-index' "$reason" 'hard 的 reason 不应因用户文件改变'

    reason=$(dc_protected_reason '/opt/dc-keep-me/sub')
    rc=$?
    dc_assert_eq 0 "$rc" '用户文件追加的绝对路径应生效'
    dc_assert_eq 'user-protect' "$reason" '用户追加项的 reason 应为 user-protect'

    # 复位：别把用户文件留给后面的用例
    rm -f -- "$uf"
    dc_protect_load
    reason=$(dc_protected_reason "$HOME/Library/Caches/ms-playwright")
    rc=$?
    dc_assert_eq 0 "$rc" '移除用户文件后 soft 保护应恢复'
}

DC_CASES+=(
    dc_case_protect_hard
    dc_case_protect_soft
    dc_case_protect_user_override
)
