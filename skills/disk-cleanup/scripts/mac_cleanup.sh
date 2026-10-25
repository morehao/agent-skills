#!/usr/bin/env bash
# ============================================
# Mac 磁盘清理脚本
# 设计要点：
#   - 默认只查询，不删任何东西；--dry-run 只预览（含计划命令与预计可删量）
#   - 每个清理项有稳定编码（--list 查看），--only / --skip 决定这次到底删哪些
#   - 报告双口径：目录总量 ≠ 本次可删量。只删 mtime 阈值的项会单独实测「可删」子集，
#     避免「报 2.3G、实删 200MB」这种误导
#   - 已知纯缓存目录（浏览器/更新器）整目录清理，不套 mtime 阈值：它们本来就可丢，
#     且浏览器会持续 touch 缓存条目，mtime 过滤在其中几乎无效
#   - 遍历被 TCC/权限拒绝的条目单独计数并写进报告，不当成 0
#   - 保留运行中程序可能占用的活动文件：未知缓存只清 mtime 过期内容
#   - 数量校验与更硬的 shell 选项；sudo 项在无 TTY 环境明确跳过并交出原文命令
# 使用方法（本脚本随 disk-cleanup 技能分发，位于 skills/disk-cleanup/scripts/）：
#   1. 只查询占用（默认，不删任何东西）：bash skills/disk-cleanup/scripts/mac_cleanup.sh
#   2. 查看清理项编码：                 bash ... --list
#   3. 编码 + 说明的机器可读版：        bash ... --list --json
#   4. 预览所选清理项：                 bash ... --clean --dry-run --only caches,logs
#   5. 清理所选（用户勾选后执行）：      bash ... --clean --only caches,logs,trash
#   6. 只看最占空间的对象：             bash ... --top 10
#   7. 全部清理（只建议用户本人在终端手动使用）：bash ... --clean --all
# ============================================

set -uo pipefail

CLEAN=0
DRY_RUN=0
JSON=0
LIST=0
ALL=0
TOP_N=0
ONLY_RAW=""
SKIP_RAW=""
CACHE_AGE_DAYS=1
LOG_AGE_DAYS=7
PROJECTS_AGE_DAYS=30
PROJECT_ROOTS="${PROJECT_ROOTS:-$HOME/Documents}"
PROJECTS_KEEP=""

# 清理项编码：勾选单位。新增清理项时必须同时更新这里、references/cleanup.md 与 SKILL.md 的清单；
# scripts/check-disk-cleanup-codes.mjs 会校验三处是否一致（CI 会跑）。
KNOWN_IDS="caches logs tmp varfolders snapshots trash xcode toolcache bigbuild docker appcache updaters projects"

json_esc() {
  printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'
}

item_label() {
  case "$1" in
    caches)     echo "用户缓存 ~/Library/Caches" ;;
    logs)       echo "用户日志 ~/Library/Logs" ;;
    tmp)        echo "/tmp 临时目录" ;;
    varfolders) echo "/var/folders 当前用户容器残留" ;;
    snapshots)  echo "Time Machine 本地快照" ;;
    trash)      echo "废纸篓" ;;
    xcode)      echo "Xcode DerivedData" ;;
    toolcache)  echo "语言工具链/包管理器缓存" ;;
    bigbuild)   echo "构建大件（ipsw/Homebrew/CocoaPods/Gradle/DeviceSupport/模拟器）" ;;
    docker)     echo "Docker 无用资源" ;;
    appcache)   echo "应用内缓存（Electron/Chromium 型 app）" ;;
    updaters)   echo "应用自动更新残留" ;;
    projects)   echo "项目构建产物（node_modules 等）" ;;
    *)          echo "未知" ;;
  esac
}

item_desc() {
  case "$1" in
    caches)     echo "纯缓存目录整删；其余只删 ${CACHE_AGE_DAYS} 天前未改动内容" ;;
    logs)       echo "只删 ${LOG_AGE_DAYS} 天前的旧日志文件，保留目录结构" ;;
    tmp)        echo "只删 ${CACHE_AGE_DAYS} 天前的陈旧内容" ;;
    varfolders) echo "T/C 清 7 天以上；X 清代码签名残留与 7 天前目录；go-build 清 1 天以上" ;;
    snapshots)  echo "tmutil thinlocalsnapshots（回滚粒度变粗，系统会重建）" ;;
    trash)      echo "清空，清后不可恢复" ;;
    xcode)      echo "整个 DerivedData 删除，下次构建全量重编" ;;
    toolcache)  echo "白名单内可再生缓存 + pnpm store prune（删后重新下载/编译）" ;;
    bigbuild)   echo "ipsw / Homebrew / CocoaPods / Gradle / DeviceSupport / 不可用模拟器" ;;
    docker)     echo "docker system prune -a（镜像需重新 pull；不会缩小 Docker.raw）" ;;
    appcache)   echo "各 app 目录下的 Cache/GPUCache/Code Cache 等，app 会重建" ;;
    updaters)   echo "crx_cache / auto-updater 等更新下载残留" ;;
    projects)   echo "只处理 ${PROJECTS_AGE_DAYS} 天前未改动的构建产物目录（需重新 build）" ;;
    *)          echo "" ;;
  esac
}

is_sudo_id() {
  case "$1" in
    tmp|snapshots) return 0 ;;
    *) return 1 ;;
  esac
}

usage() {
  cat <<EOF
用法: $0 [--clean] [--dry-run] [--only <ids>] [--skip <ids>] [--all] [--top [N]] [--json]

  默认              只查询并输出各目录占用，不删除任何内容
  --clean           执行实际清理
  --dry-run         配合 --clean：只打印计划命令与预计可删量，不实际删除
  --only <ids>      只清理指定项（英文逗号分隔），如 --only caches,logs；可重复传，会合并
  --skip <ids>      排除指定项，如 --skip docker,bigbuild；可重复传，会合并
  --all             显式表示「清理全部项」；不带 --only/--skip 时 --clean 必须配 --all
  --list            列出全部清理项编码与说明后退出（加 --json 输出机器可读版）
  --top [N]         只读：列出 \$HOME 下最占空间的 N 项（目录与 >100MB 文件），默认 10，较慢
  --json            stdout 只输出 JSON（进度信息走 stderr），便于 agent 解析
  --cache-age-days N     caches/tmp 的 mtime 阈值（默认 1）
  --log-age-days N       logs 的 mtime 阈值（默认 7）
  --projects-age-days N  projects 只处理该天数前未改动的构建产物（默认 30）
  --projects-roots <p>   projects 的扫描根（默认 \$HOME/Documents，可用冒号分隔多个）
  --projects-keep <p>    projects 里排除的具体路径（可重复传）

可用编码: $KNOWN_IDS
需 sudo 的项: tmp snapshots（agent 环境会被跳过，命令交给用户自己的终端执行）
EOF
}

list_items() {
  local id
  for id in $KNOWN_IDS; do
    if is_sudo_id "$id"; then
      printf '  %-11s %s\n' "$id" "$(item_label "$id")    [需 sudo]"
    else
      printf '  %-11s %s\n' "$id" "$(item_label "$id")"
    fi
    printf '  %-11s   %s\n' "" "$(item_desc "$id")"
  done
  cat <<EOF

不含在本脚本里的：
  opencode 数据库瘦身：由 disk-cleanup skill 走 cleanup-opencode.sh（先备份、先闭库、再 VACUUM）
  iOS 设备备份、聊天记录、虚拟机镜像等用户数据：只报告大小与路径，不代删
EOF
}

