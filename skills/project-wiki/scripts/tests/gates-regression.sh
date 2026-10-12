#!/usr/bin/env bash
# gates-regression.sh —— project-wiki 门禁回归测试
#
# 用法：bash scripts/tests/gates-regression.sh
#
# 为什么需要它：本 skill 的门禁全是"拦住坏文档"，而**门禁失效是静默的**——
# 校验器一旦漏检（正则不认某种写法、路径跳过检查），坏文档照样"通过"，
# 没有任何迹象。所以每条门禁都必须有一个"故意违规、必须被拦住"的夹具。
#
# 覆盖：代码预算（含豁免）、引用真实性（缺失/越界/乱序/越界根/无法解析/未传源码根）、
#       校验痕迹、行内引用密度、标题数字前缀、首页索引（漏列/悬空）、
#       图表（节点复杂度/未声明参与者）、篇幅、以及合规夹具应全绿。
#
# 退出码：0 = 全部门禁按预期工作；1 = 有断言失败。

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK_DOCS="$(cd -- "$HERE/.." && pwd)/check-docs.mjs"
CHECK_ALL="$(cd -- "$HERE/.." && pwd)/check-all.mjs"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SRC="$TMP/src-repo"
mkdir -p "$SRC/internal/gateway" "$SRC/cmd/server"
printf 'package gateway\n\nfunc Route() {}\nfunc Mw() {}\n' > "$SRC/internal/gateway/router.go"
printf 'package gateway\n\nfunc Auth() {}\n' > "$SRC/internal/gateway/middleware.go"
printf '# Demo\n' > "$SRC/README.md"
# 动态路由目录名（Next.js 风格）带方括号：这类真实路径必须能被引用解析支持，
# 否则整类项目（Next.js / Nuxt / SvelteKit）的引用都验不了，只能退化成"认不出"。
mkdir -p "$SRC/src/app/[owner]/[repo]"
printf 'export default function Page() {\n  return null;\n}\n' > "$SRC/src/app/[owner]/[repo]/page.tsx"
printf 'secret\n' > "$TMP/outside.txt"

PASS=0
FAIL=0

# assert_exit <期望退出码> <说明> <目录> [额外参数...]
assert_exit() {
  local want="$1"; shift
  local desc="$1"; shift
  local dir="$1"; shift
  node "$CHECK_DOCS" "$dir" "$@" >"$TMP/out.txt" 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
    printf '  ok   %s（退出码 %s）\n' "$desc" "$got"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s：期望退出码 %s，实际 %s\n' "$desc" "$want" "$got"
    sed 's/^/       /' "$TMP/out.txt"
  fi
}

# assert_report <输出码> <说明> <目录> [额外参数...]
assert_report() {
  local code="$1"; shift
  local desc="$1"; shift
  local dir="$1"; shift
  node "$CHECK_DOCS" "$dir" "$@" >"$TMP/out.txt" 2>&1
  if grep -q "\[$code\]" "$TMP/out.txt"; then
    PASS=$((PASS + 1))
    printf '  ok   %s（报出 %s）\n' "$desc" "$code"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s：未报出 %s\n' "$desc" "$code"
    sed 's/^/       /' "$TMP/out.txt"
  fi
}

# ———————————————————————— 夹具 1：合规文档应全绿 ————————————————————————
GOOD="$TMP/good-wiki"; mkdir -p "$GOOD"
cat > "$GOOD/README.md" <<'EOF'
---
title: Demo 文档
description: 面向使用者的 Demo 文档：概览与架构。
---

# Demo

Demo 是一个示例服务。

**本文档依据**：v1.0.0（abc1234），2026-10-12

## 页面索引

| 页面 | 内容 |
|------|------|
| [topic.md](topic.md) | 主题页 |

## 建议阅读顺序

1. [topic.md](topic.md) —— 先读这个

## 现状与边界

