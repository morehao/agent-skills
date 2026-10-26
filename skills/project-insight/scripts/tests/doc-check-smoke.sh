#!/usr/bin/env bash
# doc-check-smoke.sh —— check-doc.mjs 回归冒烟（临时目录，不落 fixture 到本仓库）。
#
# 用法：bash scripts/tests/doc-check-smoke.sh
# 覆盖：正常文档通过 / 断链 / SVG 元信息与外链 / 证据路径与行号 / 孤立图提示 / --strict。
# 退出码：0 = 全部通过；1 = 有断言失败。

set -u
DOC="$(cd "$(dirname "$0")/.." && pwd)/check-doc.mjs"
S="$(mktemp -d "${TMPDIR:-/tmp}/pi-doc.XXXXXX")"
trap 'rm -rf "$S"' EXIT
fail=0

assert() { # assert <描述> <期望子串> <实际输出>
  if grep -qF "$2" <<<"$3"; then
    echo "  PASS $1"
  else
    echo "  FAIL ${1}（期望含：${2}）"
    echo "$3" | sed 's/^/    | /'
    fail=1
  fi
}

assert_exit() { # assert_exit <描述> <期望码> <实际码>
  if [ "$2" = "$3" ]; then
    echo "  PASS $1"
  else
    echo "  FAIL ${1}（期望退出码 ${2}，实际 ${3}）"
    fail=1
  fi
}

mkdir -p "$S/src/pkg" "$S/docs/assets"
printf 'func handshake(ctx context.Context) error {\n\treturn nil\n}\n' >"$S/src/pkg/x.go"
printf '<svg viewBox="0 0 10 10" xmlns="http://www.w3.org/2000/svg"><title>t</title><desc>d</desc></svg>\n' >"$S/docs/assets/ok.svg"
printf '<svg width="10" height="10" xmlns="http://www.w3.org/2000/svg"><script>1</script></svg>\n' >"$S/docs/assets/bad.svg"

cat >"$S/docs/good.md" <<'EOF'
# 好文档

## 有正文

这张图展示握手路径。![图](assets/ok.svg)

正文提到 `pkg/x.go:1`，行内示例 `[不是链接](nope.md)` 不应被误判。
EOF
cat >"$S/docs/bad.md" <<'EOF'
# 坏文档

## 断链

见 [不存在](nope.md)。

## 坏图

![图](assets/bad.svg)

## 证据

- [pkg/x.go:1-2](https://example.com/x) — 结论
- [pkg/y.go:1-2]() — 不存在
- [pkg/x.go:3-9]() — 越界
EOF
cat >"$S/docs/figure-only.md" <<'EOF'
# 孤立图

## 只有图

![图](assets/ok.svg)
EOF

echo "1) 正常文档通过，行内链接示例不误判"
out=$(node "$DOC" "$S/docs/good.md" 2>&1); code=$?
assert_exit "退出码 0" 0 "$code"
assert "输出 PASS" "[DOC-PASS]" "$out"

echo "2) 断链 / 坏图 / 证据问题被拦住"
out=$(node "$DOC" --source-repo "$S/src" "$S/docs/bad.md" 2>&1); code=$?
assert_exit "退出码 1" 1 "$code"
assert "发现断链" "[DOC-LINK]" "$out"
assert "发现缺 title" "缺 <title>" "$out"
assert "发现缺 viewBox" "缺固定 viewBox" "$out"
assert "发现外部脚本" "含 <script>" "$out"
assert "发现证据路径不存在" "路径不存在：pkg/y.go" "$out"
assert "发现证据行号越界" "行号越界" "$out"

echo "3) 孤立图是提示，不阻断；--strict 下才失败"
out=$(node "$DOC" "$S/docs/figure-only.md" 2>&1); code=$?
assert_exit "默认退出码 0" 0 "$code"
assert "给出 FIGURE-ONLY 提示" "[DOC-FIGURE-ONLY]" "$out"
out=$(node "$DOC" --strict "$S/docs/figure-only.md" 2>&1); code=$?
assert_exit "--strict 退出码 1" 1 "$code"

echo
[ "$fail" -eq 0 ] && echo "全部通过" || echo "存在失败断言"
exit "$fail"