list_items_json() {
  local id sep="" sudo
  printf '{"schema":1,"codes":['
  for id in $KNOWN_IDS; do
    sudo=false
    is_sudo_id "$id" && sudo=true
    printf '%s{"id":"%s","label":"%s","desc":"%s","sudo":%s}' \
      "$sep" "$(json_esc "$id")" "$(json_esc "$(item_label "$id")")" \
      "$(json_esc "$(item_desc "$id")")" "$sudo"
    sep=","
  done
  printf ']}\n'
}

# normalize_ids <raw>：去掉空白与空项，输出逗号分隔列表（无前后逗号）
normalize_ids() {
  local raw="$1" out="" id
  local IFS=','
  for id in $raw; do
    id="${id//[[:space:]]/}"
    [[ -z "$id" ]] && continue
    out="${out}${out:+,}${id}"
  done
  printf '%s' "$out"
}

# validate_ids <raw> <flag>：编码不存在直接失败，避免「以为清了其实没清」
validate_ids() {
  local raw="$1" flag="$2" id
  local IFS=','
  for id in $raw; do
    id="${id//[[:space:]]/}"
    [[ -z "$id" ]] && continue
    case " $KNOWN_IDS " in
      *" $id "*) ;;
      *)
        echo "未知清理项: ${id}（${flag}）；可用编码: $KNOWN_IDS" >&2
        exit 1 ;;
    esac
  done
}

# want <id>：当前选择是否包含该清理项
want() {
  local id="$1"
  if [[ -n "$ONLY_IDS" ]]; then
    case "$ONLY_IDS" in
      *",$id,"*) ;;
      *) return 1 ;;
    esac
  fi
  if [[ -n "$SKIP_IDS" ]]; then
    case "$SKIP_IDS" in
      *",$id,"*) return 1 ;;
    esac
  fi
  return 0
}

# mark_unselected <id>：按编码去重记录「未勾选」的清理项
mark_unselected() {
  case ",$UNSELECTED_IDS," in
    *",$1,"*) ;;
    *) UNSELECTED_IDS="${UNSELECTED_IDS}${UNSELECTED_IDS:+,}$1" ;;
  esac
}

