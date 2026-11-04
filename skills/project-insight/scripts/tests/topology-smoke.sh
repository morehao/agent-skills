#!/usr/bin/env bash
# topology-smoke.sh —— audit-svg-topology.mjs 回归冒烟（临时目录，不落 fixture 到本仓库）。
#
# 用法：bash skills/project-insight/scripts/tests/topology-smoke.sh
# 覆盖：
#   1) diagram-design 风格（无 class 钩子）走几何推断：节点/连线/标签都识别，图例箭头不算连线
#   2) <path> 的 Q（圆角折线）端点解析正确 —— 曾因 CMD_RE 不含 Q 把端点算成乱值
#   3) 图例里的 <line class="edge edge-arrow"> 不当作连线（真连线照样计）
#   4) 【关键回归】解析不到节点时必须 exit 1，不许 0 节点 0 连线判通过（假绿）
#   5) 端点悬空必须 exit 1
#   6) --expect 命中/不符 分别 exit 0 / 1
# 退出码：0 = 全部通过；1 = 有断言失败。
set -u

AU="$(cd "$(dirname "$0")/.." && pwd)/audit-svg-topology.mjs"
T="$(mktemp -d "${TMPDIR:-/tmp}/pi-topology.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0

assert() { # assert <描述> <期望子串> <实际输出>
  if grep -qF "$2" <<<"$3"; then echo "  PASS $1"; else echo "  FAIL $1（期望含：$2）"; echo "$3" | sed 's/^/    | /'; fail=1; fi
}
assert_exit() { # assert_exit <描述> <期望码> <实际码>
  if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1（期望退出码 $2，实际 $3）"; fail=1; fi
}
mk() { printf '%s\n' "$2" >"$T/$1"; }

# 1+2) diagram-design 风格：无 class、rect+text 节点、Q 圆角折线、图例浮动箭头
mk dd-style.svg '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 900 600">
  <defs><marker id="arrow" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto"><polygon points="0 0, 8 3, 0 6" fill="#4f5d75"/></marker></defs>
  <line x1="180" y1="72" x2="300" y2="72" stroke="#4f5d75" marker-end="url(#arrow)"/>
  <path d="M 180,104 H 280 Q 288,104 288,112 V 380 Q 288,388 296,388 H 300" fill="none" stroke="#4f5d75" marker-end="url(#arrow)"/>
  <line x1="600" y1="520" x2="660" y2="520" stroke="#4f5d75" marker-end="url(#arrow)"/>
  <rect x="40" y="40" width="140" height="64" rx="6" fill="#ffffff" stroke="#2d3142"/>
  <text x="110" y="72" font-size="12" text-anchor="middle" fill="#2d3142">A</text>
  <rect x="300" y="40" width="140" height="64" rx="6" fill="#ffffff" stroke="#2d3142"/>
  <text x="370" y="72" font-size="12" text-anchor="middle" fill="#2d3142">B</text>
  <rect x="300" y="356" width="140" height="64" rx="6" fill="#ffffff" stroke="#2d3142"/>
  <text x="370" y="388" font-size="12" text-anchor="middle" fill="#2d3142">C</text>
</svg>'

echo "1) diagram-design 风格（无 class）走推断：节点 3 / 连线 2，图例箭头忽略"
out=$(node "$AU" "$T/dd-style.svg"); code=$?
assert "推断模式" "推断模式" "$out"
assert "节点与连线计数" "节点 3 个 / 连线 2 条" "$out"
assert "标签取自盒内文本" "A -> B" "$out"
assert "图例浮动箭头被忽略" "箭头 1 个按装饰忽略" "$out"
assert_exit "退出码 0" 0 "$code"

echo "2) path 的 Q 圆角折线端点解析正确（回归：CMD_RE 漏 Q 会把端点算成乱值）"
assert "Q 折线终点落在 C，未报悬空" "A -> C" "$out"
if grep -qF "EDGE-DANGLING" <<<"$out"; then echo "  FAIL Q 折线被误判为悬空"; echo "$out" | sed 's/^/    | /'; fail=1; else echo "  PASS 无 EDGE-DANGLING"; fi

# 3) class 风格：真连线 + 图例示例箭头
mk class-style.svg '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 900 600">
  <rect class="node" x="40" y="40" width="140" height="64" fill="#fff" stroke="#333"/>
  <text x="110" y="72" font-size="12">起始</text>
  <rect class="node" x="300" y="40" width="140" height="64" fill="#fff" stroke="#333"/>
  <text x="370" y="72" font-size="12">结果</text>
  <path class="edge edge-arrow" d="M 180,72 H 300" fill="none" stroke="#333"/>
  <line class="edge edge-arrow" x1="600" y1="520" x2="660" y2="520" stroke="#333"/>
</svg>'

echo "3) 图例里的 line.edge 不计入连线，真连线照计"
out=$(node "$AU" "$T/class-style.svg"); code=$?
assert "节点与连线计数" "节点 2 个 / 连线 1 条" "$out"
assert "标签识别" "起始 -> 结果" "$out"
assert "图例示例箭头忽略" "示例箭头 1 个按装饰忽略" "$out"
assert_exit "退出码 0" 0 "$code"

# 4) 无文本矩形 = 无法识别节点 → 必须失败（不许假绿）
mk unparsed.svg '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 300">
  <rect x="40" y="40" width="120" height="60" fill="#fff" stroke="#333"/>
  <path class="edge" d="M 100,100 L 200,200" fill="none" stroke="#333"/>
</svg>'

echo "4) 【关键回归】解析不到节点必须 exit 1（0 节点 0 连线不许判通过）"
out=$(node "$AU" "$T/unparsed.svg" 2>&1); code=$?
assert "报 EDGE-UNPARSED" "[EDGE-UNPARSED]" "$out"
assert_exit "退出码 1" 1 "$code"

# 5) 端点悬空 → exit 1
mk dangling.svg '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 900 600">
  <rect class="node" x="40" y="40" width="140" height="64" fill="#fff" stroke="#333"/>
  <text x="110" y="72" font-size="12">甲</text>
  <rect class="node" x="300" y="40" width="140" height="64" fill="#fff" stroke="#333"/>
  <text x="370" y="72" font-size="12">乙</text>
  <path class="edge" d="M 180,72 H 700" fill="none" stroke="#333"/>
</svg>'

echo "5) 端点悬空必须 exit 1"
out=$(node "$AU" "$T/dangling.svg" 2>&1); code=$?
assert "报 EDGE-DANGLING" "[EDGE-DANGLING]" "$out"
assert_exit "退出码 1" 1 "$code"

# 6) --expect
printf 'A -> B\nA -> C\n' >"$T/expect-ok.txt"
printf 'A -> B\nB -> C\n' >"$T/expect-bad.txt"

echo "6) --expect 命中 exit 0 / 不符 exit 1"
out=$(node "$AU" --expect "$T/expect-ok.txt" "$T/dd-style.svg" 2>&1); code=$?
assert "与期望清单一致" "与期望清单完全一致" "$out"
assert_exit "命中退出码 0" 0 "$code"

out=$(node "$AU" --expect "$T/expect-bad.txt" "$T/dd-style.svg" 2>&1); code=$?
assert "报缺少期望连线" "缺少期望连线" "$out"
assert_exit "不符退出码 1" 1 "$code"

if [ "$fail" -eq 0 ]; then echo; echo "全部通过"; else echo; echo "有断言失败"; fi
exit "$fail"
