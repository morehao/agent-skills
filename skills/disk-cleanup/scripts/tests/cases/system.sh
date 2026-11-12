#!/usr/bin/env bash
# 用例（system 组）：tmp / varfolders / snapshots / trash / appcache / updaters / systemlogs
#
# 安全边界：
#   - 只在 run.sh 建立的假 HOME 里造数据、删数据；
#   - 需要 sudo 的编码（tmp / snapshots / systemlogs）只跑 --dry-run，绝不跑非 dry-run 的
#     --clean —— 那会真删 /private/tmp、真 thin 快照，且 sudo 缓存命中时会真的执行；
#   - varfolders 指向真实用户的 /var/folders 容器，所以这里只做 dry-run 与测量断言。
#
# 断言用子串匹配而不是 json.loads：本用例不该被别的 target 的 JSON 问题连坐。

# system 组的目标都绑 macOS 的系统路径/命令（tmutil、lsappinfo、/private/var/log、
# /var/folders 的当前用户容器）。CI 跑在 ubuntu-latest：那里「平台没有这个对象」不是失败，
# 所以整组按平台跳过，别把 Linux 上必然缺的条目当成回归。
dc_case_needs_darwin() {
    case "$(uname -s)" in
        Darwin) return 0 ;;
    esac
    dc_skip "当前平台 $(uname -s) 不是 macOS，system 组用例跳过"
    return 1
}

# dc_system_json_has <json> <子串> <说明>
dc_system_json_has() {
    dc_assert_contains "${1-}" "${2-}" "${3-}"
}

# 造一个够大的目录（> appcache/updaters 的 10MB 门槛），du 与 dd 都是两边通用的命令
dc_system_make_big() {
    local dir="$1"
    mkdir -p -- "$dir" || return 1
    dd if=/dev/zero of="$dir/blob" bs=1024 count=11264 >/dev/null 2>&1 || return 1
    return 0
}

# 用例 S1：7 个 system 编码的 dry-run 契约 —— 逐项有计划、退出码 0、不改动任何东西。
dc_case_system_dryrun_plan() {
    dc_case_needs_darwin || return 0
    local ids='tmp,varfolders,snapshots,trash,appcache,updaters,systemlogs'
    local need='target_tmp target_varfolders target_snapshots target_trash target_appcache target_updaters target_systemlogs'
    local fn missing=0

    for fn in $need; do
        if ! declare -F "$fn" >/dev/null 2>&1; then
            dc_skip "targets 里还没有 ${fn} 的实现（队友并行开发中），跳过 system 组 dry-run"
            missing=1
            break
        fi
    done
    [[ "$missing" -eq 0 ]] || return 0

    # 先在假 HOME 造可删目标：dry-run 必须一个都不动
    mkdir -p -- "$HOME/.Trash" || { dc_fail '无法创建假废纸篓'; return 1; }
    printf 'x' >"$HOME/.Trash/old.txt"
    dc_system_make_big "$HOME/Library/Application Support/TestApp/Cache" || {
        dc_fail '无法创建假 app 缓存目录'
        return 1
    }
    dc_system_make_big "$HOME/Library/Application Support/TestApp/auto-updater" || {
        dc_fail '无法创建假更新残留目录'
        return 1
    }

    local out="" rc=0
    out=$(run_timeout 300 bash "$DC_SCRIPT" --clean --dry-run --only "$ids" --json 2>/dev/null) || rc=$?
    dc_assert_eq 0 "$rc" "--clean --dry-run --only ${ids} 应 exit 0"
    dc_system_json_has "$out" '"schema":2' 'dry-run 的 JSON 应带 schema 2'
    dc_system_json_has "$out" '"mode":"dry-run"' 'dry-run 的 mode 应为 dry-run'
    dc_system_json_has "$out" '"freed_kb":0' 'dry-run 的 freed_kb 应为 0'

    local id
    for id in tmp varfolders snapshots trash appcache updaters systemlogs; do
        dc_system_json_has "$out" "\"id\":\"${id}\"" "JSON 里应出现编码 ${id} 的条目"
    done
    # dry-run 不许动数据
    dc_assert_ok 'dry-run 后假废纸篓条目应仍然存在' test -e "$HOME/.Trash/old.txt"
    dc_assert_ok 'dry-run 后假 app 缓存应仍然存在' \
        test -e "$HOME/Library/Application Support/TestApp/Cache/blob"
    dc_assert_ok 'dry-run 后假更新残留应仍然存在' \
        test -e "$HOME/Library/Application Support/TestApp/auto-updater/blob"
}