is_pos_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) CLEAN=1; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    --json) JSON=1; shift ;;
    --all) ALL=1; shift ;;
    --only)
      if [[ $# -lt 2 ]]; then echo "--only 需要一个逗号分隔的编码列表" >&2; exit 1; fi
      if [[ -n "$ONLY_RAW" ]]; then ONLY_RAW="${ONLY_RAW},${2}"; else ONLY_RAW="$2"; fi
      shift 2 ;;
    --only=*) ONLY_RAW="${ONLY_RAW:+${ONLY_RAW},}${1#--only=}"; shift ;;
    --skip)
      if [[ $# -lt 2 ]]; then echo "--skip 需要一个逗号分隔的编码列表" >&2; exit 1; fi
      if [[ -n "$SKIP_RAW" ]]; then SKIP_RAW="${SKIP_RAW},${2}"; else SKIP_RAW="$2"; fi
      shift 2 ;;
    --skip=*) SKIP_RAW="${SKIP_RAW:+${SKIP_RAW},}${1#--skip=}"; shift ;;
    --cache-age-days|--log-age-days|--projects-age-days)
      if [[ $# -lt 2 ]] || ! is_pos_int "$2"; then echo "$1 需要一个非负整数天数" >&2; exit 1; fi
      case "$1" in
        --cache-age-days) CACHE_AGE_DAYS="$2" ;;
        --log-age-days) LOG_AGE_DAYS="$2" ;;
        --projects-age-days) PROJECTS_AGE_DAYS="$2" ;;
      esac
      shift 2 ;;
    --projects-roots)
      if [[ $# -lt 2 ]]; then echo "$1 需要一个路径" >&2; exit 1; fi
      PROJECT_ROOTS="$2"; shift 2 ;;
    --projects-keep)
      if [[ $# -lt 2 ]]; then echo "$1 需要一个路径" >&2; exit 1; fi
      PROJECTS_KEEP="${PROJECTS_KEEP}${2}"$'\n'; shift 2 ;;
    --top)
      TOP_N=10
      if [[ $# -ge 2 ]] && is_pos_int "$2"; then TOP_N="$2"; shift; fi
      shift ;;
    --top=*) TOP_N="${1#--top=}"; is_pos_int "$TOP_N" || { echo "--top 需要整数" >&2; exit 1; }; shift ;;
    --list) LIST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "未知参数: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

# --list 延后到参数解析结束再执行，这样 --list --json 的顺序不影响结果
if [[ "$LIST" == "1" ]]; then
  if [[ "$JSON" == "1" ]]; then list_items_json; else list_items; fi
  exit 0
fi

validate_ids "$ONLY_RAW" "--only"
validate_ids "$SKIP_RAW" "--skip"

ONLY_NORM=$(normalize_ids "$ONLY_RAW")
SKIP_NORM=$(normalize_ids "$SKIP_RAW")
ONLY_IDS=""
SKIP_IDS=""
[[ -n "$ONLY_NORM" ]] && ONLY_IDS=",${ONLY_NORM},"
[[ -n "$SKIP_NORM" ]] && SKIP_IDS=",${SKIP_NORM},"

# 输出分流：--json 时进度信息走 stderr，stdout 只留 JSON
say() {
  if [[ "$JSON" == "1" ]]; then
    printf '%s\n' "$*" >&2
  else
    printf '%s\n' "$*"
  fi
}

if [[ "$CLEAN" != "1" ]]; then
  say "当前为【查询模式】：仅统计占用，不删除任何内容。"
  say "如需实际清理，请运行: $0 --clean --only <勾选的编码>"
  say ""
  if [[ -n "$ONLY_IDS" || -n "$SKIP_IDS" ]]; then
    say "⚠️ 未加 --clean，--only/--skip 不生效（本次仍是只读查询）。"
    say ""
  fi
elif [[ -z "$ONLY_IDS" && -z "$SKIP_IDS" && "$ALL" != "1" ]]; then
  echo "⚠️ --clean 未指定 --only/--skip 时必须显式加 --all（防止误清全部）。" >&2
  echo "   给用户勾选场景请传 --only <ids>；确实要全清请在用户终端跑 --clean --all。" >&2
  exit 2
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

# 预取 sudo 权限（仅 --clean 且非 dry-run，且所选清理项里确有 sudo 步骤时）
SUDO_OK=0
if [[ "$CLEAN" == "1" && "$DRY_RUN" != "1" ]]; then
  if want tmp || want snapshots; then
    if sudo -v 2>/dev/null; then
      SUDO_OK=1
    else
      echo "⚠️ 无法获取 sudo 权限（可能已取消或环境无 TTY）。" >&2
      echo "   涉及 /tmp、Time Machine 的步骤将被跳过；请在用户自己的终端执行对应 --only 命令。" >&2
      echo "" >&2
    fi
  fi
fi

UNSELECTED_IDS=""
LAST_RUN_SELECTED=1
STEP_TOTAL_KB=0
STEP_DEL_KB=0
STEP_NOTE=""
STEP_PATH=""
PLAN_CMD=""
REPORT_STEPS=()
SKIPPED_STEPS=()
JSON_ITEMS=()

json_add() {
  local id="$1" desc="$2" status="$3" obj
  obj=$(printf '{"id":"%s","label":"%s","status":"%s","total_kb":%s,"deletable_kb":%s' \
    "$(json_esc "$id")" "$(json_esc "$desc")" "$status" "${STEP_TOTAL_KB:-0}" "${STEP_DEL_KB:-0}")
  if [[ -n "$STEP_PATH" ]]; then
    obj="${obj},\"path\":\"$(json_esc "$STEP_PATH")\""
  fi
  if [[ -n "$STEP_NOTE" ]]; then
    obj="${obj},\"note\":\"$(json_esc "$STEP_NOTE")\""
  fi
  JSON_ITEMS+=("${obj}}")
}

# run <编码> <描述> <内部函数或命令...>
# 未勾选 → 跳过；需 sudo 但无权限 → 跳过并打印可交接的命令；
# 仅当 --clean 时执行；再配 --dry-run 则只打印 PLAN_CMD（调用方负责设置）。
run() {
  local id="$1" desc="$2"; shift 2
  STEP_NOTE=""
  if [[ "$CLEAN" == "1" ]] && ! want "$id"; then
    LAST_RUN_SELECTED=0
    mark_unselected "$id"
    say "   [跳过] ${desc}（未勾选：${id}）"
    json_add "$id" "$desc" "skipped-unselected"
    return 0
  fi
  LAST_RUN_SELECTED=1
  if is_sudo_id "$id" && [[ "$CLEAN" == "1" && "$DRY_RUN" != "1" && "$SUDO_OK" != "1" ]]; then
    say "   [跳过] ${desc}（当前环境无 sudo 权限）"
    say "      请在用户终端执行: ${PLAN_CMD:-$*}"
    SKIPPED_STEPS+=("${desc}（需 sudo，已交给用户终端）")
    json_add "$id" "$desc" "skipped-sudo"
    return 0
  fi
  if [[ "$CLEAN" != "1" ]]; then
    say "   [查询] ${desc}"
    json_add "$id" "$desc" "queried"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    say "   [预览] ${desc}"
    say "      ${PLAN_CMD:-（内部实现，无独立命令）}"
    json_add "$id" "$desc" "dry-run"
    return 0
  fi
  say "   [执行] ${desc}"
  if "$@"; then
    REPORT_STEPS+=("${desc}${STEP_NOTE:+（${STEP_NOTE}）}")
    json_add "$id" "$desc" "done"
  else
    SKIPPED_STEPS+=("${desc}（命令返回非 0，可能部分未删）")
    json_add "$id" "$desc" "failed"
  fi
}

# human <KB>：把 KB 换算成可读大小（GB/MB）
human() {
  awk -v kb="${1:-0}" '
    BEGIN {
      if (kb >= 1048576) { printf "%.2f GB", kb/1048576 }
      else if (kb >= 1024) { printf "%.0f MB", kb/1024 }
      else if (kb > 0) { printf "%d KB", kb }
      else { printf "0" }
    }'
}

# du_kb <path>：目录占用（KB）；取不到按 0 计并在调用处说明
du_kb() {
  local p="${1:-}" kb
  [[ -z "$p" || ! -e "$p" ]] && { printf '0'; return; }
  kb=$(du -sk "$p" 2>/dev/null | awk '{print $1}')
  printf '%s' "${kb:-0}"
}

# subset_kb <path> <days>：path 下 mtime 超过 days 天的普通文件总大小（KB）
# 注意：只统计文件，不对目录求和——目录会连同子树被重复计入
# （曾算出「可删 3.4G > 总量 2.3G」）。硬链接按条目各计一次，结果为近似值；
# 权限不可读的子树不计入（另由 denied_count 报数）。
subset_kb() {
  local p="$1" d="$2" kb
  [[ -e "$p" ]] || { printf '0'; return; }
  kb=$(find "$p" \( -type f -o -type l \) -mtime +"$d" -exec du -k {} + 2>/dev/null \
        | awk '{s+=$1} END{printf "%d", s+0}')
  printf '%s' "${kb:-0}"
}

# denied_count <path>：浅层遍历时被权限/TCC 拒绝的条目数（不当作 0 处理）
denied_count() {
  local p="$1" n
  [[ -e "$p" ]] || { printf '0'; return; }
  n=$(find "$p" -maxdepth 2 -print 2>&1 >/dev/null | grep -c "Operation not permitted" || true)
  printf '%s' "${n:-0}"
}

# delete_aged <path> <days>：删除 mtime 超过 days 天的条目，失败数写进 STEP_NOTE
delete_aged() {
  local p="$1" d="$2" fails
  [[ -e "$p" ]] || { say "      （路径不存在，跳过）"; STEP_NOTE="路径不存在"; return 0; }
  fails=$(find "$p" -mindepth 1 -mtime +"$d" -delete 2>&1 >/dev/null | grep -c . || true)
  fails="${fails:-0}"
  say "      删除完成；失败 ${fails} 条（受保护/正在使用的条目会留在原处）"
  STEP_NOTE="失败 ${fails} 条"
  return 0
}

# delete_aged_sudo：sudo 项的 mtime 清理（仅当 SUDO_OK=1 时会被调用）
delete_aged_sudo() {
  local p="$1" d="$2" fails
  [[ -e "$p" ]] || { say "      （路径不存在，跳过）"; STEP_NOTE="路径不存在"; return 0; }
  fails=$(sudo find "$p" -mindepth 1 -mtime +"$d" -delete 2>&1 >/dev/null | grep -c . || true)
  fails="${fails:-0}"
  say "      删除完成；失败 ${fails} 条（系统占用的条目属正常）"
  STEP_NOTE="失败 ${fails} 条"
  return 0
}

# delete_whole <path>：整目录删除
delete_whole() {
  local p="$1"
  if [[ ! -e "$p" ]]; then
    say "      （路径不存在，跳过）"
    STEP_NOTE="路径不存在"
    return 0
  fi
  if rm -rf "$p" 2>/dev/null; then
    say "      已删除 $p"
    STEP_NOTE="已删除"
  else
    say "      ⚠️ 未能完全删除 ${p}（可能受保护）"
    STEP_NOTE="删除失败（可能受保护）"
  fi
  return 0
}

# lower <str>：bash 3.2 没有 ${var,,}，统一走 tr
lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

# is_purge_cache <条目名>：已知纯缓存/更新器目录 → 整目录清理，不套 mtime 阈值。
# 判据：内容是仍可从服务端重新下载的副本（浏览器缓存、更新包）。
is_purge_cache() {
  local n
  n=$(lower "$1")
  case "$n" in
    "microsoft edge"|"google/chrome"|"chromium"|"bravesoftware"|"vivaldi"|"opera"|"firefox") return 0 ;;
    *updater*|*-updater) return 0 ;;
    "com.apple.softwareupdate"|"com.apple.appstore"|"com.apple.appstoreagent") return 0 ;;
    "com.apple.safari"|"safari") return 0 ;;
  esac
  return 1
}

say "======================================"
say "   Mac 磁盘占用查询"
if [[ "$CLEAN" == "1" ]]; then
  say "   *** 清理模式：正在执行清理 ***"
  [[ "$DRY_RUN" == "1" ]] && say "   *** 预览模式：不会实际删除任何内容 ***"
else
  say "   *** 查询模式：仅统计占用，不删除 ***"
fi
say "======================================"
say ""

say "【磁盘当前可用空间】："
DF_LINE=$(df -h / 2>/dev/null | awk 'NR==2{print "可用: " $4 " / 总量: " $2}')
say "${DF_LINE:-可用: 未知}"
DISK_FREE_BEFORE_KB=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
DISK_FREE_BEFORE_KB="${DISK_FREE_BEFORE_KB:-0}"
say ""