暂不支持水平扩展。
EOF
cat > "$GOOD/topic.md" <<'EOF'
---
title: 主题页
description: 验证合规页面能通过全部门禁。
---

# 主题页

## 这一段讲什么

这是一段足够长的散文，用来让正文有效行数超过下限，避免触发篇幅过短的提示。
继续补充说明文字，确保这个夹具是"合规"的而不是靠警告侥幸通过。

## 结构图

下面这张图展示请求的流向，读者应当从中看出网关是唯一的入口。

```mermaid
graph TD
    C[客户端] --> G[网关]
    G --> A[服务 A]
```

网关承担了鉴权与分流两件事，这也是它成为瓶颈的原因。

## 职责划分

| 层 | 职责 | 不负责 |
|----|------|--------|
| 网关 | 鉴权、路由 | 业务逻辑 |
| 服务 | 业务处理 | 登录态 |

再补一段散文把这一页说完整，确保正文行数足够，不再依赖任何警告豁免。

> 依据：`internal/gateway/router.go:1-5`、`internal/gateway/middleware.go:1-4`
EOF

echo "== 夹具 1：合规文档应全绿 =="
assert_exit 0 "合规文档通过" "$GOOD" --source-repo "$SRC"

# ———————————————————————— 夹具 2：各类违规 ————————————————————————
BAD="$TMP/bad-wiki"; mkdir -p "$BAD"
cat > "$BAD/README.md" <<'EOF'
---
title: Bad
description: 故意违规的样例。
---

# Bad

## 页面索引

| 页面 | 内容 |
|------|------|
| [bad.md](bad.md) | 违规样例 |
| [ghost.md](ghost.md) | 不存在的页 |
EOF
cat > "$BAD/bad.md" <<'EOF'
---
title: 违规样例
description: 覆盖全部违规类型的夹具页面。
---

# 违规样例

```go
func a() {}
```

```go
func b() {}
```

```go
func c() {}
```

```go
func d() {}
```

## 引用造假

结论一（`internal/gateway/nope.go:1-10`）。
结论二（`internal/gateway/router.go:900-950`）。
结论三（`internal/gateway/router.go:50-10`）。
结论四（`../outside.txt:1`）。
结论五（`internal/gateway/router.go:1`）。
结论六（`internal/gateway/router.go:2`）。
结论七（`internal/gateway/router.go:3`）。

## 校验痕迹

<!-- anchor: package gateway ... func Mw() {} -->

Sources: [internal/gateway/router.go:1-5]()

## 1. 数字前缀标题

正文。
EOF
# 未列出页：真实存在但首页索引没提
cat > "$BAD/forgotten.md" <<'EOF'
---
title: 被遗忘的页
description: 存在但没有出现在首页索引里。
---

# 被遗忘的页

一段足够长的散文用于占位，继续补充文字以避免触发篇幅警告，这里再写一些内容凑够行数。
加上这一行以后，希望只有"未列出"这一条被报出，其它检查都应当通过。

```mermaid
graph TD
    A[一] --> B[二]
```

结尾再补一句话，让正文显得完整一些。
EOF

echo
echo "== 夹具 2：违规必须被拦住 =="
assert_exit 1 "违规文档整体不通过" "$BAD" --source-repo "$SRC"
assert_report DOC-CODE-HEAVY "代码块数超预算" "$BAD" --source-repo "$SRC"
assert_report DOC-SRC-MISSING "引用路径不存在" "$BAD" --source-repo "$SRC"
assert_report DOC-SRC-ORANGE "行号越界" "$BAD" --source-repo "$SRC"
assert_report DOC-SRC-RANGE "区间首末无序" "$BAD" --source-repo "$SRC"
assert_report DOC-SRC-TRAVERSAL "引用越出源码根" "$BAD" --source-repo "$SRC"
assert_report DOC-TRACE "正文有校验痕迹" "$BAD" --source-repo "$SRC"
assert_report DOC-INLINE-REFS "行内引用超密度" "$BAD" --source-repo "$SRC"
assert_report DOC-HEADING-NUM "标题数字前缀" "$BAD" --source-repo "$SRC"
assert_report DOC-INDEX-DANGLING "首页链接悬空" "$BAD" --source-repo "$SRC"
assert_report DOC-INDEX-UNLISTED "页面未在首页列出" "$BAD" --source-repo "$SRC"

