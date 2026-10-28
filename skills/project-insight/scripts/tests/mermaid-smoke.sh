#!/usr/bin/env bash
# mermaid-smoke.sh —— check-mermaid.mjs 回归冒烟（临时目录，不落任何 fixture 到本仓库）。
#
# 用法：bash skills/project-insight/scripts/tests/mermaid-smoke.sh
# 覆盖：
#   1) 最简 flowchart 通过（parse+render）
#   2) 【关键回归】带标签的边（graph 与 flowchart 两种声明）都能渲染 —— 曾经的假错误
#      "Could not find a suitable point for the given distance" 来自 SVG 测量垫片返回 0，
#      不是图本身的问题；本用例守住垫片不被改回去。
#   3) 菱形判断 + 带标签边
#   4) 子图 + 回边
#   5) 【反向】真语法错误必须报 MERMAID-ERROR、退出 1
#   6) 【反向】子图父链成环（render 布局期错误）必须报 MERMAID-ERROR、退出 1
#   7) sequenceDiagram 只走 parse（不因 render 环境报错）
#   8) <br/> 非规范写法给 MERMAID-WARN 但不阻断（退出 0）
# 退出码：0 = 全部通过；1 = 有断言失败。
set -u

CM="$(cd "$(dirname "$0")/.." && pwd)/check-mermaid.mjs"
T="$(mktemp -d "${TMPDIR:-/tmp}/pi-mermaid.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0

assert() { # assert <描述> <期望子串> <实际输出>
  if grep -qF "$2" <<<"$3"; then echo "  PASS $1"; else echo "  FAIL $1（期望含：$2）"; echo "$3" | sed 's/^/    | /'; fail=1; fi
}
assert_not() { # assert_not <描述> <不应出现的子串> <实际输出>
  if grep -qF "$2" <<<"$3"; then echo "  FAIL $1（不应出现：$2）"; echo "$3" | sed 's/^/    | /'; fail=1; else echo "  PASS $1"; fi
}
assert_exit() { # assert_exit <描述> <期望码> <实际码>
  if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1（期望退出码 $2，实际 $3）"; fail=1; fi
}

mk() { printf '%s\n' "$2" >"$T/$1"; }

mk simple.md '```mermaid
flowchart TD
    A --> B
```'

# 关键回归：带标签的边
mk graph-labeled.md '```mermaid
graph TD
    A -->|小于| B
```'
mk flowchart-labeled.md '```mermaid
flowchart TD
    A -->|"resolveExecutable + spawn(pipe)"| B
```'

mk diamond.md '```mermaid
flowchart TD
    A{x} -->|y| B
    A -->|z| C
```'

mk subgraph-backedge.md '```mermaid
flowchart TB
    subgraph S["外层"]
      A --> B
    end
    B -.->|回边| A
```'

mk syntax-error.md '```mermaid
flowchart TD
    A -->|未闭合 B
```'

mk cycle.md '```mermaid
flowchart TD
    subgraph A
    subgraph A
      B --> C
    end
    end
```'

mk sequence.md '```mermaid
sequenceDiagram
    participant A
    participant B
    A->>B: hello
    B-->>A: world
```'

mk br-warn.md '```mermaid
flowchart TD
    A["第一行<br/>第二行"] --> B
```'

echo "1) 最简 flowchart 渲染通过（exit 0）"
out=$(node "$CM" "$T/simple.md"); code=$?
assert "OK (parse+render)" "OK  (parse+render)" "$out"
assert_exit "退出码 0" 0 "$code"

echo "2) 关键回归：带标签的边（graph / flowchart 两种声明）都能渲染"
out=$(node "$CM" "$T/graph-labeled.md" "$T/flowchart-labeled.md"); code=$?
assert "graph 声明的带标签边 OK" "graph-labeled.md:1-4" "$out"
assert "flowchart 声明的带标签边 OK" "flowchart-labeled.md:1-4" "$out"
assert_not "不得出现测量类假错误" "Could not find a suitable point" "$out"
assert_exit "退出码 0" 0 "$code"

echo "3) 菱形判断 + 带标签边"
out=$(node "$CM" "$T/diamond.md"); code=$?
assert "OK (parse+render)" "OK  (parse+render)" "$out"
assert_exit "退出码 0" 0 "$code"

echo "4) 子图 + 回边"
out=$(node "$CM" "$T/subgraph-backedge.md"); code=$?
assert "OK (parse+render)" "OK  (parse+render)" "$out"
assert_exit "退出码 0" 0 "$code"

echo "5) 【反向】真语法错误必须失败（exit 1）"
out=$(node "$CM" "$T/syntax-error.md"); code=$?
assert "MERMAID-ERROR" "[MERMAID-ERROR]" "$out"
assert_exit "退出码 1" 1 "$code"

echo "6) 【反向】子图父链成环必须失败（exit 1，布局期错误）"
out=$(node "$CM" "$T/cycle.md"); code=$?
assert "MERMAID-ERROR" "[MERMAID-ERROR]" "$out"
assert "报出成环原因" "would create a cycle" "$out"
assert_exit "退出码 1" 1 "$code"

echo "7) sequenceDiagram 只走 parse"
out=$(node "$CM" "$T/sequence.md"); code=$?
assert "OK (parse) 而非 parse+render" "OK  (parse)" "$out"
assert_exit "退出码 0" 0 "$code"

echo "8) <br/> 非规范写法给 WARN 但不阻断（exit 0）"
out=$(node "$CM" "$T/br-warn.md"); code=$?
assert "给出 MERMAID-WARN" "[MERMAID-WARN]" "$out"
assert_exit "退出码 0" 0 "$code"

if [ "$fail" -eq 0 ]; then echo; echo "全部通过"; else echo; echo "有断言失败"; fi
exit "$fail"