# ---------- 1. 用户缓存 [caches] ----------
say "----- 1. 用户缓存 (~/Library/Caches) [caches] -----"
CACHE_DIR="$HOME/Library/Caches"
clean_caches() {
  local p fails=0 n=0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    n=$((n + 1))
    rm -rf "$p" 2>/dev/null || fails=$((fails + 1))
  done <<< "$CACHE_PURGE_LIST"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    find "$p" -mindepth 1 -mtime +"$CACHE_AGE_DAYS" -delete 2>/dev/null || true
  done <<< "$CACHE_AGED_LIST"
  say "      纯缓存整删 ${n} 个目录（失败 ${fails} 个）；其余按 ${CACHE_AGE_DAYS} 天阈值清理"
  STEP_NOTE="整删 ${n} 个目录（失败 ${fails} 个）"
  return 0
}
if [[ -d "$CACHE_DIR" ]]; then
  CACHE_TOTAL_KB=$(du_kb "$CACHE_DIR")
  CACHE_DEL_KB=0
  CACHE_PURGE_LIST=""
  CACHE_AGED_LIST=""
  CACHE_TOP=""
  CACHE_PURGE_N=0
  CACHE_DENIED=$(denied_count "$CACHE_DIR")
  for entry in "$CACHE_DIR"/*; do
    [[ -e "$entry" ]] || continue
    name=$(basename "$entry")
    if is_purge_cache "$name"; then
      sz=$(du_kb "$entry")
      CACHE_DEL_KB=$((CACHE_DEL_KB + sz))
      CACHE_PURGE_LIST="${CACHE_PURGE_LIST}${entry}"$'\n'
      CACHE_PURGE_N=$((CACHE_PURGE_N + 1))
      CACHE_TOP="${CACHE_TOP}${sz}	${name}（纯缓存，整删）"$'\n'
    else
      sz=$(subset_kb "$entry" "$CACHE_AGE_DAYS")
      CACHE_DEL_KB=$((CACHE_DEL_KB + sz))
      [[ "$sz" -gt 0 ]] && CACHE_AGED_LIST="${CACHE_AGED_LIST}${entry}"$'\n'
      CACHE_TOP="${CACHE_TOP}${sz}	${name}（${CACHE_AGE_DAYS} 天前可删）"$'\n'
    fi
  done
  say "  目录总量: $(human "$CACHE_TOTAL_KB") / 本次可删（按阈值实测）: $(human "$CACHE_DEL_KB")"
  say "  最大子项（按可删量）:"
  printf '%s' "$CACHE_TOP" | sort -rn | head -5 | while IFS=$'\t' read -r kb nm; do
    [[ -n "${nm:-}" ]] && say "    - $(human "$kb")  ${nm}"
  done
  if [[ "$CACHE_DENIED" -gt 0 ]]; then
    say "  ⚠️ ${CACHE_DENIED} 个受保护子目录未计入（TCC 保护，需在系统设置授权或应用内清理）"
  fi
  STEP_TOTAL_KB="$CACHE_TOTAL_KB"
  STEP_DEL_KB="$CACHE_DEL_KB"
  STEP_PATH="$CACHE_DIR"
  PLAN_CMD="整删 ${CACHE_PURGE_N} 个纯缓存目录（浏览器/更新器）；其余: find <子项> -mindepth 1 -mtime +${CACHE_AGE_DAYS} -delete"
  run caches "清理用户缓存（纯缓存整删 + 其余按 mtime 阈值）" clean_caches
else
  say "  未找到 ~/Library/Caches，跳过"
fi
say ""

# ---------- 2. 用户日志 [logs] ----------
say "----- 2. 清理用户日志 (~/Library/Logs) [logs] -----"
LOG_DIR="$HOME/Library/Logs"
clean_logs() {
  delete_aged "$LOG_DIR" "$LOG_AGE_DAYS"
}
if [[ -d "$LOG_DIR" ]]; then
  LOG_TOTAL_KB=$(du_kb "$LOG_DIR")
  LOG_DEL_KB=$(subset_kb "$LOG_DIR" "$LOG_AGE_DAYS")
  LOG_DENIED=$(denied_count "$LOG_DIR")
  say "  目录总量: $(human "$LOG_TOTAL_KB") / 本次可删（${LOG_AGE_DAYS} 天前）: $(human "$LOG_DEL_KB")"
  [[ "$LOG_DENIED" -gt 0 ]] && say "  ⚠️ ${LOG_DENIED} 个受保护条目未计入"
  STEP_TOTAL_KB="$LOG_TOTAL_KB"
  STEP_DEL_KB="$LOG_DEL_KB"
  STEP_PATH="$LOG_DIR"
  PLAN_CMD="find ${LOG_DIR} -mindepth 1 -mtime +${LOG_AGE_DAYS} -delete"
  run logs "清理 ${LOG_AGE_DAYS} 天前未改动的用户日志文件" clean_logs
else
  say "  未找到 ~/Library/Logs，跳过"
fi
say ""

# ---------- 3. /tmp [tmp] ----------
say "----- 3. 清理 /tmp 临时目录 [tmp] -----"
# /tmp 在 macOS 上是软链 → private/tmp。find 对作为起始点的软链默认不跟进
# （`find /tmp -mindepth 1` 恒为 0 条，清理会静默空转），因此这里直接用真实路径。
TMP_DIR="/private/tmp"
if [[ -d "$TMP_DIR" ]]; then
  TMP_TOTAL_KB=$(du_kb "$TMP_DIR")
  TMP_DEL_KB=$(subset_kb "$TMP_DIR" "$CACHE_AGE_DAYS")
  say "  目录总量: $(human "$TMP_TOTAL_KB") / 本次可删（${CACHE_AGE_DAYS} 天前，近似）: $(human "$TMP_DEL_KB")"
  say "  注：/tmp 是 /private/tmp 的软链，脚本统一走真实路径；完整总量需 sudo 才可读。"
  STEP_TOTAL_KB="$TMP_TOTAL_KB"
  STEP_DEL_KB="$TMP_DEL_KB"
  STEP_PATH="$TMP_DIR"
  PLAN_CMD="sudo find ${TMP_DIR} -mindepth 1 -mtime +${CACHE_AGE_DAYS} -delete"
  run tmp "清理 ${TMP_DIR} 中 ${CACHE_AGE_DAYS} 天前的临时内容" delete_aged_sudo "$TMP_DIR" "$CACHE_AGE_DAYS"
else
  say "  未找到 ${TMP_DIR}，跳过"
fi
say ""

# ---------- 4. /var/folders [varfolders] ----------
say "----- 4. 检查 /var/folders 占用 [varfolders] -----"
MY_UID=$(id -u 2>/dev/null)
VF_SIZE=$(du -sh /var/folders 2>/dev/null | awk '{print $1}')
if [[ -z "$VF_SIZE" ]]; then
  VF_SIZE=$(sudo -n du -sh /var/folders 2>/dev/null | awk '{print $1}')
fi
say "  占用大小: ${VF_SIZE:-未知}"
say "  ⚠️ /var/folders 是系统临时/缓存容器。仅清理当前用户（uid ${MY_UID:-?}）容器目录下的明确残留，"
say "     系统/他人沙箱目录（如 _zz）会被跳过，避免权限噪音。"

FOLDERS_USER_DIR=""
for _d in /var/folders/*/*/ ; do
  [[ -d "$_d" ]] || continue
  if [[ "$(stat -f '%u' "$_d" 2>/dev/null)" == "$MY_UID" ]]; then
    FOLDERS_USER_DIR="${_d%/}"
    break
  fi
