#!/usr/bin/env bash
# 差分 oracle 的回归测试：纯 bash，不依赖 Mole（用固定夹具冒充 clean-list.txt）。
# 守的是「分类不能错」：覆盖判定、冲突识别、/private 归一化、command 行排除、缺输入时的提示。
#
# 用法：bash scripts/dev/tests/mole-oracle-test.sh
# 退出码：0 全绿 / 1 有断言失败

set -uo pipefail

TESTS_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ORACLE="$TESTS_DIR/../mole-oracle.sh"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/mole-oracle-test.XXXXXX") || exit 1
trap 'case "$TMPD" in "${TMPDIR:-/tmp}"/mole-oracle-test.*|/tmp/mole-oracle-test.*) rm -rf -- "$TMPD" ;; esac' EXIT

FAILS=0
ASSERTS=0

ok() { ASSERTS=$((ASSERTS + 1)); printf '      ✓ %s\n' "$*"; }
bad() { ASSERTS=$((ASSERTS + 1)); FAILS=$((FAILS + 1)); printf '      ✗ %s\n' "$*"; }

# expect_contains <文件> <子串> <说明>
expect_contains() {
    if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3（没找到：$2）"; fi
}
expect_absent() {
    if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3（不该出现：$2）"; else ok "$3"; fi
}

# ---------- 夹具 ----------
OURS="$TMPD/ours.tsv"
MOLE="$TMPD/mole.txt"
REPORT="$TMPD/report.md"

{
    printf '#code\tdecision\tkind\tpath\treason\tsize_kb\tsudo\n'
    printf 'caches\tdelete\tdir\t/Users/t/Library/Caches/Foo\t\t-1\t0\n'
    printf 'caches\tdelete\tfile\t/Users/t/Library/Caches/Deep/old.bin\t\t-1\t0\n'
    printf 'caches\tprotected\tfile\t/Users/t/Library/Caches/com.apple.spotlight/x\tspotlight-index\t-1\t0\n'
    printf 'node\tdelete\tfile\t/Users/t/.npm/_cacache/x\t\t-1\t0\n'
    printf 'xcode\tdelete\tdir\t/Users/t/Library/Developer/Xcode/DerivedData\t\t-1\t0\n'
    printf 'homebrew\tdelete\tcommand\tbrew cleanup --prune=all\t\t-1\t0\n'
    printf 'tmp\tdelete\tfile\t/var/tmp/old\t\t-1\t0\n'
} > "$OURS"

cat > "$MOLE" <<'EOF'
# Mole Cleanup Preview - 2026-11-13 10:00:00
#
# How to protect files:
# 1. Run mo clean --whitelist and press Enter to save your selections
#

=== User essentials ===
/Users/t/Library/Caches/Foo  # 1.20GB
/Users/t/Library/Caches/Foo/sub  # 200.0MB, 3 items
/Users/t/Library/Caches/Bar  # 300.0MB
/Users/t/Library/Caches/Deep  # 10.0MB
/Users/t/Library/Caches/com.apple.spotlight/x  # 10.0MB
/private/var/tmp/old  # 5.0MB
=== System ===
/Users/t/Library/Caches/Baz  # size unknown
EOF

out=$("$ORACLE" --ours "$OURS" --mole "$MOLE" --out "$REPORT" 2>&1)
rc=$?
[[ "$rc" -eq 0 ]] && ok '有输入时应 exit 0' || bad "有输入时应 exit 0，实际 ${rc}：${out}"

# ---------- 分类 ----------
expect_contains "$REPORT" '（3 条' '缺口应为 3 条（Bar / Deep / Baz）'
expect_contains "$REPORT" '已知合计 300 MB' '缺口合计只算已知识别的大小'
expect_contains "$REPORT" '其中部分覆盖 1 条' 'Deep 只有后代被覆盖，应记部分覆盖'
expect_contains "$REPORT" '`/Users/t/Library/Caches/Bar`' 'Bar 应进缺口'
expect_absent "$REPORT" '`/Users/t/Library/Caches/Foo`' 'Foo 已覆盖，不该进缺口'
expect_absent "$REPORT" '`/Users/t/Library/Caches/Foo/sub`' 'Foo/sub 被祖先覆盖，不该进缺口'
expect_absent "$REPORT" '`/var/tmp/old`' '/private 与 /var 归一化后应算覆盖'
expect_contains "$REPORT" 'unknown' 'Baz 的 size unknown 应如实显示'

expect_contains "$REPORT" '（1 条）' '冲突应为 1 条（spotlight）'
expect_contains "$REPORT" 'spotlight-index' '冲突应带上我们的保护原因'
expect_contains "$REPORT" '`/Users/t/Library/Caches/com.apple.spotlight/x`' '冲突应列出该路径'

expect_contains "$REPORT" '| `node` | 1 |' 'node/x 应进「多出」'
expect_contains "$REPORT" '| `xcode` | 1 |' 'DerivedData 应进「多出」'
expect_absent "$REPORT" '| `homebrew` |' 'command 行不参与逐条比对'
expect_absent "$REPORT" '`/Users/t/.npm/_cacache/x`' '多出清单里只放路径列，不带反引号包整行'
expect_contains "$REPORT" '/Users/t/.npm/_cacache/x' '多出样例应列出具体路径'

# ---------- 读不到的父目录要标成「可能是假缺口」 ----------
mkdir -p "$TMPD/blocked"
: > "$TMPD/blocked/kept.bin"
chmod 000 "$TMPD/blocked"
cat > "$TMPD/mole2.txt" <<EOF
=== System ===
$TMPD/blocked/kept.bin  # 1.0MB
EOF
: > "$TMPD/ours2.tsv"
printf '#code\tdecision\tkind\tpath\treason\tsize_kb\tsudo\n' > "$TMPD/ours2.tsv"
"$ORACLE" --ours "$TMPD/ours2.tsv" --mole "$TMPD/mole2.txt" --out "$TMPD/report2.md" > /dev/null 2>&1
expect_contains "$TMPD/report2.md" '本进程读不到' '父目录列不出来时应标为可能的假缺口'
expect_contains "$TMPD/report2.md" '真实可审约 0 条' '假缺口不计入「真实可审」'
chmod 755 "$TMPD/blocked"

# ---------- 边界 ----------
"$ORACLE" --ours "$OURS" --mole "$TMPD/nope.txt" > "$TMPD/missing.out" 2>&1
[[ "$?" -eq 1 ]] && ok '缺 Mole 清单应 exit 1' || bad '缺 Mole 清单应 exit 1'
expect_contains "$TMPD/missing.out" 'mo clean --dry-run' '缺 Mole 清单时给出终端命令'

"$ORACLE" --help > /dev/null 2>&1
[[ "$?" -eq 0 ]] && ok '--help 应 exit 0' || bad '--help 应 exit 0'

"$ORACLE" > /dev/null 2>&1
[[ "$?" -eq 2 ]] && ok '不给输入应 exit 2' || bad '不给输入应 exit 2'

"$ORACLE" --ours "$OURS" --mole "$MOLE" --limit abc > /dev/null 2>&1
[[ "$?" -eq 2 ]] && ok '--limit 非整数应 exit 2' || bad '--limit 非整数应 exit 2'

printf '\n断言 %s 条：失败 %s 条\n' "$ASSERTS" "$FAILS"
[[ "$FAILS" -eq 0 ]] && { printf '全部通过\n'; exit 0; }
printf 'FAIL\n'
exit 1
