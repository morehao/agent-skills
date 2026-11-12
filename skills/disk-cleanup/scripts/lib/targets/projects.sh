#!/usr/bin/env bash
# targets: projects 组（projects / dshtmp / projectcache）
# 约定（与其它 target 文件一致）：
#   target_<id>()  只读测量：算 total/del、打印明细、设置 STEP_* 与 PLAN_CMD，最后调 run
#   clean_<id>()   执行：只能用 lib/safety.sh 的漏斗原语，不得直接删
#
# v2 相对 v1 新增的三条判据（本文件的核心，别退回到「只看目录自身 mtime」）：
#   ① 树内活跃度：目录 mtime 超阈值 **且** tree_active <dir> <days> 为假，才进可删清单。
#      构建产物目录的 mtime 停在上次生成时间，长期在改的项目会被误判「30 天没动」。
#   ② git 追踪保护：删 dist/build 这类产物前，若目录在 git 工作树内、且该路径下
#      `git ls-files` 非空（有被跟踪文件），跳过并注明「含被 git 跟踪的文件」。
#   ③ 嵌套仓库保护：待删目录自己含 .git（它是别人的仓库根 / submodule / worktree）→ 跳过，
#      删它等于删别人的版本历史。
# 保守方向：stat / git / find 超时或读不到 → 一律跳过，不进可删清单（宁可漏清，不可误删）。
[[ -n "${_DC_T_PROJECTS_LOADED:-}" ]] && return 0
_DC_T_PROJECTS_LOADED=1

# 候选下限（与 v1 一致：太小的条目只是噪音）
PROJ_MIN_KB=51200      # projects / projectcache：< 50MB 不进清单
DSHTMP_MIN_KB=10240    # dshtmp：< 10MB 不进清单

# 构建产物目录名（v1 集合，行为等价；v2 只加判据，不改范围）
PROJ_NAMES=(-name node_modules -o -name .next -o -name .turbo -o -name .parcel-cache
            -o -name .venv -o -name venv -o -name __pycache__ -o -name target
            -o -name dist -o -name build -o -name Pods)
# 项目内编译缓存目录名
PROJCACHE_NAMES=(-name .gocache -o -name .tmp-gocache -o -name .pnpm-store
                 -o -name .corepack -o -path '*/.dsh/gocache')

# ---------------- 共用小工具 ----------------
# proj_age_days <dir> <now_epoch>：目录自身 mtime 距今多少天；读不到输出空
# （读不到 ≠ 很旧：调用方必须按「跳过」处理）
proj_age_days() {
    local d="${1:-}" now="${2:-0}" m age
    [[ -n "$d" && -d "$d" ]] || return 0
    m=$(run_timeout "$DC_TIMEOUT_QUICK" stat -f '%m' "$d" 2>/dev/null) || return 0
    case "${m:-}" in ''|*[!0-9]*) return 0 ;; esac
    age=$(( (now - m) / 86400 ))
    [[ "$age" -lt 0 ]] && age=0
    printf '%s' "$age"
}

# proj_git_skip_reason <dir>：该跳过的输出原因（空 = 可以删）
# 三态可确定才放行：不在工作树内 → 无保护可言；在工作树内 + 有被跟踪文件 → 跳过。
proj_git_skip_reason() {
    local d="${1:-}" rc=0 inside out
    [[ -n "$d" && -d "$d" ]] || return 0
    # ③ 嵌套仓库：目录自身含 .git（仓库根 / submodule 的 .git 文件 / worktree 都算）
    if [[ -e "$d/.git" ]]; then
        printf '%s' "目录内含 .git（是独立仓库），跳过"
        return 0
    fi
    command -v git >/dev/null 2>&1 || return 0
    # ② 是否在 git 工作树内（stderr 抑制；超时按「跳过」处理）
    inside=$(run_timeout "$DC_TIMEOUT_QUERY" git -C "$d" rev-parse --is-inside-work-tree 2>/dev/null) || rc=$?
    [[ "$rc" -eq 124 ]] && { printf '%s' "git 探测超时，跳过"; return 0; }
    [[ "$inside" == "true" ]] || return 0
    # ls-files 的路径本来就相对 cwd，`-C "$d"` 后直接列即可，不做路径拼接
    # （用 show-prefix 拼相对路径会撞上「路径相对 toplevel、pathspec 相对 cwd」的坑）
    rc=0
    out=$(run_timeout "$DC_TIMEOUT_QUERY" git -C "$d" ls-files 2>/dev/null) || rc=$?
    [[ "$rc" -eq 124 ]] && { printf '%s' "git 探测超时，跳过"; return 0; }
    [[ -n "$out" ]] && { printf '%s' "含被 git 跟踪的文件，跳过"; return 0; }
    return 0
}