# ———————————————————————— 夹具 3：反静默（认不出也必须说） ————————————————————————
QUIRK="$TMP/quirk-wiki"; mkdir -p "$QUIRK"
cat > "$QUIRK/README.md" <<'EOF'
---
title: 写法变体
description: 引用写法不规范时必须被说出来，而不是静默跳过。
---

# 写法变体

## 页面索引

| 页面 | 内容 |
|------|------|
| [quirk.md](quirk.md) | 写法变体 |
EOF
cat > "$QUIRK/quirk.md" <<'EOF'
---
title: 写法变体
description: 引用写法不规范时必须被报出，而不是静默跳过。
---

# 写法变体

## 换一种写法

这一段把说明文字写进了 code span（`见 some/dir/file.go:10`），整段内容不是一个合法引用，
校验器无法解析，应当明确告知"认不出"，而不是当作没有引用悄悄跳过。
这里继续补充散文，让页面不至于因为篇幅过短而被额外报错，保持本夹具的单一意图。

还有一种情况是行号写成了中文冒号（`internal/gateway/router.go：1`），同样无法解析。

## 结构图

```mermaid
graph TD
    A[一] --> B[二]
```

结尾再补一句散文，让这一页的正文长度跨过下限，避免触发与本次断言无关的警告。
EOF

echo
echo "== 夹具 3：反静默机制 =="
assert_report DOC-SRC-UNPARSED "无法解析的引用被明确报出" "$QUIRK" --source-repo "$SRC"
assert_report DOC-SRC-UNCHECKED "未传 --source-repo 时不静默放过" "$GOOD"
# 写法变体（全角冒号 / #L 锚点式行号）应被归一化后照常校验，而不是被跳过：
# 归一化错了会报 MISSING，被跳过则什么都不报——两种都算失败。
VARIANT="$TMP/variant-wiki"; mkdir -p "$VARIANT"
cp "$GOOD/README.md" "$VARIANT/README.md"
cat > "$VARIANT/variant.md" <<'EOF'
---
title: 写法变体归一化
description: 全角冒号与 #L 锚点式行号应被归一化后照常校验。
---

# 写法变体归一化

## 全角冒号

这里的引用用了全角冒号（`internal/gateway/router.go：1`），归一化之后应当照常校验通过。
继续补充散文，让这一页的正文长度跨过下限，避免无关的篇幅警告干扰本次断言。

## 锚点式行号

这里用了 GitHub 风格的锚点行号（`internal/gateway/router.go#L2`），同样应当被归一化。
再补一段散文，把这一页说完整，确保夹具聚焦在"归一化是否正确"这一件事上。

## 结构图

```mermaid
graph TD
    A[一] --> B[二]
```

结尾一句散文。
EOF
node "$CHECK_DOCS" "$VARIANT" --source-repo "$SRC" >"$TMP/out.txt" 2>&1
if grep -qE 'DOC-SRC-(MISSING|UNPARSED)' "$TMP/out.txt"; then
  FAIL=$((FAIL + 1)); printf '  FAIL 写法变体未被正确归一化\n'; sed 's/^/       /' "$TMP/out.txt"
else
  PASS=$((PASS + 1)); printf '  ok   写法变体（全角冒号 / #L 锚点）已归一化并照常校验\n'
fi

