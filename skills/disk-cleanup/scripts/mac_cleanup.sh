#!/usr/bin/env bash
# ============================================
# disk-cleanup v2（macOS）：先测量 → 用户勾选 → 才删除
#
# 设计要点（与 v1 的差别）：
#   - 编码唯一事实源是 data/codes.tsv；本脚本与文档都由它派生
#   - 所有删除经 lib/safety.sh 的单一漏斗：路径断言 + 保护清单 + 在用检测 + 超时 + 审计
#   - 每个动作落一行 append-only 台账，`--history` 可回放
#   - --dry-run 必须配 --clean；单独使用是用法错误（不再静默降级成查询）
#
# 常用：
#   bash ... --list                          # 看编码
#   bash ...                                 # 只查询占用（默认，不删）
#   bash ... --clean --dry-run --only caches,logs   # 预览
#   bash ... --clean --only caches,logs      # 执行勾选项
#   bash ... --history [--limit 50] [--json] # 回放台账
#   bash ... --top 10                        # 只看最占空间
#   bash ... --orphans-list                  # 只看已卸载 App 残留（只报告）
# 退出码：0 正常 / 1 有 partial|failed / 2 用法或校验错误
# ============================================

set -uo pipefail

DC_SCRIPT_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/timeout.sh
. "$DC_SCRIPT_DIR/lib/timeout.sh"
# shellcheck source=lib/core.sh
. "$DC_SCRIPT_DIR/lib/core.sh"
# shellcheck source=lib/probe.sh
. "$DC_SCRIPT_DIR/lib/probe.sh"
# shellcheck source=lib/safety.sh
. "$DC_SCRIPT_DIR/lib/safety.sh"
# shellcheck source=lib/audit.sh
. "$DC_SCRIPT_DIR/lib/audit.sh"
# shellcheck source=lib/report.sh
. "$DC_SCRIPT_DIR/lib/report.sh"
# 目标实现：每个编码一个 target_<id>，按需拆分到 lib/targets/*.sh
for _dc_f in "$DC_SCRIPT_DIR"/lib/targets/*.sh; do
    [[ -f "$_dc_f" ]] || continue
    # shellcheck disable=SC1090
    . "$_dc_f"
done
unset _dc_f

# 编码与保护清单是运行前提，先于任何 $HOME 拼接断言
dc_env_assert
dc_codes_load || exit 2
dc_groups_load
dc_protect_load

# ---------- 默认值 ----------
CLEAN=0
DRY_RUN=0
JSON=0
LIST=0
ALL=0
HISTORY=0
HISTORY_LIMIT=50
TOP_N=0
ONLY_RAW=""
SKIP_RAW=""
SHOW_GROUPS=0
CACHE_AGE_DAYS=1
LOG_AGE_DAYS=7
SYSTEMLOG_AGE_DAYS=7
PROJECTS_AGE_DAYS=30
DSHTMP_AGE_DAYS=0
PROJECTCACHE_AGE_DAYS=3
HALFDL_AGE_DAYS=30
INSTALLER_AGE_DAYS=30
PROJECT_ROOTS="${PROJECT_ROOTS:-$HOME/Documents}"
PROJECTS_KEEP_LIST=()
ORPHANS_AGE_DAYS=30
ORPHANS_DELETE_LIST=""
ORPHANS_NEED_SUDO=0
ORPHANS_LIST_ALL=0
ORPHANS_MAX=15
ORPHAN_CANDIDATE_PATHS=()
ESTIMATED_FREED_KB=0
HAD_FAILURE=0
FAILED_COUNT=0
SANDBOX_SUSPECT=0
SUDO_OK=0
ONLY_IDS=""
SKIP_IDS=""
UNSELECTED_IDS=""
LAST_RUN_SELECTED=1
STEP_TOTAL_KB=0
STEP_DEL_KB=0
STEP_NOTE=""
STEP_REASON=""
STEP_PATH=""
STEP_SAMPLE=""
PLAN_CMD=""
REPORT_STEPS=()
SKIPPED_STEPS=()
JSON_ITEMS=()
JSON_CODE_IDS=()
JSON_CODE_STATUSES=()
JSON_CODE_TOTALS=()
JSON_CODE_DELS=()
REPORT_JSON=""
REPORT_SEP=""
DISK_FREE_BEFORE_KB=0
DISK_FREE_AFTER_KB=0
DF_DELTA_KB=0
FREED_KB=0
FINAL_EXIT=0

usage() {
    cat >&2 <<'EOF'
用法: mac_cleanup.sh [模式] [选项]

模式（默认只查询，不删任何东西）:
  --list                 列出清理项编码与说明（--list --json 为机器可读版）
  --history              回放清理台账（默认最近 50 条）
  --top [N]              只读：$HOME 下最大的 N 个目录与 >100MB 文件（默认 10）
  --orphans-list         只读：显示全部疑似卸载残留（默认只显示最大的 15 项）
  （无参数）              只查询各项目前占用
  --clean --only <ids>   执行勾选的清理项
  --clean --all          执行全部（只建议用户本人终端使用）

选项:
  --only <ids>           逗号分隔编码（也可用场景组名）；--only=caches 亦可
  --group <names>        场景组：system/devcaches/ios/nodejs/project-artifacts/ai-agents/containers
  --groups               列出全部场景组（与 --list 一起看更完整）
  --skip <ids>           从选择里排除
  --dry-run              必须与 --clean 同用：只打印计划，不删
  --json                 stdout 只输出 JSON（进度走 stderr）
  --limit <N>            --history 的条数（默认 50）
  --orphans-delete <路径> 按用户点名删除某条残留（可多次）
  --orphans-age-days <N> 残留判定「多少天无改动」（默认 30）
  --projects-roots <路径> 项目产物扫描根（默认 ~/Documents）
  --projects-keep <路径>  保留某个项目（可多次）
  --projects-age-days <N> 项目产物年龄阈值（默认 30）
  --projectcache-age-days <N> 项目编译缓存阈值（默认 3）
  --dshtmp-age-days <N>   .dsh/tmp 阈值（默认 0 = 全部可删）
  --cache-age-days <N>    用户缓存阈值（默认 1）
  --log-age-days <N>      用户日志阈值（默认 7）
  -h, --help             本帮助

退出码: 0 正常 / 1 有 partial|failed / 2 用法或校验错误
EOF
}

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean) CLEAN=1; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        --json) JSON=1; shift ;;
        --all) ALL=1; shift ;;
        --only)
            if [[ $# -lt 2 ]]; then printf '%s\n' '--only 需要一个逗号分隔的编码列表\n' >&2; exit 2; fi
            ONLY_RAW="${ONLY_RAW:+${ONLY_RAW},}${2}"; shift 2 ;;
        --only=*) ONLY_RAW="${ONLY_RAW:+${ONLY_RAW},}${1#--only=}"; shift ;;
        --group)
            if [[ $# -lt 2 ]]; then printf '%s\n' '--group 需要一个场景组名（多个用逗号）' >&2; exit 2; fi
            ONLY_RAW="${ONLY_RAW:+${ONLY_RAW},}${2}"; shift 2 ;;
        --group=*) ONLY_RAW="${ONLY_RAW:+${ONLY_RAW},}${1#--group=}"; shift ;;
        --groups) SHOW_GROUPS=1; shift ;;
        --skip)
            if [[ $# -lt 2 ]]; then printf '%s\n' '--skip 需要一个逗号分隔的编码列表\n' >&2; exit 2; fi
            SKIP_RAW="${SKIP_RAW:+${SKIP_RAW},}${2}"; shift 2 ;;
        --skip=*) SKIP_RAW="${SKIP_RAW:+${SKIP_RAW},}${1#--skip=}"; shift ;;
        --history) HISTORY=1; shift ;;
        --limit)
            if [[ $# -lt 2 ]] || ! is_pos_int "$2"; then printf '%s\n' '--limit 需要一个非负整数\n' >&2; exit 2; fi
            HISTORY_LIMIT="$2"; shift 2 ;;
        --limit=*) HISTORY_LIMIT="${1#--limit=}"; is_pos_int "$HISTORY_LIMIT" || { printf '%s\n' '--limit 需要整数\n' >&2; exit 2; }; shift ;;
        --cache-age-days|--log-age-days|--projects-age-days|--dshtmp-age-days|--projectcache-age-days|--orphans-age-days)
            if [[ $# -lt 2 ]] || ! is_pos_int "$2"; then printf '%s 需要一个非负整数天数\n' "$1" >&2; exit 2; fi
            case "$1" in
                --cache-age-days) CACHE_AGE_DAYS="$2" ;;
                --log-age-days) LOG_AGE_DAYS="$2" ;;
                --projects-age-days) PROJECTS_AGE_DAYS="$2" ;;
                --dshtmp-age-days) DSHTMP_AGE_DAYS="$2" ;;
                --projectcache-age-days) PROJECTCACHE_AGE_DAYS="$2" ;;
                --orphans-age-days) ORPHANS_AGE_DAYS="$2" ;;
            esac
            shift 2 ;;
        --cache-age-days=*|--log-age-days=*|--projects-age-days=*|--dshtmp-age-days=*|--projectcache-age-days=*|--orphans-age-days=*)
            _age_val="${1#*=}"; _age_flag="${1%%=*}"
            is_pos_int "$_age_val" || { printf '%s 需要一个非负整数天数\n' "$_age_flag" >&2; exit 2; }
            case "$_age_flag" in
                --cache-age-days) CACHE_AGE_DAYS="$_age_val" ;;
                --log-age-days) LOG_AGE_DAYS="$_age_val" ;;
                --projects-age-days) PROJECTS_AGE_DAYS="$_age_val" ;;
                --dshtmp-age-days) DSHTMP_AGE_DAYS="$_age_val" ;;
                --projectcache-age-days) PROJECTCACHE_AGE_DAYS="$_age_val" ;;
                --orphans-age-days) ORPHANS_AGE_DAYS="$_age_val" ;;
            esac
            shift ;;
        --projects-roots)
            if [[ $# -lt 2 ]]; then printf '%s\n' '--projects-roots 需要一个路径\n' >&2; exit 2; fi
            PROJECT_ROOTS="$2"; shift 2 ;;
        --projects-keep)
            if [[ $# -lt 2 ]]; then printf '%s\n' '--projects-keep 需要一个路径\n' >&2; exit 2; fi
            PROJECTS_KEEP_LIST+=("$(resolve_path "$2")"); shift 2 ;;
        --top)
            TOP_N=10
            if [[ $# -ge 2 ]] && is_pos_int "$2"; then TOP_N="$2"; shift; fi
            shift ;;
        --top=*) TOP_N="${1#--top=}"; is_pos_int "$TOP_N" || { printf '%s\n' '--top 需要整数\n' >&2; exit 2; }; shift ;;
        --orphans-list) ORPHANS_LIST_ALL=1; shift ;;
        --orphans-delete)
            if [[ $# -lt 2 ]]; then printf '%s\n' '--orphans-delete 需要一个绝对路径\n' >&2; exit 2; fi
            ORPHANS_DELETE_LIST="${ORPHANS_DELETE_LIST}${2}"$'\n'; shift 2 ;;
        --orphans-delete=*) ORPHANS_DELETE_LIST="${ORPHANS_DELETE_LIST}${1#--orphans-delete=}"$'\n'; shift ;;
        --list) LIST=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            printf '未知参数: %s\n' "$1" >&2
            usage
            exit 2 ;;
    esac
done

if [[ "$SHOW_GROUPS" == "1" && "$LIST" != "1" ]]; then
    say "场景组（--group <名> 等价于把这些编码一起交给 --only）："
    dc_group_list
    exit 0
fi

if [[ "$LIST" == "1" ]]; then
    if [[ "$JSON" == "1" ]]; then
        list_items_json
    else
        list_items
        say ""
        say "场景组（--group <名>）："
        dc_group_list
    fi
    exit 0
fi

# 单独 --dry-run 是用法错误：v1 会静默降级成查询，agent 会误以为「已经预览过」
if [[ "$DRY_RUN" == "1" && "$CLEAN" != "1" ]]; then
    printf '%s\n' '--dry-run 必须与 --clean 同用（例：--clean --dry-run --only caches）\n' >&2
    exit 2
fi
if [[ "$CLEAN" == "1" && "$DRY_RUN" != "1" && -z "$ONLY_RAW" && -z "$SKIP_RAW" && "$ALL" != "1" ]]; then
    printf '⚠️ --clean 未指定 --only/--skip 时必须显式加 --all（防止误清全部）。\n' >&2
    printf '   给用户勾选场景请传 --only <ids>；确实要全清请在用户终端跑 --clean --all。\n' >&2
    exit 2
fi

# 把场景组名展开成编码（编码优先：组名不得与编码同名，加载时已校验）
expand_groups() {
    local raw="$1" out="" tok codes
    local OLD_IFS="$IFS"
    IFS=','
    for tok in $raw; do
        tok=$(printf '%s' "$tok" | tr -d '[:space:]')
        [[ -n "$tok" ]] || continue
        if codes=$(dc_group_codes "$tok"); then
            out="${out}${out:+,}${codes}"
        else
            out="${out}${out:+,}${tok}"
        fi
    done
    IFS="$OLD_IFS"
    printf '%s' "$out"
}

_unknown_group=""
_old_ifs="$IFS"; IFS=','
for _tok in $ONLY_RAW; do
    _tok=$(printf '%s' "$_tok" | tr -d '[:space:]')
    [[ -n "$_tok" ]] || continue
    case " $KNOWN_IDS " in *" $_tok "*) continue ;; esac
    dc_group_codes "$_tok" >/dev/null && continue
    _unknown_group="$_tok"
done
IFS="$_old_ifs"
if [[ -n "$_unknown_group" ]]; then
    printf '未知清理项或场景组: %s\n' "$_unknown_group" >&2
    printf '可用编码: %s\n' "$KNOWN_IDS" >&2
    printf '可用场景组（--groups 查看）\n' >&2
    exit 2
fi
ONLY_RAW=$(expand_groups "$ONLY_RAW")

validate_ids "$ONLY_RAW" "--only"
validate_ids "$SKIP_RAW" "--skip"

ONLY_NORM=$(normalize_ids "$ONLY_RAW")
SKIP_NORM=$(normalize_ids "$SKIP_RAW")
[[ -n "$ONLY_NORM" ]] && ONLY_IDS=",${ONLY_NORM},"
[[ -n "$SKIP_NORM" ]] && SKIP_IDS=",${SKIP_NORM},"

# 残留删除的路径结构校验（不依赖扫描）
if [[ -n "$ORPHANS_DELETE_LIST" ]] && declare -F dc_orphans_prevalidate >/dev/null 2>&1; then
    dc_orphans_prevalidate || exit 1
fi

dc_audit_init "mode=${CLEAN:+clean}${CLEAN:-query} only=${ONLY_NORM:-*} skip=${SKIP_NORM:-*} dry=${DRY_RUN}"

if [[ "$HISTORY" == "1" ]]; then
    if [[ "$JSON" == "1" ]]; then dc_history_json "$HISTORY_LIMIT"; else dc_history_text "$HISTORY_LIMIT"; fi
    exit 0
fi

# 输出分流说明（--json 时全部走 stderr）
if [[ "$CLEAN" != "1" ]]; then
    say "当前为【查询模式】：仅统计占用，不删除任何内容。"
    say "如需实际清理：$0 --clean --only <勾选的编码>（先加 --dry-run 预览）"
    say ""
fi

if [[ "$CLEAN" == "1" ]]; then
    if [[ -n "$ONLY_IDS" ]]; then
        say "已选择清理项: $ONLY_NORM"
        [[ -n "$SKIP_IDS" ]] && say "其中排除: $SKIP_NORM"
    elif [[ -n "$SKIP_IDS" ]]; then
        say "已选择清理项: 全部，排除 $SKIP_NORM"
    else
        say "已选择清理项: 全部（--all）"
    fi
    say ""
fi

# 预取 sudo（仅真正执行且所选里有 sudo 编码时）
if [[ "$CLEAN" == "1" && "$DRY_RUN" != "1" && -n "$ONLY_IDS$( [[ "$ALL" == "1" ]] && echo all )" ]]; then
    NEED_SUDO=0
    _i=0
    while [[ "$_i" -lt "$DC_CODE_COUNT" ]]; do
        _id="${DC_CODE_IDS[$_i]}"
        if [[ "${DC_CODE_SUDOS[$_i]}" == "1" ]] && want "$_id"; then NEED_SUDO=1; fi
        _i=$((_i + 1))
    done
    # orphans 的编码 sudo 位是 0，但 /Library 下的残留删除同样需要提权
    if [[ -n "$ORPHANS_DELETE_LIST" ]] && printf '%s' "$ORPHANS_DELETE_LIST" | grep -q '^/Library/'; then
        NEED_SUDO=1
    fi
    if [[ "$NEED_SUDO" == "1" ]]; then
        if sudo -v 2>/dev/null; then
            SUDO_OK=1
        else
            printf '⚠️ 无法获取 sudo 权限（可能已取消或环境无 TTY）。\n' >&2
            printf '   涉及系统目录/快照的步骤会被跳过；请在用户自己的终端执行对应 --only 命令。\n\n' >&2
        fi
    fi
fi

DISK_FREE_BEFORE_KB=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
DISK_FREE_BEFORE_KB="${DISK_FREE_BEFORE_KB:-0}"

# ---------- 分派 ----------
dc_section() {
    STEP_TOTAL_KB=0; STEP_DEL_KB=0; STEP_NOTE=""; STEP_REASON=""
    STEP_PATH=""; STEP_SAMPLE=""; PLAN_CMD=""
    say ""
    say "----- $(item_label "$1")（${1}）-----"
}

# --top 是独立只读模式
if [[ "$TOP_N" -gt 0 ]]; then
    say "----- \$HOME 下最占空间的 ${TOP_N} 项（只读） -----"
    say "  正在扫描（-xdev 全量遍历，100G+ 的 HOME 可能要几分钟）..."
    say ""
    say "  目录 Top ${TOP_N}:"
    run_timeout 600 du -sk "$HOME"/* 2>/dev/null | sort -rn | head -"$TOP_N" | while read -r kb p; do
        [[ -n "${p:-}" ]] && say "    $(human "$kb")  ${p#"$HOME"/}"
    done
    say ""
    say "  文件 Top ${TOP_N}（>100MB）:"
    run_timeout 600 find "$HOME" -xdev -type f -size +100M -exec du -k {} + 2>/dev/null | sort -rn | head -"$TOP_N" | while read -r kb p; do
        [[ -n "${p:-}" ]] && say "    $(human "$kb")  ${p#"$HOME"/}"
    done
    say ""
    say "  提示：可再生（缓存/构建产物）的走本脚本编码；用户数据（聊天记录、虚拟机镜像、设计稿、iCloud）只报告不代删。"
    exit 0
fi

SCOPE_ACTIVE=0
[[ -n "$ONLY_IDS" || -n "$SKIP_IDS" ]] && SCOPE_ACTIVE=1

_i=0
while [[ "$_i" -lt "$DC_CODE_COUNT" ]]; do
    _id="${DC_CODE_IDS[$_i]}"
    # 限定范围时只跑范围内的编码：查询模式只测它，执行模式也少测一遍无关目录
    if [[ "$SCOPE_ACTIVE" == "1" ]] && ! want "$_id"; then
        _i=$((_i + 1))
        continue
    fi
    # 编码里可能有连字符（xcode-ios），函数名用下划线
    _fn="target_${_id//-/_}"
    if ! declare -F "$_fn" >/dev/null 2>&1; then
        _fn="target_${_id}"
    fi
    if declare -F "$_fn" >/dev/null 2>&1; then
        "$_fn"
    else
        say "   [跳过] ${_id}（本版本未实现）"
    fi
    _i=$((_i + 1))
done

# 回填：没有产生记录的编码补一条「未找到目标」，
# 让 agent 看到「这项查过了」而不是「脚本漏了」。
dc_has_item() {
    local want="$1" it
    [[ ${#JSON_CODE_IDS[@]} -gt 0 ]] || return 1
    for it in "${JSON_CODE_IDS[@]}"; do
        [[ "$it" == "$want" ]] && return 0
    done
    return 1
}

MISSING_IDS=""
_i=0
while [[ "$_i" -lt "$DC_CODE_COUNT" ]]; do
    _id="${DC_CODE_IDS[$_i]}"
    if ! dc_has_item "$_id"; then
        if [[ "$SCOPE_ACTIVE" == "1" ]] && ! want "$_id"; then
            # 范围外的编码：执行模式记「未勾选」，查询模式干脆不列（scope 已说明范围）
            if [[ "$CLEAN" == "1" ]]; then
                STEP_TOTAL_KB=0; STEP_DEL_KB=0
                STEP_NOTE="不在本次范围"; STEP_REASON="unselected"
                json_add "$_id" "$(item_label "$_id")" "skipped-unselected"
                mark_unselected "$_id"
            fi
            _i=$((_i + 1))
            continue
        fi
        STEP_TOTAL_KB=0; STEP_DEL_KB=0
        STEP_NOTE="未找到目标路径"; STEP_REASON="not-found"
        _st="queried"
        if [[ "$CLEAN" == "1" ]]; then
            if [[ "$DRY_RUN" == "1" ]]; then _st="dry-run"; else _st="done"; fi
        fi
        json_add "$_id" "$(item_label "$_id")" "$_st"
        MISSING_IDS="${MISSING_IDS}${MISSING_IDS:+ }${_id}"
    fi
    _i=$((_i + 1))
done
if [[ -n "$MISSING_IDS" ]]; then
    say ""
    say "  未找到目标（已查过，无占用）：${MISSING_IDS}"
fi

# 只报告段（系统级大户）只在「不限定范围」时输出：用户聚焦某个场景时不该被无关大户稀释
if [[ "${SCOPE_ACTIVE:-0}" != "1" ]] && declare -F targets_extras >/dev/null 2>&1; then
    targets_extras
fi

# ---------- 收尾报告 ----------
DISK_FREE_AFTER_KB=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
DISK_FREE_AFTER_KB="${DISK_FREE_AFTER_KB:-0}"
DF_DELTA_KB=$((DISK_FREE_AFTER_KB - DISK_FREE_BEFORE_KB))
FINAL_EXIT=0
[[ "$HAD_FAILURE" == "1" ]] && FINAL_EXIT=1
FREED_KB=0
if [[ "$CLEAN" == "1" && "$DRY_RUN" != "1" ]]; then FREED_KB="$ESTIMATED_FREED_KB"; fi

say ""
say "======================================"
if [[ "$CLEAN" != "1" ]]; then
    say "  清理报告（查询模式，未执行任何清理）"
    say "======================================"
    say "  下一步：把上面的清理项按编码交给用户勾选，再执行"
    say "    $0 --clean --only <勾选的编码>"
    say "  预览所选：加 --dry-run；排除某项：用 --skip <编码>"
elif [[ "$DRY_RUN" == "1" ]]; then
    say "  清理报告（预览，未实际清理）"
    say "======================================"
    say "  确认上列计划命令与勾选一致后，去掉 --dry-run 执行。"
else
    say "  清理报告"
    say "======================================"
    say "  磁盘可用空间：$(human "$DISK_FREE_BEFORE_KB") → $(human "$DISK_FREE_AFTER_KB")"
    say "  各清理项实测可删合计（估算）：约 $(human "$ESTIMATED_FREED_KB")"
    if [[ "$DF_DELTA_KB" -gt 0 ]]; then
        say "  df 差值（含系统自身回收/其它进程写入等噪声）：+$(human "$DF_DELTA_KB")"
    elif [[ "$DF_DELTA_KB" -lt 0 ]]; then
        say "  df 差值（含系统自身回收/其它进程写入等噪声）：-$(human "$((-DF_DELTA_KB))")"
    else
        say "  df 差值（含系统自身回收/其它进程写入等噪声）：0"
    fi
    [[ "$HAD_FAILURE" == "1" ]] && say "  有 ${FAILED_COUNT} 个清理项未完全成功（partial/failed）。"
    say ""
    if [[ ${#REPORT_STEPS[@]} -gt 0 ]]; then
        say "  实际执行的清理项（${#REPORT_STEPS[@]}）："
        for s in "${REPORT_STEPS[@]}"; do say "    ✅ ${s}"; done
    else
        say "  （本次没有实际执行的清理项）"
    fi
    [[ -n "$UNSELECTED_IDS" ]] && { say ""; say "  未勾选（未执行）：$UNSELECTED_IDS"; }
    if [[ ${#SKIPPED_STEPS[@]} -gt 0 ]]; then
        say ""
        say "  已勾选但未完成的清理项（${#SKIPPED_STEPS[@]}）："
        for s in "${SKIPPED_STEPS[@]}"; do say "    ⏭  ${s}"; done
    fi
    say ""
    say "  台账：${DC_AUDIT_LOG}（$0 --history 回放）"
    [[ "${DC_PROBE_UNKNOWN:-0}" == "1" ]] && say "  注意：lsof 不可用，「文件是否在用」未能判定。"
fi
say "======================================"
say ""

if [[ "$JSON" == "1" ]]; then dc_json_emit; fi
exit "$FINAL_EXIT"
