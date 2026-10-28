#!/usr/bin/env bash
# references-smoke.sh —— verify-references.mjs 回归冒烟（临时目录，不落任何 fixture 到本仓库）。
#
# 用法：bash scripts/tests/references-smoke.sh
# 覆盖：零引用合法（exit 0）/ 锚点验证通过 / 缺文件 UNVERIFIED（exit 1）/ 行号偏移 MISMATCH（exit 1）/
#       路径穿越 TRAVERSAL（exit 2）/ --stats 密度与单段多引用报告 / 围栏代码块内引用不计入统计 /
#       已补真实链接的引用仍被校验 / anchor-base64 双锚 / 引用与指纹之间夹说明行不错位 /
#       （反向）夹说明行但锚点真错位仍判 MISMATCH。
# 退出码：0 = 全部通过；1 = 有断言失败。

set -u
VR="$(cd "$(dirname "$0")/.." && pwd)/verify-references.mjs"
T="$(mktemp -d "${TMPDIR:-/tmp}/pi-refs.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0

assert() { # assert <描述> <期望子串> <实际输出>
  if grep -qF "$2" <<<"$3"; then echo "  PASS $1"; else echo "  FAIL $1（期望含：$2）"; echo "$3" | sed 's/^/    | /'; fail=1; fi
}
assert_exit() { # assert_exit <描述> <期望码> <实际码>
  if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1（期望退出码 $2，实际 $3）"; fail=1; fi
}

mkdir -p "$T/repo/pkg"
printf 'package util\n// add two ints\nfunc Add(a, b int) int {\n\treturn a + b\n}\n' >"$T/repo/pkg/util.go"

printf '# 测试\n\n纯叙述，没有引用。\n' >"$T/zero.md"
printf '# 测试\n\n一句结论 [pkg/util.go:1-2]()\n<!-- anchor: package util … // add two ints -->\n' >"$T/ok.md"
printf '# 测试\n\n坏路径 [nope/missing.go:1-2]()\n' >"$T/missing.md"
printf '# 测试\n\n越界 [../outside.go:1-2]()\n' >"$T/traversal.md"
printf '# 测试\n\n锚点错位 [pkg/util.go:3-4]()\n<!-- anchor: package util … // add two ints -->\n' >"$T/mismatch.md"
printf '# 测试\n\n结论一 [pkg/util.go:1-1]()，结论二 [pkg/util.go:3-3]()，挤在同一段。\n' >"$T/dense.md"
printf '# 测试\n\n```md\n示例 [pkg/util.go:1-2]() 写在代码块里\n```\n\n正文没有引用。\n' >"$T/fenced.md"

# B1：已补真实链接的引用（括号内是 URL，不是空括号）——必须仍被校验，不得当作"无引用"放过
printf '# 测试\n\n带链接 [pkg/util.go:1-2](https://example.com/repo/blob/main/pkg/util.go#L1-L2)\n<!-- anchor: package util … // add two ints -->\n' >"$T/linked.md"
# B1 反向：带链接但锚点错位，仍要 MISMATCH
printf '# 测试\n\n带链接错位 [pkg/util.go:3-4](https://example.com/repo/blob/main/pkg/util.go#L3-L4)\n<!-- anchor: package util … // add two ints -->\n' >"$T/linked-bad.md"
# B2：anchor-base64 双锚（首 … 末，两段各自 base64）
FIRST_B64=$(printf 'package util' | base64)
LAST_B64=$(printf '// add two ints' | base64)
printf '# 测试\n\n双锚 [pkg/util.go:1-2]()\n<!-- anchor-base64:%s … %s -->\n' "$FIRST_B64" "$LAST_B64" >"$T/dual-anchor.md"
# B3：引用与指纹之间夹一行说明，不应错位
printf '# 测试\n\n结论一 [pkg/util.go:1-2]()\n这里是夹在中间的一行说明文字。\n<!-- anchor: package util … // add two ints -->\n' >"$T/interleaved.md"
# B3 反向：夹说明行 + 锚点真错位，仍要 MISMATCH（证明没把门禁调松）
printf '# 测试\n\n结论一 [pkg/util.go:3-4]()\n这里是夹在中间的一行说明文字。\n<!-- anchor: package util … // add two ints -->\n' >"$T/interleaved-bad.md"