# ———————————————————————— 夹具 4：预算豁免与图表检查 ————————————————————————
FIG="$TMP/fig-wiki"; mkdir -p "$FIG"
cp "$GOOD/README.md" "$FIG/README.md"
cat > "$FIG/figs.md" <<'EOF'
---
title: 图表夹具
description: 验证节点复杂度与未声明参与者会被提示。
---

# 图表夹具

## 超复杂流程图

```mermaid
graph TD
    n1[A1] --> n2[A2]
    n2 --> n3[A3]
    n3 --> n4[A4]
    n4 --> n5[A5]
    n5 --> n6[A6]
    n6 --> n7[A7]
    n7 --> n8[A8]
    n8 --> n9[A9]
    n9 --> n10[A10]
    n10 --> n11[A11]
    n11 --> n12[A12]
    n12 --> n13[A13]
```

## 未声明参与者

```mermaid
sequenceDiagram
    C->>G: 请求
    G-->>C: 响应
```

## 代码豁免

<!-- code-budget: 协议头部字段顺序本身就是设计载体，无法用散文替代 -->

```text
a
b
c
d
e
f
g
h
i
j
k
l
m
n
o
p
```

这一页还剩下一些说明文字，用来把正文填充到不至于触发篇幅警告的长度，继续写下去。

结尾再补一句，保持夹具干净。
EOF

echo
echo "== 夹具 4：图表与预算豁免 =="
assert_report DOC-FIGURE-COMPLEX "节点数超阈值被提示改 SVG" "$FIG" --source-repo "$SRC"
assert_report DOC-FIGURE-PARTICIPANT "时序图未声明参与者被提示" "$FIG" --source-repo "$SRC"
# 豁免生效：16 行的代码块不再报 CODE-LONG
node "$CHECK_DOCS" "$FIG" --source-repo "$SRC" >"$TMP/out.txt" 2>&1 || true
if grep -q 'DOC-CODE-LONG' "$TMP/out.txt"; then
  FAIL=$((FAIL + 1)); printf '  FAIL 代码预算豁免未生效（仍报 DOC-CODE-LONG）\n'
else
  PASS=$((PASS + 1)); printf '  ok   code-budget 豁免生效\n'
fi

echo
echo "== 夹具 5：解析器缺口 =="

# 5.1 目标不存在必须判失败。
# 曾经这里的失败信号被末尾那句「未发现问题 → exitCode = 0」覆盖掉，
# 于是"目标写错了"会显示成"检查通过"——正是本 skill 最反对的静默放过。
node "$CHECK_DOCS" "$TMP/no-such-dir" >"$TMP/out.txt" 2>&1
got=$?
if [ "$got" = "2" ] && grep -q 'DOC-TARGET-MISSING' "$TMP/out.txt"; then
  PASS=$((PASS + 1)); printf '  ok   目标不存在时判失败（退出码 2）\n'
else
  FAIL=$((FAIL + 1)); printf '  FAIL 目标不存在却未判失败：退出码 %s\n' "$got"
fi

# 5.2 依据折成多行仍算依据。续行若被算成正文里的行内引用，长依据列表必然误报 INLINE-REFS。
BASIS="$TMP/basis-wiki"; mkdir -p "$BASIS"
cat > "$BASIS/README.md" <<'EOF'
---
title: 依据折行
description: 依据写成多行引用块时，续行也必须算作依据。
---

# 依据折行

## 页面索引

| 页面 | 内容 |
|------|------|
| [basis.md](basis.md) | 依据折行 |
EOF
cat > "$BASIS/basis.md" <<'EOF'
---
title: 依据折行
description: 依据写成多行引用块时，续行也必须算作依据，而不是被当成正文里的行内引用。
---

# 依据折行

## 一段说明

这里放一段与断言无关的散文，让页面正文长度跨过下限，避免触发篇幅警告而干扰本夹具的单一意图。
这段文字本身不包含任何引用写法，引用全部集中在文末那一块依据里，正是本夹具要验证的形态。

## 结构图

```mermaid
graph TD
    A[一] --> B[二]
```

