#!/usr/bin/env bash
# 差分 oracle（研发期工具，不进技能包、不是运行时依赖）
#
# 把 Mole 的 dry-run 候选清单和我们自己的候选清单按路径 join，产出三类待审差异：
#   缺口   Mole 会清、我们完全不碰          → 我们的覆盖盲区
#   冲突   我们标了 protected、Mole 会清     → 两边保护口径不一致（安全相关）
#   多出   我们计划删、Mole 不碰             → 我们更激进，需要复核
#
# 只读：只读两个清单文件、只写临时报告；不删任何东西，也不调用 mo。
#
# 用法：
#   scripts/dev/mole-oracle.sh --collect-ours          # 自己跑一次预览再比（推荐）
#   scripts/dev/mole-oracle.sh --ours plan.tsv         # 用已有清单
#   scripts/dev/mole-oracle.sh --collect-ours --only caches,logs --limit 60
#
# 前置：Mole 侧要在**你自己的终端**跑一次 `mo clean --dry-run`
# （它必须写 ~/.config/mole/clean-list.txt，沙箱里会失败）。
#
# 退出码：0 报告已产出 / 1 输入缺失或比对失败 / 2 用法错误

set -uo pipefail

DEV_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -P -- "$DEV_DIR/../.." && pwd -P)
AWK_PROG="$DEV_DIR/mole-oracle.awk"
CLEANUP_SCRIPT="$REPO_ROOT/skills/disk-cleanup/scripts/mac_cleanup.sh"
DEFAULT_MOLE_LIST="${MOLE_CLEAN_LIST:-$HOME/.config/mole/clean-list.txt}"

OURS=""
MOLE="$DEFAULT_MOLE_LIST"
LIMIT=40
OUT=""
COLLECT=0
ONLY=""
COLLECT_NOTE=""

usage() {
    cat >&2 <<'EOF'
用法: mole-oracle.sh [选项]

  --collect-ours          先跑一次我们的预览（--clean --dry-run）再比对
  --ours <清单.tsv>       直接用已有的 manifest（disk-cleanup --manifest 产物）
  --mole <clean-list>     Mole 的候选清单（默认 ~/.config/mole/clean-list.txt）
  --only <ids>            --collect-ours 时限定编码（不给则全量，比较才有意义）
  --limit <N>             每类最多列多少条（默认 40）
  --out <文件.md>         把报告写到文件（默认 stdout）
  -h, --help              本帮助

前置：在你自己的终端跑一次 `mo clean --dry-run`，它会把候选路径写进
      ~/.config/mole/clean-list.txt（沙箱里写不了，所以这一步交给你）。
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --collect-ours) COLLECT=1; shift ;;
        --ours)
            [[ $# -ge 2 ]] || { printf '%s\n' '--ours 需要一个文件路径' >&2; exit 2; }
            OURS="$2"; shift 2 ;;
        --ours=*) OURS="${1#--ours=}"; shift ;;
        --mole)
            [[ $# -ge 2 ]] || { printf '%s\n' '--mole 需要一个文件路径' >&2; exit 2; }
            MOLE="$2"; shift 2 ;;
        --mole=*) MOLE="${1#--mole=}"; shift ;;
        --only)
            [[ $# -ge 2 ]] || { printf '%s\n' '--only 需要编码列表' >&2; exit 2; }
            ONLY="$2"; shift 2 ;;
        --only=*) ONLY="${1#--only=}"; shift ;;
        --limit)
            [[ $# -ge 2 ]] || { printf '%s\n' '--limit 需要整数' >&2; exit 2; }
            LIMIT="$2"; shift 2 ;;
        --limit=*) LIMIT="${1#--limit=}"; shift ;;
        --out)
            [[ $# -ge 2 ]] || { printf '%s\n' '--out 需要一个文件路径' >&2; exit 2; }
            OUT="$2"; shift 2 ;;
        --out=*) OUT="${1#--out=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf '未知参数: %s\n' "$1" >&2; usage; exit 2 ;;
    esac
done

case "$LIMIT" in
    ''|*[!0-9]*) printf '%s\n' '--limit 需要非负整数' >&2; exit 2 ;;
esac

if [[ "$COLLECT" != "1" && -z "$OURS" ]]; then
    printf '%s\n' '要么给 --ours <清单.tsv>，要么加 --collect-ours 现跑一次。' >&2
    usage
    exit 2
fi