echo "1) 零引用合法（exit 0）"
out=$(node "$VR" "$T/repo" "$T/zero.md"); code=$?
assert "打印无引用（允许）" "无引用（允许）" "$out"
assert_exit "退出码 0" 0 "$code"

echo "2) 锚点验证通过"
out=$(node "$VR" "$T/repo" "$T/ok.md"); code=$?
assert "GROUNDER-OK" "[GROUNDER-OK]" "$out"
assert_exit "退出码 0" 0 "$code"

echo "3) 缺文件 UNVERIFIED（exit 1）"
out=$(node "$VR" "$T/repo" "$T/missing.md"); code=$?
assert "GROUNDER-UNVERIFIED" "[GROUNDER-UNVERIFIED]" "$out"
assert_exit "退出码 1" 1 "$code"

echo "4) 路径穿越 TRAVERSAL（exit 2）"
out=$(node "$VR" "$T/repo" "$T/traversal.md"); code=$?
assert "GROUNDER-TRAVERSAL" "[GROUNDER-TRAVERSAL]" "$out"
assert_exit "退出码 2" 2 "$code"

echo "5) 锚点错位 MISMATCH（exit 1）"
out=$(node "$VR" "$T/repo" "$T/mismatch.md"); code=$?
assert "GROUNDER-MISMATCH" "[GROUNDER-MISMATCH]" "$out"
assert_exit "退出码 1" 1 "$code"

echo "6) --stats 报告密度与单段多引用（exit 0）"
out=$(node "$VR" --stats "$T/dense.md" "$T/zero.md"); code=$?
assert "单段多引用 1 段" "单段多引用 1 段" "$out"
assert "零引用篇目" "引用 0 处" "$out"
assert_exit "退出码 0" 0 "$code"

echo "8) 已补真实链接的引用仍被校验（不得当作无引用放过）"
out=$(node "$VR" "$T/repo" "$T/linked.md"); code=$?
assert "GROUNDER-OK" "[GROUNDER-OK]" "$out"
assert_exit "退出码 0" 0 "$code"

echo "9) 已补真实链接 + 锚点错位 → 仍 MISMATCH（退出码 1）"
out=$(node "$VR" "$T/repo" "$T/linked-bad.md"); code=$?
assert "GROUNDER-MISMATCH" "[GROUNDER-MISMATCH]" "$out"
assert_exit "退出码 1" 1 "$code"

echo "10) anchor-base64 双锚（首 … 末）"
out=$(node "$VR" "$T/repo" "$T/dual-anchor.md"); code=$?
assert "GROUNDER-OK" "[GROUNDER-OK]" "$out"
assert_exit "退出码 0" 0 "$code"

echo "11) 引用与指纹之间夹一行说明 → 不错位"
out=$(node "$VR" "$T/repo" "$T/interleaved.md"); code=$?
assert "GROUNDER-OK" "[GROUNDER-OK]" "$out"
assert_exit "退出码 0" 0 "$code"

echo "12) 夹说明行 + 锚点真错位 → 仍 MISMATCH（不调松门禁）"
out=$(node "$VR" "$T/repo" "$T/interleaved-bad.md"); code=$?
assert "GROUNDER-MISMATCH" "[GROUNDER-MISMATCH]" "$out"
assert_exit "退出码 1" 1 "$code"

echo "7) --stats 忽略围栏代码块内的引用"
out=$(node "$VR" --stats "$T/fenced.md")
assert "代码块内引用不计" "引用 0 处" "$out"

if [ "$fail" -eq 0 ]; then echo; echo "全部通过"; else echo; echo "有断言失败"; fi
exit "$fail"