末尾补一句，确保正文行数达标。

> 依据：`internal/gateway/router.go:1-4`、`internal/gateway/middleware.go:1-3`、
> `internal/gateway/router.go:2`、`internal/gateway/router.go:3`、`internal/gateway/router.go:4`、
> `internal/gateway/middleware.go:1`、`internal/gateway/middleware.go:2`、`internal/gateway/middleware.go:3`
EOF
node "$CHECK_DOCS" "$BASIS" --source-repo "$SRC" >"$TMP/out.txt" 2>&1
if grep -q 'DOC-INLINE-REFS' "$TMP/out.txt"; then
  FAIL=$((FAIL + 1)); printf '  FAIL 依据折行被误判成正文行内引用\n'
else
  PASS=$((PASS + 1)); printf '  ok   依据折行仍算依据（不误报 INLINE-REFS）\n'
fi

# 5.3 带方括号的动态路由路径：既要能解析（不报 UNPARSED），又必须真的去校验（不存在要报 MISSING）。
BRACKET="$TMP/bracket-wiki"; mkdir -p "$BRACKET"
cat > "$BRACKET/README.md" <<'EOF'
---
title: 方括号路径
description: 动态路由路径必须可解析、且真的被校验。
---

# 方括号路径

## 页面索引

| 页面 | 内容 |
|------|------|
| [bracket.md](bracket.md) | 方括号路径 |
EOF
cat > "$BRACKET/bracket.md" <<'EOF'
---
title: 方括号路径
description: 动态路由路径必须可解析、且真的被校验，不能既验不了又不吭声。
---

# 方括号路径

## 一段说明

这里放一段与断言无关的散文，让页面正文长度跨过下限，避免触发篇幅警告干扰本夹具的判断。
路径里带方括号是 Next.js 之类框架的目录命名方式，属于真实存在的路径形态。

## 结构图

```mermaid
graph TD
    A[一] --> B[二]
```

末尾补一句，确保正文行数达标，引用收在下面这一行。

> 依据：`src/app/[owner]/[repo]/page.tsx:1-3`、`src/app/[owner]/[nope]/page.tsx:1`
EOF
node "$CHECK_DOCS" "$BRACKET" --source-repo "$SRC" >"$TMP/out.txt" 2>&1
if grep -q 'DOC-SRC-UNPARSED' "$TMP/out.txt"; then
  FAIL=$((FAIL + 1)); printf '  FAIL 方括号路径被当成无法解析\n'
else
  PASS=$((PASS + 1)); printf '  ok   方括号路径可解析\n'
fi
if grep -q 'DOC-SRC-MISSING' "$TMP/out.txt"; then
  PASS=$((PASS + 1)); printf '  ok   方括号路径确实被校验（不存在的报 MISSING）\n'
else
  FAIL=$((FAIL + 1)); printf '  FAIL 方括号路径解析了却没被校验\n'
fi

# 5.4 check-all 必须把位置参数绝对化后再交给子进程。
# 它拉起的 check-docs 以本脚本目录为 cwd，相对路径直接透传会让自研门禁一个文件都收不到
# （表现为 [DOC-TARGET-MISSING] + "文件 0 个"），门禁整体空转却还显示"检查过"。
got=0
( cd "$TMP" && node "$CHECK_ALL" good-wiki --source-repo "$SRC" ) >"$TMP/out-all.txt" 2>&1 || got=$?
if [ "$got" = "0" ] && ! grep -q 'DOC-TARGET-MISSING' "$TMP/out-all.txt"; then
  PASS=$((PASS + 1)); printf '  ok   check-all 传相对路径时自研门禁真的跑到了文件\n'
else
  FAIL=$((FAIL + 1)); printf '  FAIL check-all 相对路径下自研门禁空转（退出码 %s）\n' "$got"
fi

echo
echo "回归结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "全部门禁按预期工作。"