done

clean_varfolders() {
  local fails=0 out
  out=$(find "$FOLDERS_USER_DIR/T" -mindepth 1 -mtime +7 -delete 2>&1 >/dev/null | grep -c . || true)
  fails=$((fails + ${out:-0}))
  out=$(find "$FOLDERS_USER_DIR/C" -mindepth 1 -mtime +7 -delete 2>&1 >/dev/null | grep -c . || true)
  fails=$((fails + ${out:-0}))
  out=$(find "$FOLDERS_USER_DIR/X" -mindepth 1 -maxdepth 1 \( -name "*code_sign_clone*" -o -mtime +7 \) -delete 2>&1 >/dev/null | grep -c . || true)
  fails=$((fails + ${out:-0}))
  out=$(find "$FOLDERS_USER_DIR/T" -maxdepth 1 -type d -name "go-build*" -mtime +1 -delete 2>&1 >/dev/null | grep -c . || true)
  fails=$((fails + ${out:-0}))
  say "      T/C/X 与 go-build 清理完成；失败 ${fails} 条（多为受保护条目，属正常）"
  STEP_NOTE="失败 ${fails} 条"
  return 0
}

if [[ -z "$FOLDERS_USER_DIR" ]]; then
  say "  ⚠️ 未定位到当前用户的 /var/folders 容器目录，跳过本步清理。"
else
  say "  当前用户容器目录：$FOLDERS_USER_DIR"
  VF_TOTAL_KB=$(du_kb "$FOLDERS_USER_DIR")
  VF_DEL_KB=$(( $(subset_kb "$FOLDERS_USER_DIR/T" 7) + $(subset_kb "$FOLDERS_USER_DIR/C" 7) + $(subset_kb "$FOLDERS_USER_DIR/X" 7) ))
  say "  目录总量: $(human "$VF_TOTAL_KB") / 本次可删（T/C/X 7 天前）: $(human "$VF_DEL_KB")"
  STEP_TOTAL_KB="$VF_TOTAL_KB"
  STEP_DEL_KB="$VF_DEL_KB"
  STEP_PATH="$FOLDERS_USER_DIR"
  PLAN_CMD="find ${FOLDERS_USER_DIR}/{T,C,X} -mindepth 1 -mtime +7 -delete; find ${FOLDERS_USER_DIR}/T -maxdepth 1 -name 'go-build*' -mtime +1 -delete"
  run varfolders "清理当前用户 /var/folders 的过期残留" clean_varfolders
fi
say ""

# ---------- 5. Time Machine 本地快照 [snapshots] ----------
say "----- 5. 清理本地 Time Machine 快照 [snapshots] -----"
SNAPSHOT_COUNT=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c '^com\.apple\.' || true)
if [[ "$SNAPSHOT_COUNT" =~ ^[0-9]+$ ]] && [[ "$SNAPSHOT_COUNT" -gt 0 ]]; then
  say "  发现 ${SNAPSHOT_COUNT} 个本地快照（占用由系统按快照策略计算，脚本不估算）。"
  STEP_TOTAL_KB=0
  STEP_DEL_KB=0
  STEP_NOTE="快照 ${SNAPSHOT_COUNT} 个"
  PLAN_CMD="sudo tmutil thinlocalsnapshots / 999999999999 4"
  run snapshots "精简本地快照（快速模式）" sudo tmutil thinlocalsnapshots / 999999999999 4
else
  say "  未发现本地快照（或 tmutil 需要「完全磁盘访问权限」才能列出），跳过"
fi
say ""

