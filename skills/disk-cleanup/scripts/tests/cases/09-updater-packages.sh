#!/usr/bin/env bash
# 用例 09：更新包（Upgrade/ 下的历史安装包）。
#
# 沙箱 App 把下载的安装包放在 Containers/<id>/Data/Library/Application Support/Upgrade/，
# 这个位置不在任何既有编码的扫描面里。规则：只删超 UPD_AGE_DAYS 天未动的子项，
# 保留 Upgrade 目录本身；App Support 与 Containers 两处都要扫到。

dc_case_updater_packages() {
    local root old_pkg fresh_pkg json mf hit

    root="$HOME/Library/Containers/com.test.app/Data/Library/Application Support/Upgrade"
    mkdir -p "$HOME/Library/Application Support"          # target 在 App Support 缺失时会直接返回
    mkdir -p "$root/oldpkg" "$root/freshpkg"
    printf 'x' > "$root/oldpkg/payload.bin"
    printf 'x' > "$root/freshpkg/payload.bin"
    touch -t 202001010000 "$root/oldpkg" 2>/dev/null || true

    # UPD_AGE_DAYS=1：只应命中 2020 年那个
    json=$(UPD_AGE_DAYS=1 bash "$DC_SCRIPT" --clean --dry-run --only updaters --json 2>/dev/null)
    mf=$(printf '%s' "$json" | sed -n 's/.*"manifest":{"path":"\([^"]*\)".*/\1/p')
    dc_assert_begin
    if [[ -f "$mf" ]]; then :; else dc_fail "updaters 预览没产出清单"; return 0; fi

    hit=$(grep -c 'Upgrade/oldpkg' "$mf" 2>/dev/null || true)
    dc_assert_eq 1 "${hit:-0}" '超龄的更新包应进清单'

    hit=$(grep -c 'Upgrade/freshpkg' "$mf" 2>/dev/null || true)
    dc_assert_eq 0 "${hit:-0}" '未超龄的更新包不该进清单'

    hit=$(grep -c 'Upgrade	' "$mf" 2>/dev/null || true)
    dc_assert_eq 0 "${hit:-0}" 'Upgrade 目录本身不该被删，只删里面的历史包'
}

DC_CASES+=(
    dc_case_updater_packages
)