# 临时目录：只清自己建的那个前缀
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/mole-oracle.XXXXXX") || { printf '%s\n' '无法创建临时目录' >&2; exit 1; }
cleanup_tmp() {
    case "$TMPD" in
        "${TMPDIR:-/tmp}"/mole-oracle.*|/tmp/mole-oracle.*) rm -rf -- "$TMPD" ;;
        *) printf '警告：临时目录前缀不符，拒绝清理：%s\n' "$TMPD" >&2 ;;
    esac
}
trap cleanup_tmp EXIT
trap 'cleanup_tmp; exit 1' INT TERM

if [[ "$COLLECT" == "1" ]]; then
    [[ -x "$CLEANUP_SCRIPT" || -f "$CLEANUP_SCRIPT" ]] || {
        printf '找不到 disk-cleanup 脚本：%s\n' "$CLEANUP_SCRIPT" >&2
        exit 1
    }
    if ! find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -print -quit >/dev/null 2>&1; then
        printf '提示：当前进程读不到 ~/.Trash（沙箱/TCC）。在我们的清单里，读不到的目录等于「没有候选」，\n' >&2
        printf '      缺口一节会因此出现假阳性。要干净的结果，请在你自己终端跑同一个 --collect-ours。\n' >&2
    fi
    printf '正在跑我们的预览（这一步可能几十秒到几分钟，取决于候选量）...\n' >&2
    rc=0
    if [[ -n "$ONLY" ]]; then
        bash "$CLEANUP_SCRIPT" --clean --dry-run --only "$ONLY" --manifest "$TMPD/ours.tsv" --json \
            > "$TMPD/ours.json" 2> "$TMPD/ours.err" || rc=$?
    else
        bash "$CLEANUP_SCRIPT" --clean --dry-run --all --manifest "$TMPD/ours.tsv" --json \
            > "$TMPD/ours.json" 2> "$TMPD/ours.err" || rc=$?
    fi
    if [[ "$rc" -ne 0 || ! -s "$TMPD/ours.tsv" ]]; then
        printf '我们的预览失败（退出码 %s）。stderr 末尾：\n' "$rc" >&2
        tail -5 "$TMPD/ours.err" >&2
        exit 1
    fi
    OURS="$TMPD/ours.tsv"
    COLLECT_NOTE="本次现跑，清单已随临时目录清理"
fi

if [[ ! -f "$OURS" ]]; then
    printf '找不到我们的候选清单：%s\n' "$OURS" >&2
    exit 1
fi
if [[ ! -f "$MOLE" ]]; then
    cat >&2 <<EOF
找不到 Mole 的候选清单：$MOLE

先在**你自己的终端**跑一次预览（Mole 必须写 ~/.config/mole，沙箱里写不了）：
  mo clean --dry-run

跑完它会把每个候选路径写进 ~/.config/mole/clean-list.txt，再回来执行本命令。
EOF
    exit 1
fi

# 先把三个输出文件建出来：某一类为空时 awk 不会创建它，后面 cat 会报错
: > "$TMPD/gap.tsv"; : > "$TMPD/conflict.tsv"; : > "$TMPD/extra.tsv"

awk -v OURS="$OURS" -v MOLE="$MOLE" \
    -v gap_out="$TMPD/gap.tsv" -v con_out="$TMPD/conflict.tsv" -v ext_out="$TMPD/extra.tsv" \
    -f "$AWK_PROG" "$OURS" "$MOLE" > "$TMPD/stats" 2> "$TMPD/awk.err" || {
    printf '比对失败：\n' >&2
    tail -5 "$TMPD/awk.err" >&2
    exit 1
}

st() { awk -F'\t' -v k="$1" '$1==k{print $2}' "$TMPD/stats"; }

OURS_DEL=$(st ours_delete); OURS_PROT=$(st ours_protected); OURS_CMD=$(st ours_command)
OURS_UNV=$(st ours_unverified); MOLE_N=$(st mole_total); MOLE_UNK=$(st mole_unknown)
GAP_N=$(st gap); GAP_PART=$(st gap_partial); CON_N=$(st conflict); EXT_N=$(st extra)

fmt_kb() {
    awk -v kb="${1:-0}" 'BEGIN{
        if (kb < 0) { print "unknown"; exit }
        if (kb >= 1048576) printf "%.1f GB", kb/1048576
        else if (kb >= 1024) printf "%.0f MB", kb/1024
        else printf "%d KB", kb
    }'
}

sum_kb() {
    awk -F'\t' -v col="${2:-1}" -v flagcol="${3:-0}" '
        ($0 == "") { next }
        { if (flagcol > 0 && $flagcol != 0) next; s += $col }
        END { printf "%d", s + 0 }' "$1"
}

