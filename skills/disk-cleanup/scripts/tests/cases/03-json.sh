#!/usr/bin/env bash
# 用例 03：json_esc 的转义契约（schema 2 的 JSON 全靠它拼，转义错了 agent 解析会炸）。

dc_case_json_esc() {
    local got input

    got=$(json_esc 'say "hi"')
    dc_assert_eq 'say \"hi\"' "$got" '双引号应转义成 \"'

    got=$(json_esc 'C:\temp\a')
    dc_assert_eq 'C:\\temp\\a' "$got" '反斜杠应转义成 \\'

    input=$(printf 'a\001b')
    got=$(json_esc "$input")
    dc_assert_eq 'ab' "$got" '控制字符应被移除'

    got=$(json_esc '中文/测试（含括号）')
    dc_assert_eq '中文/测试（含括号）' "$got" '中文与全角符号应原样保留'

    input=$(printf 'a\nb')
    got=$(json_esc "$input")
    dc_assert_eq 'ab' "$got" '换行应被移除（不能把 JSON 拆成两行）'

    input=$(printf 'x\001\ty\002z')
    got=$(json_esc "$input")
    dc_assert_begin
    case "$got" in
        *[[:cntrl:]]*)
            dc_fail "json_esc 输出仍含原始控制字符（会把 JSON 弄坏）：$(printf '%s' "$got" | od -An -c | tr -s ' ')"
            ;;
    esac

    # 组合：引号 + 反斜杠 + 控制字符 + 中文，输出仍应是一条合法 JSON 字符串内容
    input=$(printf '路径 "%s" \\ 完\001成' '/tmp/a')
    got=$(json_esc "$input")
    dc_assert_eq '路径 \"/tmp/a\" \\ 完成' "$got" '混合输入应按顺序转义并去掉控制字符'
}

DC_CASES+=(
    dc_case_json_esc
)