# 用例 S2：trash / appcache / updaters 在假 HOME 里真删 —— 该删的删、该留的留。
dc_case_system_clean_in_fake_home() {
    dc_case_needs_darwin || return 0
    local fn
    for fn in target_trash target_appcache target_updaters; do
        if ! declare -F "$fn" >/dev/null 2>&1; then
            dc_skip "targets 里还没有 ${fn} 的实现，跳过假 HOME 真删用例"
            return 0
        fi
    done

    local support="$HOME/Library/Application Support"
    # 废纸篓：普通条目 + 隐藏条目 + 子目录
    mkdir -p -- "$HOME/.Trash/sub" || { dc_fail '无法创建假废纸篓'; return 1; }
    printf 'x' >"$HOME/.Trash/sub/a.txt"
    printf 'x' >"$HOME/.Trash/.hidden-item"
    # appcache：>10MB 的 Cache 该删；配置与登录态该留；<10MB 的小缓存按语义也该留
    dc_system_make_big "$support/TestApp/Cache" || { dc_fail '无法创建假 Cache'; return 1; }
    dc_system_make_big "$support/TestApp/Code Cache" || { dc_fail '无法创建假 Code Cache'; return 1; }
    mkdir -p -- "$support/TestApp/Local Storage" "$support/TestSmall/Cache" || {
        dc_fail '无法创建假配置目录'
        return 1
    }
    printf 'cfg' >"$support/TestApp/config.json"
    printf 'login' >"$support/TestApp/Local Storage/leveldb-token"
    printf 'tiny' >"$support/TestSmall/Cache/blob"
    # updaters：>10MB 的 auto-updater 该删
    dc_system_make_big "$support/TestApp/auto-updater" || { dc_fail '无法创建假更新残留'; return 1; }

    local rc=0
    run_timeout 300 bash "$DC_SCRIPT" --clean --only trash,appcache,updaters >/dev/null 2>&1 || rc=$?
    dc_assert_eq 0 "$rc" '--clean --only trash,appcache,updaters 应 exit 0（只在假 HOME 下删）'

    # 该删的
    dc_assert_begin
    [[ ! -e "$HOME/.Trash/old.txt" ]] || dc_fail '废纸篓里的普通条目应被清掉'
    dc_assert_begin
    [[ ! -e "$HOME/.Trash/sub" ]] || dc_fail '废纸篓里的子目录应被整棵清掉'
    dc_assert_begin
    [[ ! -e "$HOME/.Trash/.hidden-item" ]] || dc_fail '废纸篓里的隐藏条目也应被清掉（NUL 遍历，不靠 glob）'
    dc_assert_begin
    [[ ! -e "$support/TestApp/Cache" ]] || dc_fail '>10MB 的 app Cache 应被整目录删掉'
    dc_assert_begin
    [[ ! -e "$support/TestApp/Code Cache" ]] || dc_fail '>10MB 的 Code Cache 应被整目录删掉'
    dc_assert_begin
    [[ ! -e "$support/TestApp/auto-updater" ]] || dc_fail '>10MB 的 auto-updater 应被整目录删掉'

    # 该留的：配置与登录态一律不动
    dc_assert_ok 'app 的配置文件不许被 appcache 删' test -e "$support/TestApp/config.json"
    dc_assert_ok 'app 的登录态（Local Storage）不许被 appcache 删' \
        test -e "$support/TestApp/Local Storage/leveldb-token"
    dc_assert_ok '小于 10MB 的小缓存按语义保留（避免把 app 频繁重建的小目录当目标）' \
        test -e "$support/TestSmall/Cache/blob"
    dc_assert_ok '假 HOME 之外不应被波及' test -d "$HOME"
}