# proj_top <sz_kb> <路径显示> <注>：往本次明细表 PROJ_TOP 追加一行（制表符分隔，末尾统一排序）
proj_top() {
    PROJ_TOP="${PROJ_TOP}${1}	$(human "$1")  ${2}  （${3}）"$'\n'
}

# proj_show_top <最大行数>：按大小倒序打印明细
proj_show_top() {
    local n="${1:-12}"
    printf '%s' "$PROJ_TOP" | sort -rn | head -"$n" | while IFS=$'\t' read -r kb nm; do
        [[ -n "${nm:-}" ]] && say "    - ${nm}"
    done
}

# 三个 target 共用同一张明细表，每个 target_* 开头清空
PROJ_TOP=""

# ---------------- projects ----------------
# 项目构建产物：node_modules / dist / build / target / .next 等
PROJ_TOTAL_KB=0
PROJ_DEL_KB=0
PROJ_DEL_LIST=""
PROJ_N=0
PROJ_DEL_N=0
PROJ_SKIP_TREE=0
PROJ_SKIP_GIT=0

clean_projects() {
    local p n=0
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        n=$((n + 1))
        # 只走漏斗：已删 / 保护 / 在用 / 失败的计数由 safety.sh 维护
        dc_delete_one "$p" || true
    done < <(printf '%s\n' "$PROJ_DEL_LIST")
    STEP_NOTE="$(dc_deleted_summary)（候选 ${n} 个）"
    [[ "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

target_projects() {
    local now roots root found d sz age why
    dc_section projects
    PROJ_TOTAL_KB=0; PROJ_DEL_KB=0; PROJ_DEL_LIST=""; PROJ_TOP=""
    PROJ_N=0; PROJ_DEL_N=0; PROJ_SKIP_TREE=0; PROJ_SKIP_GIT=0
    now=$(date +%s)
    say "  扫描根: ${PROJECT_ROOTS}（--projects-roots 可改）"
    say "  只处理 ${PROJECTS_AGE_DAYS} 天前未改动、且树内没有近期改动的构建产物目录"
    roots=$(project_roots_list)
    if [[ -z "$roots" ]]; then
        say "  ⚠️ 扫描根都不存在，跳过"
        STEP_TOTAL_KB=0; STEP_DEL_KB=0
        STEP_REASON="not-found"
        STEP_NOTE="扫描根不存在，未扫描"
        PLAN_CMD="无（扫描根不存在）"
        run projects "清理项目构建产物（构建产物可再生）" clean_projects
        return 0
    fi
    while IFS= read -r root; do
        [[ -d "$root" ]] || continue
        found=$(run_timeout "$DC_TIMEOUT_FIND" find "$root" -maxdepth 6 -type d \
            \( "${PROJ_NAMES[@]}" \) -prune -print 2>/dev/null) || true
        while IFS= read -r d; do
            [[ -n "$d" ]] || continue
            [[ -d "$d" ]] || continue
            sz=$(du_kb "$d")
            [[ "$sz" -ge "$PROJ_MIN_KB" ]] || continue
            PROJ_N=$((PROJ_N + 1))
            PROJ_TOTAL_KB=$((PROJ_TOTAL_KB + sz))
            age=$(proj_age_days "$d" "$now")
            if [[ -z "$age" ]]; then
                # mtime 读不到就不判新旧：绝不进可删清单
                proj_top "$sz" "${d#"$HOME"/}" "mtime 读取失败，跳过"
                continue
            fi
            if keep_matches "$d"; then
                proj_top "$sz" "${d#"$HOME"/}" "保留：--projects-keep"
                continue
            fi
            if [[ "$age" -lt "$PROJECTS_AGE_DAYS" ]]; then
                proj_top "$sz" "${d#"$HOME"/}" "${age} 天内有改动，跳过"
                continue
            fi
            # ① 树内活跃度：目录 mtime 旧 ≠ 项目没在动
            if tree_active "$d" "$PROJECTS_AGE_DAYS"; then
                PROJ_SKIP_TREE=$((PROJ_SKIP_TREE + 1))
                proj_top "$sz" "${d#"$HOME"/}" "目录 ${age} 天未改动，但树内有 ${PROJECTS_AGE_DAYS} 天内改动，跳过"
                continue
            fi
            # ②③ git 追踪 / 嵌套仓库
            why=$(proj_git_skip_reason "$d")
            if [[ -n "$why" ]]; then
                PROJ_SKIP_GIT=$((PROJ_SKIP_GIT + 1))
                proj_top "$sz" "${d#"$HOME"/}" "${age} 天未改动，但${why}"
                continue
            fi
            PROJ_DEL_KB=$((PROJ_DEL_KB + sz))
            PROJ_DEL_N=$((PROJ_DEL_N + 1))
            PROJ_DEL_LIST="${PROJ_DEL_LIST}${d}"$'\n'
            proj_top "$sz" "${d#"$HOME"/}" "${age} 天未改动，可删"
        done < <(printf '%s\n' "$found")
    done < <(printf '%s\n' "$roots")
    say "  命中 ${PROJ_N} 个构建产物目录（≥$((PROJ_MIN_KB / 1024)) MB），合计 $(human "$PROJ_TOTAL_KB")；其中可删（≥${PROJECTS_AGE_DAYS} 天未改动且树内无新动静）$(human "$PROJ_DEL_KB")"
    [[ "$PROJ_N" -gt 0 ]] && { say "  最大子项（按可删量）:"; proj_show_top 12; }
    [[ "$PROJ_SKIP_TREE" -gt 0 ]] && say "  ⏭ ${PROJ_SKIP_TREE} 个目录 mtime 虽旧，但树内有 ${PROJECTS_AGE_DAYS} 天内改动（活跃项目默认跳过）"
    [[ "$PROJ_SKIP_GIT" -gt 0 ]] && say "  ⏭ ${PROJ_SKIP_GIT} 个目录含被 git 跟踪的文件或是独立仓库，未计入可删"
    if [[ "$PROJ_N" -gt 12 ]]; then
        say "    …（仅显示最大的 12 项；完整清单用 --json）"
    fi
    say "  注：删除后需重新 npm install / build；活跃项目默认跳过，可用 --projects-age-days 调大或用 --projects-keep 排除。"
    STEP_TOTAL_KB="$PROJ_TOTAL_KB"
    STEP_DEL_KB="$PROJ_DEL_KB"
    STEP_PATH=""
    STEP_SAMPLE=$(printf '%s' "$PROJ_DEL_LIST" | head -5)
    # 口径（lead 定）：树内活跃 / git 跟踪 / 嵌套仓库三种跳过都记 user-kept——
    # 它们是「用户或仓库自己的数据」，不是 data/protect.tsv 命中，所以不进 protected[]。
    if [[ $((PROJ_SKIP_TREE + PROJ_SKIP_GIT)) -gt 0 ]]; then
        STEP_REASON="user-kept"
        STEP_NOTE="活跃跳过 ${PROJ_SKIP_TREE} / git 保护跳过 ${PROJ_SKIP_GIT}（候选 ${PROJ_N}，可删 ${PROJ_DEL_N}）"
    else
        STEP_NOTE="候选 ${PROJ_N} 个，可删 ${PROJ_DEL_N} 个"
    fi
    PLAN_CMD="删除 ${PROJ_DEL_N} 个 ≥${PROJECTS_AGE_DAYS} 天未改动的构建产物目录（$(human "$PROJ_DEL_KB")，走漏斗）"
    run projects "清理项目构建产物（构建产物可再生）" clean_projects
}

# ---------------- dshtmp ----------------
# 项目内 .dsh/tmp 过程产物：只清空内容、保留目录本身（同级 .dsh/docs 不碰）
DSHTMP_TOTAL_KB=0
DSHTMP_DEL_KB=0
DSHTMP_DEL_LIST=""
DSHTMP_N=0
DSHTMP_DEL_N=0
DSHTMP_SKIP_TREE=0

clean_dshtmp() {
    local d p left fails=0 n=0
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        [[ -d "$d" ]] || continue
        n=$((n + 1))
        # 删「目录下的直接子项」，目录本身保留
        while IFS= read -r -d '' p; do
            dc_delete_one "$p" || true
        done < <(run_timeout "$DC_TIMEOUT_FIND" find "$d" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
        # 回读：目录仍在且为空才算成功（低权限残留会被如实计入失败）
        if [[ -d "$d" ]]; then
            left=$(run_timeout "$DC_TIMEOUT_QUICK" find "$d" -mindepth 1 -maxdepth 1 -print 2>/dev/null | head -1) || true
            [[ -n "$left" ]] && fails=$((fails + 1))
        fi
    done < <(printf '%s\n' "$DSHTMP_DEL_LIST")
    STEP_NOTE="$(dc_deleted_summary)（清空 ${n} 个 .dsh/tmp，回读非空 ${fails} 个）"
    [[ "$fails" -eq 0 && "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

target_dshtmp() {
    local now roots root found d sz age
    dc_section dshtmp
    DSHTMP_TOTAL_KB=0; DSHTMP_DEL_KB=0; DSHTMP_DEL_LIST=""; PROJ_TOP=""
    DSHTMP_N=0; DSHTMP_DEL_N=0; DSHTMP_SKIP_TREE=0
    now=$(date +%s)
    say "  扫描根: ${PROJECT_ROOTS}（--projects-roots 可改；只清空内容、保留 .dsh/tmp 目录）"
    roots=$(project_roots_list)
    if [[ -z "$roots" ]]; then
        say "  ⚠️ 扫描根都不存在，跳过"
        STEP_TOTAL_KB=0; STEP_DEL_KB=0
        STEP_REASON="not-found"
        STEP_NOTE="扫描根不存在，未扫描"
        PLAN_CMD="无（扫描根不存在）"
        run dshtmp "清空项目内 .dsh/tmp 过程产物（保留目录）" clean_dshtmp
        return 0
    fi
    while IFS= read -r root; do
        [[ -d "$root" ]] || continue
        found=$(run_timeout "$DC_TIMEOUT_FIND" find "$root" -maxdepth 7 -type d \
            -path '*/.dsh/tmp' -prune -print 2>/dev/null) || true
        while IFS= read -r d; do
            [[ -n "$d" ]] || continue
            [[ -d "$d" ]] || continue
            sz=$(du_kb "$d")
            [[ "$sz" -ge "$DSHTMP_MIN_KB" ]] || continue
            DSHTMP_N=$((DSHTMP_N + 1))
            DSHTMP_TOTAL_KB=$((DSHTMP_TOTAL_KB + sz))
            age=$(proj_age_days "$d" "$now")
            if [[ -z "$age" ]]; then
                proj_top "$sz" "${d#"$HOME"/}" "mtime 读取失败，跳过"
                continue
            fi
            if keep_matches "$d"; then
                proj_top "$sz" "${d#"$HOME"/}" "保留：--projects-keep"
                continue
            fi
            if [[ "$age" -lt "$DSHTMP_AGE_DAYS" ]]; then
                proj_top "$sz" "${d#"$HOME"/}" "${age} 天内有改动，跳过"
                continue
            fi
            # ① 树内活跃度（--dshtmp-age-days 为 0 时恒为假，等于不限制）
            if tree_active "$d" "$DSHTMP_AGE_DAYS"; then
                DSHTMP_SKIP_TREE=$((DSHTMP_SKIP_TREE + 1))
                proj_top "$sz" "${d#"$HOME"/}" "目录 ${age} 天未改动，但树内有 ${DSHTMP_AGE_DAYS} 天内改动，跳过"
                continue
            fi
            DSHTMP_DEL_KB=$((DSHTMP_DEL_KB + sz))
            DSHTMP_DEL_N=$((DSHTMP_DEL_N + 1))
            DSHTMP_DEL_LIST="${DSHTMP_DEL_LIST}${d}"$'\n'
            proj_top "$sz" "${d#"$HOME"/}" "${age} 天未改动，可清空"
        done < <(printf '%s\n' "$found")
    done < <(printf '%s\n' "$roots")
    say "  命中 ${DSHTMP_N} 个 .dsh/tmp（≥$((DSHTMP_MIN_KB / 1024)) MB），合计 $(human "$DSHTMP_TOTAL_KB")；其中可清空（≥${DSHTMP_AGE_DAYS} 天，0=全部）$(human "$DSHTMP_DEL_KB")"
    [[ "$DSHTMP_N" -gt 0 ]] && { say "  最大子项:"; proj_show_top 12; }
    [[ "$DSHTMP_SKIP_TREE" -gt 0 ]] && say "  ⏭ ${DSHTMP_SKIP_TREE} 个目录树内有 ${DSHTMP_AGE_DAYS} 天内改动，跳过"
    if [[ "$DSHTMP_N" -gt 12 ]]; then
        say "    …（仅显示最大的 12 项；完整清单用 --json）"
    fi
    say "  注：只清空 */.dsh/tmp 的内容并保留目录本身；不触碰同级 .dsh/docs。"
    STEP_TOTAL_KB="$DSHTMP_TOTAL_KB"
    STEP_DEL_KB="$DSHTMP_DEL_KB"
    STEP_PATH=""
    STEP_SAMPLE=$(printf '%s' "$DSHTMP_DEL_LIST" | head -5)
    if [[ "$DSHTMP_SKIP_TREE" -gt 0 ]]; then
        STEP_REASON="user-kept"
        STEP_NOTE="活跃跳过 ${DSHTMP_SKIP_TREE}（候选 ${DSHTMP_N}，可清空 ${DSHTMP_DEL_N}）"
    else
        STEP_NOTE="候选 ${DSHTMP_N} 个，可清空 ${DSHTMP_DEL_N} 个"
    fi
    PLAN_CMD="清空 ${DSHTMP_DEL_N} 个 .dsh/tmp 的内容并保留目录（$(human "$DSHTMP_DEL_KB")，走漏斗）"
    run dshtmp "清空项目内 .dsh/tmp 过程产物（保留目录）" clean_dshtmp
}

# ---------------- projectcache ----------------
# 项目内编译缓存：.gocache / .tmp-gocache / .dsh/gocache / .pnpm-store / .corepack
PROJCACHE_TOTAL_KB=0
PROJCACHE_DEL_KB=0
PROJCACHE_DEL_LIST=""
PROJCACHE_N=0
PROJCACHE_DEL_N=0
PROJCACHE_SKIP_TREE=0

clean_projectcache() {
    local p n=0
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        n=$((n + 1))
        dc_delete_one "$p" || true
    done < <(printf '%s\n' "$PROJCACHE_DEL_LIST")
    STEP_NOTE="$(dc_deleted_summary)（候选 ${n} 个）"
    [[ "$DC_DEL_FAILS" -eq 0 && "$DC_DEL_TIMEOUT" -eq 0 ]]
}

target_projectcache() {
    local now roots root found d sz age
    dc_section projectcache
    PROJCACHE_TOTAL_KB=0; PROJCACHE_DEL_KB=0; PROJCACHE_DEL_LIST=""; PROJ_TOP=""
    PROJCACHE_N=0; PROJCACHE_DEL_N=0; PROJCACHE_SKIP_TREE=0
    now=$(date +%s)
    say "  扫描根: ${PROJECT_ROOTS}（--projects-roots 可改；整目录删，只处理 ${PROJECTCACHE_AGE_DAYS} 天前未改动的目录）"
    roots=$(project_roots_list)
    if [[ -z "$roots" ]]; then
        say "  ⚠️ 扫描根都不存在，跳过"
        STEP_TOTAL_KB=0; STEP_DEL_KB=0
        STEP_REASON="not-found"
        STEP_NOTE="扫描根不存在，未扫描"
        PLAN_CMD="无（扫描根不存在）"
        run projectcache "清理项目内编译缓存（可再生成）" clean_projectcache
        return 0
    fi
    while IFS= read -r root; do
        [[ -d "$root" ]] || continue
        found=$(run_timeout "$DC_TIMEOUT_FIND" find "$root" -maxdepth 7 -type d \
            \( "${PROJCACHE_NAMES[@]}" \) -prune -print 2>/dev/null) || true
        while IFS= read -r d; do
            [[ -n "$d" ]] || continue
            [[ -d "$d" ]] || continue
            sz=$(du_kb "$d")
            [[ "$sz" -ge "$PROJ_MIN_KB" ]] || continue
            PROJCACHE_N=$((PROJCACHE_N + 1))
            PROJCACHE_TOTAL_KB=$((PROJCACHE_TOTAL_KB + sz))
            age=$(proj_age_days "$d" "$now")
            if [[ -z "$age" ]]; then
                proj_top "$sz" "${d#"$HOME"/}" "mtime 读取失败，跳过"
                continue
            fi
            if keep_matches "$d"; then
                proj_top "$sz" "${d#"$HOME"/}" "保留：--projects-keep"
                continue
            fi
            if [[ "$age" -lt "$PROJECTCACHE_AGE_DAYS" ]]; then
                proj_top "$sz" "${d#"$HOME"/}" "${age} 天内有改动，跳过"
                continue
            fi
            # ① 树内活跃度：缓存可能刚被一次构建写入（mtime 却是旧的）
            if tree_active "$d" "$PROJECTCACHE_AGE_DAYS"; then
                PROJCACHE_SKIP_TREE=$((PROJCACHE_SKIP_TREE + 1))
                proj_top "$sz" "${d#"$HOME"/}" "目录 ${age} 天未改动，但树内有 ${PROJECTCACHE_AGE_DAYS} 天内改动，跳过"
                continue
            fi
            PROJCACHE_DEL_KB=$((PROJCACHE_DEL_KB + sz))
            PROJCACHE_DEL_N=$((PROJCACHE_DEL_N + 1))
            PROJCACHE_DEL_LIST="${PROJCACHE_DEL_LIST}${d}"$'\n'
            proj_top "$sz" "${d#"$HOME"/}" "${age} 天未改动，可删"
        done < <(printf '%s\n' "$found")
    done < <(printf '%s\n' "$roots")
    say "  命中 ${PROJCACHE_N} 个编译缓存目录（≥$((PROJ_MIN_KB / 1024)) MB），合计 $(human "$PROJCACHE_TOTAL_KB")；其中可删（≥${PROJECTCACHE_AGE_DAYS} 天未改动且树内无新动静）$(human "$PROJCACHE_DEL_KB")"
    [[ "$PROJCACHE_N" -gt 0 ]] && { say "  最大子项（按可删量）:"; proj_show_top 12; }
    [[ "$PROJCACHE_SKIP_TREE" -gt 0 ]] && say "  ⏭ ${PROJCACHE_SKIP_TREE} 个目录树内有 ${PROJECTCACHE_AGE_DAYS} 天内改动，跳过"
    if [[ "$PROJCACHE_N" -gt 12 ]]; then
        say "    …（仅显示最大的 12 项；完整清单用 --json）"
    fi
    say "  注：删除后下次构建 / install 需要重跑；.gocache 等只读目录由漏斗逐条处理。"
    STEP_TOTAL_KB="$PROJCACHE_TOTAL_KB"
    STEP_DEL_KB="$PROJCACHE_DEL_KB"
    STEP_PATH=""
    STEP_SAMPLE=$(printf '%s' "$PROJCACHE_DEL_LIST" | head -5)
    if [[ "$PROJCACHE_SKIP_TREE" -gt 0 ]]; then
        STEP_REASON="user-kept"
        STEP_NOTE="活跃跳过 ${PROJCACHE_SKIP_TREE}（候选 ${PROJCACHE_N}，可删 ${PROJCACHE_DEL_N}）"
    else
        STEP_NOTE="候选 ${PROJCACHE_N} 个，可删 ${PROJCACHE_DEL_N} 个"
    fi
    PLAN_CMD="删除 ${PROJCACHE_DEL_N} 个 ≥${PROJECTCACHE_AGE_DAYS} 天未改动的项目编译缓存目录（$(human "$PROJCACHE_DEL_KB")，走漏斗）"
    run projectcache "清理项目内编译缓存（可再生成）" clean_projectcache
}
