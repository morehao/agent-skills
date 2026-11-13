#!/usr/bin/env bash
# 用例 10：/var/folders 的老化清理必须跳过 AppTranslocation。
#
# AppTranslocation 是 macOS 给「从下载目录直接运行」的 App 做的隔离副本，里面是
# **正在运行的 app 本体**（du 会报 Result too large）。把它当临时垃圾删掉会让 app 当场崩，
# 所以 dc_delete_aged（以及同口径的 subset_kb）必须 prune 掉它。

dc_case_varfolders_skip_apptranslocation() {
    local root at_dir keep gone
    root="$DC_TMPHOME/vf/T"
    at_dir="$root/AppTranslocation/UUID/d/Obsidian.app/Contents"
    mkdir -p "$at_dir"
    printf 'x' > "$at_dir/binary"
    printf 'x' > "$root/old.tmp"
    touch -t 202001010000 "$at_dir/binary" "$root/old.tmp" 2>/dev/null || true

    dc_delete_aged "$root" 0 >/dev/null 2>&1

    dc_assert_begin
    if [[ -e "$root/old.tmp" ]]; then dc_fail '普通过期文件应被删'; else :; fi
    dc_assert_begin
    if [[ -e "$at_dir/binary" ]]; then :; else dc_fail 'AppTranslocation 下的文件不该被删（那是运行中的 app 本体）'; fi

    # 测量口径也要一致：AppTranslocation 不计入可删量
    dc_assert_eq 0 "$(subset_kb "$root" 0)" 'AppTranslocation 不应计入 subset_kb'
}

dc_case_varfolders_apptranslocation_measure() {
    local root at_dir
    root="$DC_TMPHOME/vf2/T"
    at_dir="$root/AppTranslocation/UUID/d/App.app/Contents"
    mkdir -p "$at_dir"
    dd if=/dev/zero of="$at_dir/blob" bs=1024 count=2048 2>/dev/null
    touch -t 202001010000 "$at_dir/blob" 2>/dev/null || true
    dc_assert_eq 0 "$(subset_kb "$root" 0)" '整棵 AppTranslocation 都被跳过（2MB 也不计）'
}

DC_CASES+=(
    dc_case_varfolders_skip_apptranslocation
    dc_case_varfolders_apptranslocation_measure
)