# ---------- 6. 废纸篓 [trash] ----------
say "----- 6. 清空废纸篓 [trash] -----"
clean_trash() {
  local fails=0 p
  for p in "$HOME"/.Trash/*; do
    [[ -e "$p" ]] || continue
    rm -rf "$p" 2>/dev/null || fails=$((fails + 1))
  done
  say "      清空完成；未能删除 ${fails} 项（可能被占用）"
  STEP_NOTE="未能删除 ${fails} 项"
  return 0
}
if [[ -d "$HOME/.Trash" ]]; then
  TRASH_TOTAL_KB=$(du_kb "$HOME/.Trash")
  say "  占用大小: $(human "$TRASH_TOTAL_KB")"
  STEP_TOTAL_KB="$TRASH_TOTAL_KB"
  STEP_DEL_KB="$TRASH_TOTAL_KB"
  STEP_PATH="$HOME/.Trash"
  PLAN_CMD="rm -rf ${HOME}/.Trash/*"
  run trash "清空废纸篓" clean_trash
else
  say "  未找到废纸篓，跳过"
fi
say ""

# ---------- 7. 开发者缓存 [xcode] ----------
say "----- 7. 开发者工具缓存 [xcode] -----"
XCODE_DIR="$HOME/Library/Developer/Xcode/DerivedData"
if [[ -d "$XCODE_DIR" ]]; then
  XCODE_KB=$(du_kb "$XCODE_DIR")
  say "  DerivedData 占用: $(human "$XCODE_KB")"
  STEP_TOTAL_KB="$XCODE_KB"
  STEP_DEL_KB="$XCODE_KB"
  STEP_PATH="$XCODE_DIR"
  PLAN_CMD="rm -rf ${XCODE_DIR}"
  run xcode "清理 Xcode DerivedData" delete_whole "$XCODE_DIR"
else
  say "  未找到 Xcode DerivedData，跳过"
fi
say ""

# ---------- 8. 大体积高危项目 [bigbuild] [docker] ----------
say "----- 8. 大体积项目检测与清理 [bigbuild] [docker] -----"

brew_cleanup() {
  echo "  正在运行 brew cleanup --prune=all ..."
  brew cleanup --prune=all 2>&1 | tail -3
  brew autoremove 2>&1 | tail -3
  say "      Homebrew 缓存与旧版本已清理"
  STEP_NOTE="brew cleanup --prune=all + autoremove"
  return 0
}

# 8.1 iOS 设备备份 —— 用户数据，只报告
IOS_BACKUP="$HOME/Library/Application Support/MobileSync/Backup"
if [[ -d "$IOS_BACKUP" ]]; then
  say "  ① iOS 设备备份: $(human "$(du_kb "$IOS_BACKUP")")  （用户数据，不代删）"
  say "     路径: $IOS_BACKUP"
  say "     清理方式：Finder/iTunes「设备」里删除旧备份"
else
  say "  ① iOS 设备备份: 未找到"
fi

# 8.2 旧 iOS 固件 (ipsw)
IPSW_DIR="$HOME/Library/iTunes/iPhone Software Updates"
if [[ -d "$IPSW_DIR" ]]; then
  IPSW_KB=$(du_kb "$IPSW_DIR")
  say "  ② 旧 iOS 固件 (ipsw): $(human "$IPSW_KB")"
  STEP_TOTAL_KB="$IPSW_KB"; STEP_DEL_KB="$IPSW_KB"; STEP_PATH="$IPSW_DIR"
  PLAN_CMD="rm -rf ${IPSW_DIR}"
  run bigbuild "清理旧 iOS 固件" delete_whole "$IPSW_DIR"
else
  say "  ② 旧 iOS 固件: 未找到"
fi

# 8.3 Homebrew
if command -v brew &> /dev/null; then
  BREW_CACHE=$(brew --cache 2>/dev/null || true)
  BREW_KB=$(du_kb "$BREW_CACHE")
  say "  ③ Homebrew 缓存: $(human "$BREW_KB")（旧版本 Cellar 由 brew cleanup 一并处理）"
  STEP_TOTAL_KB="$BREW_KB"; STEP_DEL_KB="$BREW_KB"; STEP_PATH="${BREW_CACHE:-}"
  PLAN_CMD="brew cleanup --prune=all && brew autoremove"
  run bigbuild "清理 Homebrew 缓存与旧版本" brew_cleanup
else
  say "  ③ Homebrew 缓存: 未安装 Homebrew，跳过"
fi

# 8.4 CocoaPods
PODS_CACHE="$HOME/Library/Caches/CocoaPods"
if [[ -d "$PODS_CACHE" ]]; then
  PODS_KB=$(du_kb "$PODS_CACHE")
  say "  ④ CocoaPods 缓存: $(human "$PODS_KB")"
  STEP_TOTAL_KB="$PODS_KB"; STEP_DEL_KB="$PODS_KB"; STEP_PATH="$PODS_CACHE"
  PLAN_CMD="rm -rf ${PODS_CACHE}"
  run bigbuild "清理 CocoaPods 缓存" delete_whole "$PODS_CACHE"
else
  say "  ④ CocoaPods 缓存: 未找到"
fi

# 8.5 Gradle
GRADLE_CACHE="$HOME/.gradle/caches"
if [[ -d "$GRADLE_CACHE" ]]; then
  GRADLE_KB=$(du_kb "$GRADLE_CACHE")
  say "  ⑤ Gradle 缓存: $(human "$GRADLE_KB")"
  STEP_TOTAL_KB="$GRADLE_KB"; STEP_DEL_KB="$GRADLE_KB"; STEP_PATH="$GRADLE_CACHE"
  PLAN_CMD="rm -rf ${GRADLE_CACHE}"
  run bigbuild "清理 Gradle 缓存" delete_whole "$GRADLE_CACHE"
else
  say "  ⑤ Gradle 缓存: 未找到"
fi

# 8.6 Docker
if command -v docker &> /dev/null; then
  say "  ⑥ Docker: 检测到 Docker（回收发生在虚拟磁盘内部，宿主 df 未必同步变小）"
  STEP_TOTAL_KB=0; STEP_DEL_KB=0; STEP_PATH=""
  STEP_NOTE="prune 后 Docker.raw/OrbStack 稀疏镜像不随之缩小"
  PLAN_CMD="docker system prune -a --force"
  run docker "清理 Docker 无用资源（镜像/容器/网络/构建缓存）" docker system prune -a --force
else
  say "  ⑥ Docker: 未安装，跳过"
fi

# 8.7 DeviceSupport + 旧模拟器
DEVSUPPORT="$HOME/Library/Developer/Xcode/iOS DeviceSupport"
if [[ -d "$DEVSUPPORT" ]]; then
  DEV_KB=$(du_kb "$DEVSUPPORT")
  say "  ⑦ Xcode iOS DeviceSupport: $(human "$DEV_KB")"
  STEP_TOTAL_KB="$DEV_KB"; STEP_DEL_KB="$DEV_KB"; STEP_PATH="$DEVSUPPORT"
  PLAN_CMD="rm -rf ${DEVSUPPORT}"
  run bigbuild "清理旧 iOS DeviceSupport 符号文件" delete_whole "$DEVSUPPORT"
else
  say "  ⑦ Xcode iOS DeviceSupport: 未找到"
fi

if command -v xcrun &> /dev/null; then
  say "  ⑧ 清理不可用的旧 iOS 模拟器 ..."
  STEP_TOTAL_KB=0; STEP_DEL_KB=0; STEP_PATH=""
  PLAN_CMD="xcrun simctl delete unavailable"
  run bigbuild "删除不可用的旧模拟器" xcrun simctl delete unavailable
  SIM_CACHE="$HOME/Library/Developer/CoreSimulator/Caches"
  if [[ -d "$SIM_CACHE" ]]; then
    SIM_CACHE_KB=$(du_kb "$SIM_CACHE")
    say "      CoreSimulator/Caches: $(human "$SIM_CACHE_KB")"
    STEP_TOTAL_KB="$SIM_CACHE_KB"; STEP_DEL_KB="$SIM_CACHE_KB"; STEP_PATH="$SIM_CACHE"
    PLAN_CMD="rm -rf ${SIM_CACHE}"
    run bigbuild "清理 CoreSimulator 缓存" delete_whole "$SIM_CACHE"
  fi
else
  say "  ⑧ 未安装 Xcode 命令行工具，跳过模拟器清理"
fi
say ""

# ---------- 9. 语言工具链与包管理器缓存 [toolcache] ----------
say "----- 9. 语言工具链与包管理器缓存（安全可再生）[toolcache] -----"
SAFE_CACHE_DIRS=(
  "$HOME/.npm/_npx"
  "$HOME/.npm/_cacache"
  "$HOME/.npm/_logs"
  "$HOME/.cache/uv"
  "$HOME/.cache/puppeteer"
  "$HOME/.cache/node"
  "$HOME/.cache/codex-runtimes"
  "$HOME/.cache/opencode"
  "$HOME/.cache/yarn"
  "$HOME/.cache/bun"
  "$HOME/.bun/install/cache"
  "$HOME/.cargo/registry/cache"
  "$HOME/go/pkg/mod/cache/download"
  "$HOME/.m2/repository"
  "$HOME/Library/Caches/go-build"
  "$HOME/Library/Caches/goimports"
  "$HOME/Library/Caches/gopls"
  "$HOME/Library/Caches/golangci-lint"
  "$HOME/Library/Caches/ms-playwright"
  "$HOME/Library/Caches/Cypress"
  "$HOME/Library/Caches/Yarn"
  "$HOME/Library/Caches/pip"
  "$HOME/Library/Caches/node-gyp"
  "$HOME/Library/Caches/electron"
  "$HOME/Library/Caches/Homebrew"
)
PNPM_PMS="$HOME/Library/pnpm/package-manager-store"
TOOLCACHE_TOTAL_KB=0
TOOLCACHE_EXIST=0
for d in "${SAFE_CACHE_DIRS[@]}"; do
  if [[ -d "$d" ]]; then
    sz=$(du_kb "$d")
    TOOLCACHE_TOTAL_KB=$((TOOLCACHE_TOTAL_KB + sz))
    TOOLCACHE_EXIST=$((TOOLCACHE_EXIST + 1))
    if [[ "$sz" -ge 1024 ]]; then
      say "    - $(human "$sz")  ${d/#$HOME/~}"
    fi
  fi
done
PMS_KB=0
if [[ -d "$PNPM_PMS" ]]; then
  PMS_KB=$(du_kb "$PNPM_PMS")
  say "    - $(human "$PMS_KB")  ~/Library/pnpm/package-manager-store（pnpm 工具版本仓库，删后重新下载）"
fi
say "  白名单命中 ${TOOLCACHE_EXIST} 个目录，合计 $(human "$TOOLCACHE_TOTAL_KB")；本次可删 $(human "$((TOOLCACHE_TOTAL_KB + PMS_KB))")"
STEP_TOTAL_KB=$((TOOLCACHE_TOTAL_KB + PMS_KB))
STEP_DEL_KB=$((TOOLCACHE_TOTAL_KB + PMS_KB))
STEP_PATH=""
PLAN_CMD="rm -rf <上列白名单目录>; rm -rf ~/Library/pnpm/package-manager-store"
clean_toolcache() {
  local fails=0 p
  for p in "${SAFE_CACHE_DIRS[@]}"; do
    [[ -d "$p" ]] || continue
    rm -rf "$p" 2>/dev/null || fails=$((fails + 1))
  done
  if [[ -d "$PNPM_PMS" ]]; then
    rm -rf "$PNPM_PMS" 2>/dev/null || fails=$((fails + 1))
  fi
  say "      白名单缓存清理完成；失败 ${fails} 个"
  STEP_NOTE="失败 ${fails} 个"
  return 0
}
run toolcache "清理语言工具链/包管理器缓存" clean_toolcache

if command -v pnpm &> /dev/null; then
  PNPM_STORE_KB=$(du_kb "$HOME/Library/pnpm/store")
  say "  pnpm store: $(human "$PNPM_STORE_KB")（只回收未被引用的包，可删量由 prune 决定）"
  STEP_TOTAL_KB="$PNPM_STORE_KB"
  STEP_DEL_KB=0
  STEP_PATH="$HOME/Library/pnpm/store"
  STEP_NOTE="仅回收未引用包"
  PLAN_CMD="corepack pnpm store prune"
  run toolcache "回收 pnpm store 中未引用的包" corepack pnpm store prune
else
  say "  pnpm store: 未安装 pnpm，跳过"
fi
say ""

# ---------- 10. 应用内缓存 [appcache] ----------
say "----- 10. 应用内缓存（Electron/Chromium 型 app）[appcache] -----"
APPSUPPORT="$HOME/Library/Application Support"
clean_appcache() {
  local fails=0 n=0 p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    n=$((n + 1))
    rm -rf "$p" 2>/dev/null || fails=$((fails + 1))
  done <<< "$APPCACHE_LIST"
  say "      删除 ${n} 个目录，失败 ${fails} 个（app 正在写入的多半会失败，可退出 app 后重试）"
  STEP_NOTE="删除 ${n} 个目录，失败 ${fails} 个"
  return 0
}
if [[ -d "$APPSUPPORT" ]]; then
  APPCACHE_TOTAL_KB=0
  APPCACHE_LIST=""
  APPCACHE_TOP=""
  for app in "$APPSUPPORT"/*; do
    [[ -d "$app" ]] || continue
    for sub in "Cache" "GPUCache" "Code Cache" "CachedData" "CachedExtensionVSIXs" \
               "DawnGraphiteCache" "DawnWebGPUCache" "GrShaderCache" "ShaderCache" \
               "Service Worker/CacheStorage"; do
      d="$app/$sub"
      [[ -d "$d" ]] || continue
      sz=$(du_kb "$d")
      if [[ "$sz" -lt 10240 ]]; then continue; fi   # < 10MB 不进清单，减少噪音
      APPCACHE_TOTAL_KB=$((APPCACHE_TOTAL_KB + sz))
      APPCACHE_LIST="${APPCACHE_LIST}${d}"$'\n'
      APPCACHE_TOP="${APPCACHE_TOP}${sz}	${d#"$APPSUPPORT"/}"$'\n'
    done
  done
  say "  本次可删合计: $(human "$APPCACHE_TOTAL_KB")（>10MB 的 app 内缓存目录）"
  printf '%s' "$APPCACHE_TOP" | sort -rn | head -8 | while IFS=$'\t' read -r kb nm; do
    [[ -n "${nm:-}" ]] && say "    - $(human "$kb")  ${nm}"
  done
  say "  注：这些是 app 自己的渲染/JS 缓存，删除后首次启动会重建（不动配置与登录态）。"
  STEP_TOTAL_KB="$APPCACHE_TOTAL_KB"
  STEP_DEL_KB="$APPCACHE_TOTAL_KB"
  STEP_PATH="$APPSUPPORT"
  PLAN_CMD="按上列路径逐个 rm -rf（Cache / GPUCache / Code Cache / CachedData 等）"
  run appcache "清理 app 内嵌缓存目录" clean_appcache
else
  say "  未找到 ~/Library/Application Support，跳过"
fi
say ""

# ---------- 11. 应用自动更新残留 [updaters] ----------
say "----- 11. 应用自动更新残留 [updaters] -----"
clean_updaters() {
  local fails=0 n=0 p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    n=$((n + 1))
    rm -rf "$p" 2>/dev/null || fails=$((fails + 1))
  done <<< "$UPD_LIST"
  say "      删除 ${n} 个目录，失败 ${fails} 个"
  STEP_NOTE="删除 ${n} 个目录，失败 ${fails} 个"
  return 0
}
if [[ -d "$APPSUPPORT" ]]; then
  UPD_TOTAL_KB=0
  UPD_LIST=""
  UPD_TOP=""
  UPD_FOUND=$(find "$APPSUPPORT" -maxdepth 4 -type d \
      \( -name crx_cache -o -name auto-updater -o -name app-recovery-cache -o -name UpdateCache \) \
      -prune -print 2>/dev/null || true)
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    sz=$(du_kb "$d")
    UPD_TOTAL_KB=$((UPD_TOTAL_KB + sz))
    UPD_LIST="${UPD_LIST}${d}"$'\n'
    UPD_TOP="${UPD_TOP}${sz}	${d#"$APPSUPPORT"/}"$'\n'
  done <<< "$UPD_FOUND"
  say "  本次可删合计: $(human "$UPD_TOTAL_KB")（浏览器扩展更新缓存、app 自动更新包）"
  printf '%s' "$UPD_TOP" | sort -rn | head -8 | while IFS=$'\t' read -r kb nm; do
    [[ -n "${nm:-}" ]] && say "    - $(human "$kb")  ${nm}"
  done
  STEP_TOTAL_KB="$UPD_TOTAL_KB"
  STEP_DEL_KB="$UPD_TOTAL_KB"
  STEP_PATH="$APPSUPPORT"
  PLAN_CMD="rm -rf <上列 crx_cache / auto-updater / app-recovery-cache 目录>"
  run updaters "清理应用自动更新下载残留" clean_updaters
else
  say "  未找到 ~/Library/Application Support，跳过"
fi
say ""

# ---------- 12. 项目构建产物 [projects] ----------
say "----- 12. 项目构建产物（node_modules 等）[projects] -----"
say "  扫描根: ${PROJECT_ROOTS}（--projects-roots 可改；只处理 ${PROJECTS_AGE_DAYS} 天前未改动的目录）"
clean_projects() {
  local fails=0 n=0 p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    n=$((n + 1))
    rm -rf "$p" 2>/dev/null || fails=$((fails + 1))
  done <<< "$PROJ_DEL_LIST"
  say "      删除 ${n} 个构建产物目录，失败 ${fails} 个"
  STEP_NOTE="删除 ${n} 个目录，失败 ${fails} 个"
  return 0
}
PROJ_TOTAL_KB=0
PROJ_DEL_KB=0
PROJ_DEL_LIST=""
PROJ_TOP=""
PROJ_N=0
OLD_IFS="$IFS"
IFS=':'
for root in $PROJECT_ROOTS; do
  IFS="$OLD_IFS"
  if [[ ! -d "$root" ]]; then
    say "  ⚠️ 扫描根不存在: $root"
    IFS=':'
    continue
  fi
  PROJ_FOUND=$(find "$root" -maxdepth 6 -type d \
      \( -name node_modules -o -name .next -o -name .turbo -o -name .parcel-cache \
         -o -name .venv -o -name venv -o -name __pycache__ -o -name target \
         -o -name dist -o -name build -o -name Pods \) \
      -prune -print 2>/dev/null || true)
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    sz=$(du_kb "$d")
    if [[ "$sz" -lt 51200 ]]; then continue; fi      # < 50MB 不列为候选
    PROJ_N=$((PROJ_N + 1))
    PROJ_TOTAL_KB=$((PROJ_TOTAL_KB + sz))
    mtime=$(stat -f '%m' "$d" 2>/dev/null || echo 0)
    age_days=$(( ( $(date +%s) - mtime ) / 86400 ))
    if [[ -n "$PROJECTS_KEEP" ]] && printf '%s' "$PROJECTS_KEEP" | grep -Fxq "$d"; then
      PROJ_TOP="${PROJ_TOP}${sz}	$(human "$sz")  ${d#"$HOME"/}  （保留：--projects-keep）"$'\n'
      continue
    fi
    if [[ "$age_days" -ge "$PROJECTS_AGE_DAYS" ]]; then
      PROJ_DEL_KB=$((PROJ_DEL_KB + sz))
      PROJ_DEL_LIST="${PROJ_DEL_LIST}${d}"$'\n'
      PROJ_TOP="${PROJ_TOP}${sz}	$(human "$sz")  ${d#"$HOME"/}  （${age_days} 天未改动，可删）"$'\n'
    else
      PROJ_TOP="${PROJ_TOP}${sz}	$(human "$sz")  ${d#"$HOME"/}  （${age_days} 天内有改动，跳过）"$'\n'
    fi
  done <<< "$PROJ_FOUND"
  IFS=':'
done
IFS="$OLD_IFS"
say "  命中 ${PROJ_N} 个构建产物目录，合计 $(human "$PROJ_TOTAL_KB")；其中可删（≥${PROJECTS_AGE_DAYS} 天未改动）$(human "$PROJ_DEL_KB")"
printf '%s' "$PROJ_TOP" | sort -rn | head -12 | while IFS=$'\t' read -r kb nm; do
  [[ -n "${nm:-}" ]] && say "    - ${nm}"
done
if [[ "$PROJ_N" -gt 12 ]]; then
  say "    …（仅显示最大的 12 项；完整清单用 --json）"
fi
say "  注：删除后需重新 npm install / build；活跃项目请提高 --projects-age-days 或用 --projects-keep 排除。"
STEP_TOTAL_KB="$PROJ_TOTAL_KB"
STEP_DEL_KB="$PROJ_DEL_KB"
STEP_PATH=""
PLAN_CMD="rm -rf <上列 ≥${PROJECTS_AGE_DAYS} 天未改动的构建产物目录>"
run projects "清理项目构建产物（构建产物可再生）" clean_projects
say ""

# ---------- 13. 最占空间 Top N（只读） ----------
if [[ "$TOP_N" -gt 0 ]]; then
  say "----- 13. \$HOME 下最占空间的 ${TOP_N} 项（只读）-----"
  say "  正在扫描（-xdev 全量遍历，100G+ 的 HOME 可能要几分钟；这一步只在 --top 时跑）..."
  say ""
  say "  目录 Top ${TOP_N}:"
  du -sk "$HOME"/* 2>/dev/null | sort -rn | head -"$TOP_N" | while read -r kb p; do
    [[ -n "${p:-}" ]] && say "    $(human "$kb")  ${p#"$HOME"/}"
  done
  say ""
  say "  文件 Top ${TOP_N}（>100MB）:"
  find "$HOME" -xdev -type f -size +100M -exec du -k {} + 2>/dev/null | sort -rn | head -"$TOP_N" | while read -r kb p; do
    [[ -n "${p:-}" ]] && say "    $(human "$kb")  ${p#"$HOME"/}"
  done
  say ""
  say "  提示：可再生（缓存/构建产物）的走本脚本编码；用户数据（聊天记录、虚拟机镜像、"
  say "        设计稿、iCloud）只报告不代删，给应用内入口。"
  say ""
fi

# ---------- 清理报告 ----------
DISK_FREE_AFTER_KB=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
DISK_FREE_AFTER_KB="${DISK_FREE_AFTER_KB:-0}"

if [[ "$DRY_RUN" == "1" ]]; then
  say "======================================"
  say "           清理报告（预览）"
  say "======================================"
  say "  预览模式，未实际清理。确认上列计划命令与勾选一致后，去掉 --dry-run 执行。"
  say "======================================"
elif [[ "$CLEAN" != "1" ]]; then
  say "======================================"
  say "           清理报告"
  say "======================================"
  say "  （查询模式，仅统计占用，未执行任何清理）"
  say ""
  say "  下一步：把上面的清理项按编码交给用户勾选，再执行"
  say "    bash $0 --clean --only <勾选的编码>"
  say "  预览所选：加 --dry-run；排除某项：用 --skip <编码>"
  say "======================================"
else
  say "======================================"
  say "           清理报告"
  say "======================================"
  FREED_KB=$((DISK_FREE_AFTER_KB - DISK_FREE_BEFORE_KB))
  say "  磁盘可用空间：$(human "$DISK_FREE_BEFORE_KB") → $(human "$DISK_FREE_AFTER_KB")"
  if [[ "$FREED_KB" -gt 0 ]]; then
    say "  本次实际释放：约 $(human "$FREED_KB")"
  elif [[ "$FREED_KB" -eq 0 && ${#REPORT_STEPS[@]} -eq 0 ]]; then
    say "  本次没有实际执行的清理项，空间未变化。"
  elif [[ "$FREED_KB" -lt 0 ]]; then
    say "  可用空间反而减少 $(human "$((-FREED_KB))")（清理期间可能有新写入，属正常）"
  else
    say "  本次实际释放量小于 1 MB（df 精度限制），已执行项见下方。"
  fi
  say ""
  if [[ ${#REPORT_STEPS[@]} -gt 0 ]]; then
    say "  实际执行的清理项（${#REPORT_STEPS[@]}）："
    for s in "${REPORT_STEPS[@]}"; do say "    ✅ ${s}"; done
  else
    say "  （本次没有实际执行的清理项）"
  fi
  if [[ -n "$UNSELECTED_IDS" ]]; then
    say ""
    say "  未勾选（未执行）：$UNSELECTED_IDS"
  fi
  if [[ ${#SKIPPED_STEPS[@]} -gt 0 ]]; then
    say ""
    say "  已勾选但未完成的清理项（${#SKIPPED_STEPS[@]}）："
    for s in "${SKIPPED_STEPS[@]}"; do say "    ⏭  ${s}"; done
  fi
  say "======================================"
  say ""
  say "建议：重启一次 Mac，让系统重建必要的缓存文件，"
  say "并再次前往 \"关于本机 → 储存空间\" 查看统计（该统计有延迟，需等待或重启后再看）。"
fi
say ""

if [[ "$JSON" == "1" ]]; then
  MODE="query"
  [[ "$CLEAN" == "1" ]] && MODE="clean"
  [[ "$DRY_RUN" == "1" ]] && MODE="dry-run"
  printf '{"schema":1,"mode":"%s","disk":{"free_before_kb":%s,"free_after_kb":%s,"freed_kb":%s},"items":[' \
    "$MODE" "$DISK_FREE_BEFORE_KB" "$DISK_FREE_AFTER_KB" "$((DISK_FREE_AFTER_KB - DISK_FREE_BEFORE_KB))"
  sep=""
  for it in "${JSON_ITEMS[@]}"; do
    printf '%s%s' "$sep" "$it"
    sep=","
  done
  printf ']}\n'
fi