# 缺口逐条探测可见性：我们的扫描器是从父目录往下找的，父目录列不出来就永远看不到。
# 读不到 ≠ 我们不管——沙箱/TCC 下这是假缺口，必须单列出来，不能混进「覆盖盲区」。
GAP_UNREADABLE=0
GAP_READABLE_KB=0
if [[ -s "$TMPD/gap.tsv" ]]; then
    : > "$TMPD/gap2.tsv"
    while IFS=$'\t' read -r kb sec p partial; do
        unreadable=0
        parent_dir=$(dirname -- "$p")
        if ! find "$parent_dir" -mindepth 1 -maxdepth 1 -print -quit >/dev/null 2>&1; then
            unreadable=1
        elif [[ ! -e "$p" ]]; then
            unreadable=1
        fi
        if [[ "$unreadable" == "1" ]]; then
            GAP_UNREADABLE=$((GAP_UNREADABLE + 1))
        elif [[ "$kb" -ge 0 && "${partial:-0}" != "1" ]]; then
            GAP_READABLE_KB=$((GAP_READABLE_KB + kb))
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$kb" "$sec" "$p" "$partial" "$unreadable" >> "$TMPD/gap2.tsv"
    done < "$TMPD/gap.tsv"
    mv -f "$TMPD/gap2.tsv" "$TMPD/gap.tsv"
fi

REPORT="$TMPD/report.md"

{
    printf '# Mole ⇄ disk-cleanup 候选清单差分\n\n'
    printf -- '- 生成：%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf -- '- 我们：`%s`%s（delete %s / protected %s / command %s / unverified %s）\n' \
        "$OURS" "${COLLECT_NOTE:+（${COLLECT_NOTE}）}" \
        "$OURS_DEL" "$OURS_PROT" "$OURS_CMD" "$OURS_UNV"
    printf -- '- Mole：`%s`（%s 条，其中 size unknown %s 条）\n\n' "$MOLE" "$MOLE_N" "$MOLE_UNK"
    printf '每一条都是**待审线索**，不是结论：Mole 认的不等于该删，我们不认的也可能是它过保护。\n\n'

    printf '## 1. 缺口：Mole 会清、我们完全不碰（%s 条，已知合计 %s，其中部分覆盖 %s 条）\n\n' \
        "$GAP_N" "$(fmt_kb "$(sum_kb "$TMPD/gap.tsv" 1 4)")" "$GAP_PART"
    if [[ "$GAP_UNREADABLE" -gt 0 ]]; then
        printf '> ⚠ 其中 %s 条的父目录本进程列不出来（沙箱/TCC），那些是**假缺口**；' "$GAP_UNREADABLE"
        printf '扣掉它们后，真实可审约 %s 条、%s。\n\n' "$((GAP_N - GAP_UNREADABLE))" "$(fmt_kb "$GAP_READABLE_KB")"
    fi
    if [[ "$GAP_N" -eq 0 ]]; then
        printf '无。\n\n'
    else
        printf '| 大小 | 路径 | Mole 分区 | 说明 |\n|---|---|---|---|\n'
        sort -rn -k1,1 "$TMPD/gap.tsv" | head -n "$LIMIT" | while IFS=$'\t' read -r kb sec p partial unreadable; do
            note=""
            [[ "${partial:-0}" == "1" ]] && note="我们只在其中删过部分文件"
            [[ "$kb" -lt 0 ]] && note="${note:+${note}；}大小未知"
            [[ "${unreadable:-0}" == "1" ]] && note="${note:+${note}；}⚠ 本进程读不到（沙箱/TCC，可能是假缺口）"
            printf '| %s | `%s` | %s | %s |\n' "$(fmt_kb "$kb")" "$p" "$sec" "$note"
        done
        [[ "$GAP_N" -gt "$LIMIT" ]] && printf '\n其余 %s 条见文件尾部的原始清单。\n' "$((GAP_N - LIMIT))"
        printf '\n'
    fi

    printf '## 2. 冲突：我们标为 protected、Mole 会清（%s 条）\n\n' "$CON_N"
    if [[ "$CON_N" -eq 0 ]]; then
        printf '无。\n\n'
    else
        printf '这条最值得看——要么 Mole 比我们保守（我们过保护），要么它真的会删掉我们认为删了会坏的东西。\n\n'
        printf '| 大小 | 路径 | 我们的保护原因 | Mole 分区 |\n|---|---|---|---|\n'
        sort -rn -k1,1 "$TMPD/conflict.tsv" | head -n "$LIMIT" | while IFS=$'\t' read -r kb sec p reason partial; do
            printf '| %s | `%s` | %s | %s |\n' "$(fmt_kb "$kb")" "$p" "${reason:-protected}" "$sec"
        done
        printf '\n'
    fi

    printf '## 3. 我们更激进：我们计划删、Mole 不碰（%s 条）\n\n' "$EXT_N"
    if [[ "$EXT_N" -eq 0 ]]; then
        printf '无。\n\n'
    else
        printf '按编码聚合：\n\n'
        printf '| 编码 | 条数 |\n|---|---|\n'
        cut -f1 "$TMPD/extra.tsv" | sort | uniq -c | sort -rn | while read -r n code; do
            printf '| `%s` | %s |\n' "$code" "$n"
        done
        printf '\n按目录聚合（文件级几万条没法看，看目录才判断得了阈值）：\n\n'
        printf '| 条数 | 编码 | 目录 |\n|---|---|---|\n'
        awk -F'\t' '
            { n = split($2, a, "/"); d = ""
              for (i = 2; i < n; i++) d = d "/" a[i]
              k[$1 "\t" d]++ }
            END { for (x in k) printf "%d\t%s\n", k[x], x }' "$TMPD/extra.tsv" \
            | sort -rn | head -n "$LIMIT" | while IFS=$'\t' read -r n code dir; do
                printf '| %s | `%s` | `%s` |\n' "$n" "$code" "$dir"
            done
        printf '\n'
    fi

    printf '## 不可比的部分\n\n'
    printf -- '- 我们这边有 %s 条 `kind=command`（brew / docker / tmutil / simctl / pnpm），无法逐条对齐，已排除。\n' "$OURS_CMD"
    [[ "$MOLE_UNK" -gt 0 ]] && printf -- '- Mole 有 %s 条 `size unknown`，大小按未知处理，不参与合计。\n' "$MOLE_UNK"
    printf -- '- Mole 有它自己的白名单与内置保护（`~/.config/mole/whitelist` + 代码里的规则），我们不读它——所以「我们删、Mole 不碰」里有一部分其实是它在保护。\n'
    printf -- '- 我们标 `unverified` 的 %s 条按「不碰」处理，不计入缺口。\n\n' "$OURS_UNV"

    printf '## 怎么用这份报告\n\n'
    printf '1. 缺口逐条判断：能不能进 `codes.tsv` 的某个编码、还是只该进只报告段；判断不了的写进 `docs/agents/decisions.md`。\n'
    printf '2. 冲突逐条对齐保护判据：是 Mole 过保护，还是我们的 `protect.tsv` 漏了。\n'
    printf '3. 多出项按编码复核阈值：同编码大面积出现，通常是我们阈值更松。\n'
    printf '4. 只改数据和规则，不抄 Mole 的代码或清单（GPL-3.0 对 MIT，见决策记录）。\n'
} > "$REPORT" 2> "$TMPD/render.err"