# 用例 S3：需要 sudo 的编码在 dry-run 下必须给出「需 root」的口径而不是假装可删。
dc_case_system_sudo_encodings_measure() {
    dc_case_needs_darwin || return 0
    if ! declare -F target_systemlogs >/dev/null 2>&1; then
        dc_skip 'targets 里还没有 target_systemlogs 的实现，跳过 systemlogs 用例'
        return 0
    fi
    local out="" rc=0
    out=$(run_timeout 300 bash "$DC_SCRIPT" --clean --dry-run --only systemlogs 2>&1) || rc=$?
    dc_assert_eq 0 "$rc" '--clean --dry-run --only systemlogs 应 exit 0'
    # 计划里必须写明分批上限（规格 §8：单批 ≤5 条）
    dc_assert_contains "$out" '单批' 'systemlogs 的计划应说明单批上限'
    dc_assert_contains "$out" '5' 'systemlogs 的单批上限应为 5 条'

    rc=0
    out=$(run_timeout 300 bash "$DC_SCRIPT" --clean --dry-run --only tmp 2>&1) || rc=$?
    dc_assert_eq 0 "$rc" '--clean --dry-run --only tmp 应 exit 0'
    dc_assert_contains "$out" '/private/tmp' 'tmp 应走真实路径 /private/tmp（/tmp 是软链，find 不跟进）'
}

# 用例 S4：systemlogs 的「单批 ≤5 条」分批逻辑不能丢尾部条目。
# 白盒驱动 clean_systemlogs：把两个根指到假目录，用一个只管转发的 sudo 垫片
# 代替真实提权（只在假 HOME 里删自己刚造的文件，不碰 /private/var/log）。
dc_case_system_systemlogs_batches() {
    if ! declare -F clean_systemlogs >/dev/null 2>&1; then
        dc_skip 'targets 里还没有 clean_systemlogs 的实现，跳过分批用例'
        return 0
    fi

    local shim="$HOME/.dc-sudo-shim"
    mkdir -p -- "$shim" || { dc_fail '无法创建 sudo 垫片目录'; return 1; }
    printf '#!/bin/bash\nwhile [ "${1:-}" = "-n" ]; do shift; done\nexec "$@"\n' >"$shim/sudo"
    chmod +x "$shim/sudo"

    local saved_path="$PATH" saved_r="${SYSLOG_REPORTS:-}" saved_v="${SYSLOG_VARLOG:-}"
    PATH="$shim:$PATH"

    local c counts='5 6 12' root i left
    for c in $counts; do
        root="$HOME/.dc-syslog-${c}-$$"
        mkdir -p -- "$root" || { dc_fail "无法创建假日志根 ${c}"; break; }
        i=1
        while [[ "$i" -le "$c" ]]; do
            printf 'x' >"$root/old-${i}.ips"
            touch -t 202001010000 -- "$root/old-${i}.ips"
            i=$((i + 1))
        done
        printf 'x' >"$root/fresh.ips"
        SYSLOG_REPORTS="$root"
        SYSLOG_VARLOG="$HOME/.dc-syslog-none-$$"
        dc_counters_reset
        clean_systemlogs >/dev/null 2>&1 || true
        # 边界：正好 5 条（整批）、6 条（整批 + 尾巴 1 条）、12 条（两批 + 尾巴）
        dc_assert_eq "$c" "$DC_DEL_OK" "systemlogs 应删掉全部 ${c} 个过期文件（分批不丢尾部）"
        dc_assert_ok "未过期的日志必须保留（${c} 条过期文件的场景）" test -e "$root/fresh.ips"
        left=$(find "$root" -name 'old-*.ips' -print 2>/dev/null | wc -l | tr -d ' ')
        dc_assert_eq 0 "${left:-0}" "删完后不应残留过期日志（${c} 条过期文件的场景）"
        dc_assert_eq 0 "${#SYSLOG_BATCH[@]}" 'flush 之后批次缓冲应被清空（下一轮从 0 开始数）'
    done

    SYSLOG_REPORTS="$saved_r"
    SYSLOG_VARLOG="$saved_v"
    PATH="$saved_path"
}

DC_CASES+=(
    dc_case_system_dryrun_plan
    dc_case_system_clean_in_fake_home
    dc_case_system_sudo_encodings_measure
    dc_case_system_systemlogs_batches
)
