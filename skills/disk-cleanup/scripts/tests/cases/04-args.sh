#!/usr/bin/env bash
# 用例 04：参数契约（规格 §4.1 / §4.3）。
# 单独 --dry-run、--clean 不带 --only/--skip/--all、未知编码、未知参数，都必须 exit 2。

dc_case_args_contract() {
    dc_assert_exit 2 '--clean 不带 --only/--skip/--all 应 exit 2' \
        bash "$DC_SCRIPT" --clean
    dc_assert_exit 2 '单独 --dry-run 应 exit 2（不再静默降级成查询）' \
        bash "$DC_SCRIPT" --dry-run
    dc_assert_exit 2 '未知编码（--only）应 exit 2' \
        bash "$DC_SCRIPT" --clean --only no-such-code
    dc_assert_exit 2 '未知编码（--skip）应 exit 2' \
        bash "$DC_SCRIPT" --clean --only caches --skip no-such-code
    dc_assert_exit 2 '未知参数应 exit 2' \
        bash "$DC_SCRIPT" --no-such-flag
    dc_assert_exit 0 '--list 应正常退出' \
        bash "$DC_SCRIPT" --list
    dc_assert_exit 0 '--list --json 应正常退出' \
        bash "$DC_SCRIPT" --list --json
    dc_assert_exit 0 '--help 应正常退出' \
        bash "$DC_SCRIPT" --help
}

DC_CASES+=(
    dc_case_args_contract
)