if [[ ! -s "$REPORT" ]]; then
    printf '报告生成失败：\n' >&2
    cat "$TMPD/render.err" >&2
    exit 1
fi

# 附上原始清单，便于逐条看（放在报告末尾，不干扰前面三节）
{
    printf '\n## 附：原始差异清单（TSV）\n\n### 缺口（大小 KB / 分区 / 路径 / 部分覆盖 / 本进程读不到）\n```\n'
    cat "$TMPD/gap.tsv" 2>/dev/null || true
    printf '```\n\n### 冲突（大小 KB / 分区 / 路径 / 保护原因 / 部分覆盖）\n```\n'
    cat "$TMPD/conflict.tsv" 2>/dev/null || true
    printf '```\n\n### 多出（编码 / 路径，最多 200 条）\n```\n'
    head -n 200 "$TMPD/extra.tsv" 2>/dev/null || true
    [[ $(wc -l < "$TMPD/extra.tsv" 2>/dev/null || printf 0) -gt 200 ]] && printf '...（共 %s 条，已截断）\n' "$EXT_N"
    printf '```\n'
} >> "$REPORT"

if [[ -n "$OUT" ]]; then
    outdir=$(dirname -- "$OUT")
    mkdir -p -- "$outdir" 2>/dev/null || true
    cp -- "$REPORT" "$OUT" || { printf '写入失败：%s\n' "$OUT" >&2; exit 1; }
    printf '报告已写入 %s\n' "$OUT"
    printf '缺口 %s / 冲突 %s / 多出 %s\n' "$GAP_N" "$CON_N" "$EXT_N"
else
    cat "$REPORT"
fi

exit 0
