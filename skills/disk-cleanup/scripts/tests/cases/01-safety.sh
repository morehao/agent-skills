#!/usr/bin/env bash
# 用例 01：路径断言（I2）、删除漏斗（I1）、HOME 断言（I3）、超时器（I6）、根身份回溯（I4）。
# 依赖 run.sh 已载入 lib/* 并把 HOME 指到假目录。

# dc_path_assert 必须拒绝「会塌缩成系统路径 / 已规范化前含 .. / 带控制字符」的输入。
dc_case_path_assert_rejects() {
    dc_assert_nonzero '空路径应被拒绝' dc_path_assert ''
    dc_assert_nonzero '相对路径应被拒绝' dc_path_assert 'relative/path'
    dc_assert_nonzero '根 / 应被拒绝' dc_path_assert '/'
    dc_assert_nonzero 'HOME 本身应被拒绝' dc_path_assert "$HOME"
    dc_assert_nonzero '含控制字符（TAB）应被拒绝' dc_path_assert "$HOME/Library/Caches/a"$'\t'"b"
    dc_assert_nonzero '含未规范化 .. 组件应被拒绝' dc_path_assert "$HOME/../outside"
    dc_assert_nonzero '含 . 组件应被拒绝' dc_path_assert "$HOME/./Library"
    dc_assert_ok '正常的绝对路径应通过' dc_path_assert "$HOME/Library/Caches/some-app"
}

# dc_funnel_rm 必须自己再过一遍路径断言：哪怕调用方传了脏路径，也不能真的 rm。
# 用「假 rm」兜底：断言若退化，记到 mark 文件里，而不是真删东西。
dc_case_funnel_rm_rejects() {
    local mark="$HOME/.funnel-rm-called" p rc
    for p in '' 'relative/path' "$HOME/../outside" "$HOME/Library/Caches/a"$'\t'"b" '/' "$HOME"; do
        rm -f -- "$mark"
        rc=$( (
            rm() {
                printf 'x' >> "$mark"
                return 1
            }
            dc_counters_reset
            dc_funnel_rm "$p" 0 >/dev/null 2>&1
            printf '%s' "$?"
        ) )
        dc_assert_rc_nonzero "$rc" "dc_funnel_rm 应拒绝非法路径 [${p}]"
        dc_assert_begin
        if [[ -s "$mark" ]]; then
            dc_fail "dc_funnel_rm 对非法路径 [${p}] 真的调用了 rm（路径断言已失效！）"
        fi
    done
}

# I3：HOME 为空 / 相对 / 不存在时，脚本必须 exit 2，不能把 "$HOME/..." 塌缩成系统路径。
dc_case_env_assert_home() {
    dc_assert_exit 2 'HOME 为空时 dc_env_assert 应 exit 2' \
        bash -c 'HOME=; . "$DC_SCRIPT_DIR/lib/timeout.sh"; . "$DC_SCRIPT_DIR/lib/safety.sh"; dc_env_assert'
    dc_assert_exit 2 'HOME 为相对路径时 dc_env_assert 应 exit 2' \
        bash -c 'HOME=relative/home; . "$DC_SCRIPT_DIR/lib/timeout.sh"; . "$DC_SCRIPT_DIR/lib/safety.sh"; dc_env_assert'
    dc_assert_exit 2 'HOME 目录不存在时 dc_env_assert 应 exit 2' \
        bash -c 'HOME=/nonexistent-dc-tests-home; . "$DC_SCRIPT_DIR/lib/timeout.sh"; . "$DC_SCRIPT_DIR/lib/safety.sh"; dc_env_assert'
    dc_assert_exit 2 'HOME= 时 mac_cleanup.sh --list 应 exit 2' \
        env HOME= bash "$DC_SCRIPT" --list
    dc_assert_exit 2 'HOME 不存在时 mac_cleanup.sh --list 应 exit 2' \
        env HOME=/nonexistent-dc-tests-home bash "$DC_SCRIPT" --list
}

# I6：run_timeout 超时返回 124，且不把 5s 的命令拖到 5s 之后。
dc_case_run_timeout() {
    local start end elapsed rc=0
    start=$(date +%s)
    run_timeout 2 sleep 5 >/dev/null 2>&1 || rc=$?
    end=$(date +%s)
    elapsed=$((end - start))
    dc_assert_eq 124 "$rc" 'run_timeout 2 sleep 5 的退出码应为 124'
    dc_assert_le 6 "$elapsed" 'run_timeout 2 sleep 5 的总耗时应 ≤6s'
    dc_assert_exit 0 'run_timeout 5 true 应返回 0' run_timeout 5 true
    dc_assert_exit 1 'run_timeout 5 false 应返回 1' run_timeout 5 false
}

# I4：根身份按 / 边界判定，/Users/x 不能把 /Users/xy 认成自己的子路径。
dc_case_dc_under() {
    dc_assert_ok '/Users/x 包含自身' dc_under /Users/x /Users/x
    dc_assert_ok '/Users/x 包含子路径' dc_under /Users/x/Library /Users/x
    dc_assert_nonzero '/Users/x 不包含 /Users/xy' dc_under /Users/xy /Users/x
    dc_assert_nonzero '/Users/x 不包含父路径' dc_under /Users/x /Users/x/Library
    dc_assert_nonzero '空路径不被任何根包含' dc_under '' /Users/x
    dc_assert_ok '根 / 包含一切绝对路径' dc_under /anything/here /
}

DC_CASES+=(
    dc_case_path_assert_rejects
    dc_case_funnel_rm_rejects
    dc_case_env_assert_home
    dc_case_run_timeout
    dc_case_dc_under
)
