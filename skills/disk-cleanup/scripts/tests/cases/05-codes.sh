#!/usr/bin/env bash
# 用例 05：编码契约（data/codes.tsv ↔ --list --json）与 reason/status 枚举闭合（规格 §4.3）。

dc_tsv_code_ids() {
    awk -F'\t' '!/^[[:space:]]*#/ && NF >= 4 && $1 != "" { print $1 }' "$DC_CODES_TSV"
}

dc_json_code_ids() {
    grep -o '"id":"[^"]*"' | sed -e 's/^"id":"//' -e 's/"$//'
}

# data/codes.tsv 的 id 集合与顺序，必须与 `--list --json` 完全一致。
dc_case_codes_tsv_matches_list() {
    local out tsv_csv json_csv tsv_n json_n rc=0
    out=$(bash "$DC_SCRIPT" --list --json 2>/dev/null) || rc=$?
    dc_assert_eq 0 "$rc" '--list --json 应 exit 0'

    tsv_csv=$(dc_tsv_code_ids | paste -sd, -)
    json_csv=$(printf '%s' "$out" | dc_json_code_ids | paste -sd, -)
    tsv_n=$(dc_tsv_code_ids | wc -l | tr -d ' ')
    json_n=$(printf '%s' "$out" | dc_json_code_ids | wc -l | tr -d ' ')

    dc_assert_gt 0 "$tsv_n" 'data/codes.tsv 应至少声明 1 个编码'
    dc_assert_eq "$tsv_n" "$json_n" 'data/codes.tsv 与 --list --json 的编码数量应一致'
    dc_assert_eq "$tsv_csv" "$json_csv" 'data/codes.tsv 与 --list --json 的 id/顺序应一致'
}

# 规格 §4.3 的枚举白名单（门禁的对照表就写在这里，别散落）
DC_ALLOWED_STATUS=' queried dry-run skipped-unselected skipped-sudo done partial failed reported '
DC_ALLOWED_REASON=' ok protected in-use denied-tcc denied-sandbox denied-readonly sudo-required timeout not-found io-error unverified-owner stale-guard user-kept unselected unknown '

DC_SCAN_HITS=0
DC_ENUM_TOTAL=0

# dc_scan_enum <文件> <reason|status> <正则> <白名单>
# 正则必须以一个双引号包裹的字面量结尾，值从最后一对引号里取。
dc_scan_enum() {
    local file="$1" kind="$2" pat="$3" allowed="$4" hit ln tok val
    DC_SCAN_HITS=0
    while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        ln="${hit%%:*}"
        tok="${hit#*:}"
        val=$(printf '%s' "$tok" | sed -E 's/.*"([A-Za-z0-9_-]+)"$/\1/')
        DC_SCAN_HITS=$((DC_SCAN_HITS + 1))
        dc_assert_begin
        case " $allowed " in
            *" $val "*) ;;
            *) dc_fail "${file}:${ln} 出现未登记的 ${kind}「${val}」（白名单在 tests/cases/05-codes.sh，值见规格 §4.3）" ;;
        esac
    done < <(grep -n -o -E "$pat" "$file" 2>/dev/null)
}

# lib/**/*.sh 里出现的 reason/status 字面量都必须落在 §4.3 的枚举里。
dc_case_enum_closed() {
    local f
    for f in "$DC_SCRIPTS_DIR"/lib/*.sh "$DC_SCRIPTS_DIR"/lib/targets/*.sh; do
        [[ -f "$f" ]] || continue
        dc_scan_enum "$f" 'reason' '(reason":"|DC_LAST_REASON=|STEP_REASON=)"[A-Za-z0-9_-]+"' "$DC_ALLOWED_REASON"
        DC_ENUM_TOTAL=$((DC_ENUM_TOTAL + DC_SCAN_HITS))
        dc_scan_enum "$f" 'status' '(status":"|status=)"[A-Za-z0-9_-]+"' "$DC_ALLOWED_STATUS"
        DC_ENUM_TOTAL=$((DC_ENUM_TOTAL + DC_SCAN_HITS))
        dc_scan_enum "$f" 'status' 'json_add[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+"[A-Za-z0-9_-]+"' "$DC_ALLOWED_STATUS"
        DC_ENUM_TOTAL=$((DC_ENUM_TOTAL + DC_SCAN_HITS))
    done
    # 防「扫了 0 处却绿」：内核里至少要有 json_add 的 done / skipped-* 字面量
    dc_assert_gt 0 "$DC_ENUM_TOTAL" 'lib 里应扫到至少 1 处 reason/status 字面量（否则本用例形同虚设）'
}

DC_CASES+=(
    dc_case_codes_tsv_matches_list
    dc_case_enum_closed
)
