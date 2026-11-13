#!/usr/bin/env bash
# 用例 08：候选清单（manifest）契约。
#
# 预览必须能回答「到底会删哪些路径」：清单与真实执行同源（plan 模式走同一条漏斗），
# 且预览本身不许动文件系统。这里锁住六件事：
#   ① JSON 给出清单路径与计数；② 表头 + 7 个字段；③ 编码/判定/类型枚举闭合；
#   ④ count 与数据行数一致；⑤ plan 模式零删除；⑥ 未勾选编码不进清单。

dc_manifest_json() {
    bash "$DC_SCRIPT" --clean --dry-run "$@" --json 2>/dev/null
}

# 从单行 JSON 里取 manifest.path / manifest.count（不引 jq）
dc_manifest_get() {
    local json="$1" key="$2"
    case "$key" in
        path) printf '%s' "$json" | sed -n 's/.*"manifest":{"path":"\([^"]*\)".*/\1/p' ;;
        count) printf '%s' "$json" | sed -n 's/.*"manifest":{"path":"[^"]*","count":\([0-9][0-9]*\).*/\1/p' ;;
    esac
}

# 造一个过期文件：mtime 越老越稳，不依赖 date 的相对运算
dc_manifest_make_old() {
    local p="$1"
    mkdir -p "$(dirname -- "$p")"
    printf 'dc-manifest-test' > "$p"
    touch -t 202001010000 "$p" 2>/dev/null || true
}

dc_case_manifest_preview() {
    local root out mf n jcount bad_i bad_k bad_d code
    root="$HOME/Library/Caches/dc-manifest-fixture"
    dc_manifest_make_old "$root/old.bin"
    dc_manifest_make_old "$root/nested/old2.bin"

    out=$(dc_manifest_json --only caches)
    dc_assert_contains "$out" '"manifest":{"path":"' 'JSON 应给出清单文件路径'
    mf=$(dc_manifest_get "$out" path)
    dc_assert_begin
    if [[ ! -f "$mf" ]]; then dc_fail "清单文件不存在：${mf}"; return 0; fi

    dc_assert_eq 1 "$(grep -c '^#code' "$mf" 2>/dev/null)" '清单应有一行 #code 表头'

    bad_i=$(awk -F'\t' 'NR>1 && NF != 7 {n++} END{print n+0}' "$mf" 2>/dev/null)
    dc_assert_eq 0 "${bad_i:-0}" '清单每行必须是 7 个制表符分隔字段'

    n=$(awk 'NR>1' "$mf" 2>/dev/null | grep -c . || true)
    dc_assert_gt '0' "${n:-0}" '带过期文件的假 HOME 应产出候选'
    jcount=$(dc_manifest_get "$out" count)
    dc_assert_eq "${n:-0}" "${jcount:-0}" 'JSON 的 manifest.count 应等于清单数据行数'

    # 编码枚举：每行 code 必须来自 codes.tsv
    bad_d=0
    while IFS=$'\t' read -r code _rest; do
        case "$code" in
            '#'*|'') continue ;;
        esac
        case " $KNOWN_IDS " in
            *" $code "*) ;;
            *) bad_d=$((bad_d + 1)) ;;
        esac
    done < "$mf"
    dc_assert_eq 0 "$bad_d" '清单里的编码必须都在 codes.tsv 中'

    # 判定/类型枚举闭合
    bad_i=$(awk -F'\t' 'NR>1 && $2 !~ /^(delete|protected|unverified)$/ {n++} END{print n+0}' "$mf")
    dc_assert_eq 0 "${bad_i:-0}" 'decision 只能是 delete/protected/unverified'
    bad_k=$(awk -F'\t' 'NR>1 && $3 !~ /^(dir|file|command)$/ {n++} END{print n+0}' "$mf")
    dc_assert_eq 0 "${bad_k:-0}" 'kind 只能是 dir/file/command'

    # 未勾选的编码不进清单
    code=$(awk -F'\t' 'NR>1 && $1 != "caches" {print $1; exit}' "$mf" 2>/dev/null)
    dc_assert_eq "" "${code:-}" '--only caches 的清单里不应出现其它编码'

    # plan 模式零删除
    dc_assert_begin
    if [[ -f "$root/old.bin" && -f "$root/nested/old2.bin" ]]; then :; else
        dc_fail '预览动了文件系统：plan 模式只应记录，不应删除'
    fi

    # 清单里的路径必须真的还在（预览的语义）
    code=$(awk -F'\t' 'NR>1 && $2=="delete" && $4 ~ /dc-manifest-fixture/ {print $4; exit}' "$mf" 2>/dev/null)
    dc_assert_begin
    if [[ -n "${code:-}" && -e "$code" ]]; then :; else
        dc_fail "清单标为 delete 的路径应仍然存在（预览不删）：${code:-<空>}"
    fi
}

dc_case_manifest_protected() {
    local root out mf hit
    # 保护清单里 ~/Library/Caches/com.apple.spotlight* 是 hard 项
    root="$HOME/Library/Caches/com.apple.spotlight"
    dc_manifest_make_old "$root/old.bin"

    out=$(dc_manifest_json --only caches)
    mf=$(dc_manifest_get "$out" path)
    hit=$(awk -F'\t' 'NR>1 && $2=="protected" && $4 ~ /com\.apple\.spotlight/ {n++} END{print n+0}' "$mf" 2>/dev/null)
    dc_assert_gt '0' "${hit:-0}" '保护清单命中的路径应以 decision=protected 记入清单'
}

dc_case_manifest_path_argument() {
    local dest="$HOME/custom-manifest.tsv" out mf
    out=$(dc_manifest_json --only caches --manifest "$dest")
    mf=$(dc_manifest_get "$out" path)
    dc_assert_eq "$dest" "${mf:-}" '--manifest 应把清单写进指定路径'
    dc_assert_begin
    if [[ -f "$dest" ]] && grep -q '^#code' "$dest" 2>/dev/null; then :; else
        dc_fail '--manifest 指定的文件应含表头'
    fi
}

dc_case_manifest_rejects_non_preview() {
    dc_assert_exit 2 '--manifest 不带 --dry-run 应拒绝' bash "$DC_SCRIPT" --clean --only caches --manifest "$HOME/x.tsv"
    dc_assert_exit 2 '--manifest 不带 --clean 应拒绝' bash "$DC_SCRIPT" --manifest "$HOME/x.tsv"
}

dc_case_manifest_query_is_null() {
    local out
    out=$(bash "$DC_SCRIPT" --only caches --json 2>/dev/null)
    dc_assert_contains "$out" '"manifest":null' '查询模式不应产出候选清单（manifest=null）'
}

DC_CASES+=(
    dc_case_manifest_preview
    dc_case_manifest_protected
    dc_case_manifest_path_argument
    dc_case_manifest_rejects_non_preview
    dc_case_manifest_query_is_null
)
