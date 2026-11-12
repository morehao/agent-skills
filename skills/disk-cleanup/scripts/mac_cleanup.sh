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
#   - 不创建临时文件（here-doc 换 printf、循环用进程替换）：只读沙箱/无 TMPDIR 下也能跑
#     （旧版 usage 用 here-doc，实测连 --help 都报 cannot create temp file）
#   - 卸载残留（orphans）靠「已装 App 名单 vs Library 目录名」反推，只报告；
#     删除必须 --orphans-delete 逐条点名路径，避免按名字猜把活数据删了
# 使用方法（本脚本随 disk-cleanup 技能分发，位于 skills/disk-cleanup/scripts/）：
#   1. 只查询占用（默认，不删任何东西）：bash skills/disk-cleanup/scripts/mac_cleanup.sh
#   2. 查看清理项编码：                 bash ... --list
#   3. 编码 + 说明的机器可读版：        bash ... --list --json
#   4. 预览所选清理项：                 bash ... --clean --dry-run --only caches,logs
#   5. 清理所选（用户勾选后执行）：      bash ... --clean --only caches,logs,trash
#   6. 只看最占空间的对象：             bash ... --top 10
#   7. 全部清理（只建议用户本人在终端手动使用）：bash ... --clean --all
#   8. 只看「已卸载应用的残留」：        bash ... --orphans-list
#   9. 按路径删除某几条残留：           bash ... --clean --only orphans --orphans-delete <路径>
#
# orphans（卸载残留）与其它编码的区别：判定靠「已装 App 名单反推」，天然会误报/漏报，
# 因此这一项**只报告、不自动删**；删除必须用 --orphans-delete 逐条点名路径。
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
DSHTMP_AGE_DAYS=0           # 0 = 全部可删（.dsh/tmp 是过程产物）
PROJECTCACHE_AGE_DAYS=3
PROJECT_ROOTS="${PROJECT_ROOTS:-$HOME/Documents}"
PROJECTS_KEEP_LIST=()      # 已归一化的 --projects-keep 绝对路径（bash 3.2 数组）
ORPHANS_AGE_DAYS=0          # 0 = 不限年龄（残留本身就是「App 不在了」的证据，不看新旧）
ORPHANS_DELETE_LIST=""     # 换行分隔的绝对路径；只有列在这里的才会被删
ORPHANS_NEED_SUDO=0
ORPHANS_LIST_ALL=0
ORPHANS_MAX=15             # 默认只显示最大的 N 项，--orphans-list 显示全部
ORPHAN_CANDIDATE_PATHS=()  # 本次扫描命中的残留候选（归一化绝对路径；--orphans-delete 只认这批）
ESTIMATED_FREED_KB=0       # 状态为 done/partial 的项 deletable_kb 之和（估算）
HAD_FAILURE=0              # 任一 item 为 partial/failed → 最终 exit 1
FAILED_COUNT=0
RM_FAILS=0                 # rm_nul_stdin/rm_tree_stdin 的失败计数（全局，避免子 shell）
SANDBOX_SUSPECT=0          # 预检发现 $HOME 下不可写（疑似 workspace-write 沙箱）→ EPERM 不再当 TCC 跳过

# 清理项编码：勾选单位。新增清理项时必须同时更新这里、references/cleanup.md 与 SKILL.md 的清单；
# scripts/check-disk-cleanup-codes.mjs 会校验三处是否一致（CI 会跑）。
KNOWN_IDS="caches logs tmp varfolders snapshots trash xcode node go python rust jvm homebrew cocoapods xcode-ios docker appcache updaters projects dshtmp projectcache orphans"

# 卸载残留的扫描根（只看顶层条目，不递归）：残留按「App 会往哪几处写东西」枚举，
# 不做全盘扫描。新增位置要同时改这里和 references/cleanup.md 的 orphans 小节。
ORPHAN_ROOTS=(
  "$HOME/Library/Application Support"
  "$HOME/Library/Caches"
  "$HOME/Library/Preferences"
  "$HOME/Library/Containers"
  "$HOME/Library/Group Containers"
  "$HOME/Library/HTTPStorages"
  "$HOME/Library/Logs"
  "$HOME/Library/LaunchAgents"
  "/Library/Application Support"
  "/Library/Preferences"
  "/Library/Caches"
  "/Library/LaunchAgents"
  "/Library/LaunchDaemons"
  "/Library/PrivilegedHelperTools"
)

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
    node)       echo "Node 生态缓存（npm/yarn/bun/pnpm/无头运行时）" ;;
    go)         echo "Go 缓存（模块/构建/工具）" ;;
    python)     echo "Python 缓存（uv/pip）" ;;
    rust)       echo "Rust 缓存（cargo registry）" ;;
    jvm)        echo "JVM 缓存（Maven .m2 / Gradle）" ;;
    homebrew)   echo "Homebrew 缓存与旧版本" ;;
    cocoapods)  echo "CocoaPods 缓存" ;;
    xcode-ios)  echo "iOS 大件（ipsw/DeviceSupport/CoreSimulator/模拟器）" ;;
    docker)     echo "Docker 无用资源" ;;
    appcache)   echo "应用内缓存（Electron/Chromium 型 app）" ;;
    updaters)   echo "应用自动更新残留" ;;
    projects)   echo "项目构建产物（node_modules 等）" ;;
    dshtmp)     echo "项目内 .dsh/tmp 过程产物" ;;
    projectcache) echo "项目内编译缓存（Go/pnpm 等）" ;;
    orphans)    echo "已卸载应用的残留文件（只报告，按路径删）" ;;
    *)          echo "未知" ;;
  esac
}

item_desc() {
  case "$1" in
    caches)     echo "纯缓存目录整删；其余只删 ${CACHE_AGE_DAYS} 天前未改动内容" ;;
    logs)       echo "只删 ${LOG_AGE_DAYS} 天前的旧日志文件与因此变空的旧目录；保留 ~/Library/Logs 本身" ;;
    tmp)        echo "只删 ${CACHE_AGE_DAYS} 天前的陈旧内容" ;;
    varfolders) echo "T/C 清 7 天以上；X 清代码签名残留与 7 天前目录；go-build 清 1 天以上" ;;
    snapshots)  echo "tmutil thinlocalsnapshots（回滚粒度变粗，系统会重建）" ;;
    trash)      echo "清空，清后不可恢复" ;;
    xcode)      echo "整个 DerivedData 删除，下次构建全量重编" ;;
    node)       echo "npm/yarn/bun/pnpm 缓存与无头运行时缓存；pnpm store prune（删后重新下载/编译）" ;;
    go)         echo "go-build / go/pkg/mod / goimports / gopls / golangci-lint（删后重新下载/编译）" ;;
    python)     echo "uv / pip 缓存（删后重新下载）" ;;
    rust)       echo "cargo registry 缓存（删后重新下载 crate）" ;;
    jvm)        echo "Maven ~/.m2/repository 与 Gradle ~/.gradle/caches（删后重新下载）" ;;
    homebrew)   echo "brew cleanup --prune=all + autoremove（旧版本不能回滚）" ;;
    cocoapods)  echo "CocoaPods 缓存（删后 pod install 重新下载）" ;;
    xcode-ios)  echo "ipsw / iOS DeviceSupport / CoreSimulator / 不可用模拟器" ;;
    docker)     echo "docker system prune -a（镜像需重新 pull；不会缩小 Docker.raw）" ;;
    appcache)   echo "各 app 目录下的 Cache/GPUCache/Code Cache 等，app 会重建" ;;
    updaters)   echo "crx_cache / auto-updater 等更新下载残留" ;;
    projects)   echo "只处理 ${PROJECTS_AGE_DAYS} 天前未改动的构建产物目录（需重新 build）" ;;
    dshtmp)     echo "只清空 */.dsh/tmp 的内容、保留目录；--dshtmp-age-days 默认 0（全部可删）" ;;
    projectcache) echo "整目录删 .gocache/.tmp-gocache/.dsh/gocache/.pnpm-store/.corepack；只处理 ${PROJECTCACHE_AGE_DAYS} 天前未改动的目录（需重新 build/install）" ;;
    orphans)    echo "反推已装 App 名单后列出疑似残留；删除需 --orphans-delete 逐条指定路径" ;;
    *)          echo "" ;;
  esac
}

# orphans 是混合项（部分条目在 /Library 下需要 sudo），不能整项标 sudo；
# 是否 sudo 由具体路径决定，见 is_sudo_path。
is_sudo_id() {
  case "$1" in
    tmp|snapshots) return 0 ;;
    *) return 1 ;;
  esac
}

is_sudo_path() {
  case "${1:-}" in
    /Library/*) return 0 ;;
    *) return 1 ;;
  esac
}

# resolve_path <p>：去掉尾斜杠、解析父目录真实路径后拼回 basename（末段符号链接保留不解析）。
# 用于 --projects-keep 归一化、--orphans-delete 校验与候选比对；不做删除。
resolve_path() {
  local p="${1:-}" dir base
  [[ -n "$p" ]] || { printf '%s' ""; return 0; }
  while [[ "$p" == */ && ${#p} -gt 1 ]]; do p="${p%/}"; done
  dir=$(cd -- "$(dirname -- "$p")" 2>/dev/null && pwd -P) || { printf '%s' "$p"; return 0; }
  base=$(basename -- "$p")
  printf '%s/%s' "$dir" "$base"
}

# keep_matches <path>：该路径是否命中 --projects-keep（两侧都已归一化）
keep_matches() {
  local r p
  [[ ${#PROJECTS_KEEP_LIST[@]} -gt 0 ]] || return 1
  r=$(resolve_path "${1:-}")
  for p in "${PROJECTS_KEEP_LIST[@]}"; do
    [[ "$r" == "$p" ]] && return 0
  done
  return 1
}

# rm_tree <path>：先 chmod -R u+w 再删，专治 Go/pnpm 等只读缓存目录；返回 rm 退出码
rm_tree() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 1
  chmod -R u+w -- "$p" 2>/dev/null || true
  rm -rf -- "$p" 2>/dev/null
}

# rm_nul_stdin：从 stdin 读 NUL 分隔路径逐个 rm -rf --，失败数写全局 RM_FAILS
# （必须在当前 shell 调用：`rm_nul_stdin < <(find ... -print0)`，不能走管道）
rm_nul_stdin() {
  local p
  RM_FAILS=0
  while IFS= read -r -d '' p; do
    [[ -n "$p" ]] || continue
    rm -rf -- "$p" 2>/dev/null || RM_FAILS=$((RM_FAILS + 1))
  done
}

# rm_tree_stdin：同 rm_nul_stdin，但每个条目走 rm_tree
rm_tree_stdin() {
  local p
  RM_FAILS=0
  while IFS= read -r -d '' p; do
    [[ -n "$p" ]] || continue
    rm_tree "$p" || RM_FAILS=$((RM_FAILS + 1))
  done
}

# count_real_fails <err_text>：统计错误行时排除 TCC 的 "Operation not permitted"
# （正常终端里这类是已知跳过，不应让整项变 partial；其它错误仍算失败）。
# 但若预检已判定在 workspace-write 沙箱里（$HOME 下不可写），同一句 EPERM 更可能是
# 沙箱拒绝删除 —— 这时不能当跳过，否则「一个字节没删却报 done」，所以全量计数。
count_real_fails() {
  if [[ "${SANDBOX_SUSPECT:-0}" == "1" ]]; then
    printf '%s\n' "${1:-}" | grep -c . || true
  else
    printf '%s\n' "${1:-}" | grep -v 'Operation not permitted' | grep -c . || true
  fi
}

# sum_top_kb <dir> [find 条件...]：对 dir 下顶层、匹配条件的条目逐个 du -sk 求和（KB）
sum_top_kb() {
  local dir="$1"; shift
  find "$dir" -mindepth 1 -maxdepth 1 "$@" -exec du -sk {} + 2>/dev/null \
    | awk '{s+=$1} END{printf "%d", s+0}'
}

# project_roots_list：把 --projects-roots（冒号分隔）展开为每行一个
project_roots_list() {
  local r old_ifs="$IFS"
  IFS=':'
  for r in $PROJECT_ROOTS; do printf '%s\n' "$r"; done
  IFS="$old_ifs"
}

# prevalidate_orphan_delete_paths：--orphans-delete 的结构校验（不依赖扫描结果）
# 绝对路径 / 拒绝尾斜杠 / 拒绝 .. 与 . 组件 / 必须存在 / 必须是某个扫描根的直接子项；
# 通过后把 ORPHANS_DELETE_LIST 换成归一化路径，并按 resolved 判断是否需 sudo。
prevalidate_orphan_delete_paths() {
  local p pdir base resolved root_real _ok _root out=""
  while IFS= read -r p; do
    p="${p%$'\r'}"
    [[ -z "$p" ]] && continue
    case "$p" in
      /*) ;;
      *) echo "--orphans-delete 需要绝对路径: ${p}" >&2; exit 1 ;;
    esac
    if [[ "$p" == */ ]]; then
      echo "--orphans-delete 不接受以 / 结尾的路径（会被当成整目录）: ${p}" >&2
      exit 1
    fi
    case "/${p}/" in
      *"/../"*|*"/./"*)
        echo "--orphans-delete 路径不能包含 '..' 或 '.' 组件: ${p}" >&2
        exit 1 ;;
    esac
    if [[ ! -e "$p" ]]; then
      echo "--orphans-delete 路径不存在: ${p}" >&2
      exit 1
    fi
    base=$(basename -- "$p")
    pdir=$(cd -- "$(dirname -- "$p")" 2>/dev/null && pwd -P) || {
      echo "--orphans-delete 父目录不可访问: ${p}" >&2
      exit 1
    }
    resolved="${pdir}/${base}"
    _ok=0
    for _root in "${ORPHAN_ROOTS[@]}"; do
      root_real=$(cd -- "$_root" 2>/dev/null && pwd -P) || continue
      if [[ "$resolved" == "$root_real" ]]; then
        echo "--orphans-delete 不能指向扫描根本身: ${p}" >&2
        exit 1
      fi
      [[ "$pdir" == "$root_real" ]] && _ok=1
    done
    if [[ "$_ok" != "1" ]]; then
      echo "--orphans-delete 只接受扫描根的直接子项: ${p}" >&2
      exit 1
    fi
    is_sudo_path "$resolved" && ORPHANS_NEED_SUDO=1
    out="${out}${resolved}"$'\n'
  done < <(printf '%s\n' "$ORPHANS_DELETE_LIST")
  ORPHANS_DELETE_LIST="$out"
}

# validate_orphan_delete_candidates：--orphans-delete 的路径必须出现在本次扫描候选里（扫描后调用）
validate_orphan_delete_candidates() {
  local p c found
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    found=0
    if [[ ${#ORPHAN_CANDIDATE_PATHS[@]} -gt 0 ]]; then
      for c in "${ORPHAN_CANDIDATE_PATHS[@]}"; do
        [[ "$c" == "$p" ]] && { found=1; break; }
      done
    fi
    if [[ "$found" != "1" ]]; then
      echo "--orphans-delete 路径不在本次残留候选里（可能已安装、已被过滤或名字写错）: ${p}" >&2
      exit 1
    fi
  done < <(printf '%s\n' "$ORPHANS_DELETE_LIST")
}

usage() {
  # 用 printf 而不是 here-doc：here-doc 需要临时文件，只读沙箱/无 TMPDIR 时会直接失败
  # （实测 `cannot create temp file for here document`，连 --help 都跑不出来）。
  printf '%s\n' \
    "用法: $0 [--clean] [--dry-run] [--only <ids>] [--skip <ids>] [--all] [--top [N]] [--json]" \
    "" \
    "  默认              只查询并输出各目录占用，不删除任何内容" \
    "  --clean           执行实际清理" \
    "  --dry-run         配合 --clean：只打印计划命令与预计可删量，不实际删除" \
    "  --only <ids>      只清理指定项（英文逗号分隔），如 --only caches,logs；可重复传，会合并" \
    "  --skip <ids>      排除指定项，如 --skip docker,gradle；可重复传，会合并" \
    "  --all             显式表示「清理全部项」；不带 --only/--skip 时 --clean 必须配 --all" \
    "  --list            列出全部清理项编码与说明后退出（加 --json 输出机器可读版）" \
    "  --top [N]         只读：列出 \$HOME 下最占空间的 N 项（目录与 >100MB 文件），默认 10，较慢" \
    "  --json            stdout 只输出 JSON（进度信息走 stderr），便于 agent 解析" \
    "  --cache-age-days N     caches/tmp 的 mtime 阈值（默认 1）" \
    "  --log-age-days N       logs 的 mtime 阈值（默认 7）" \
    "  --projects-age-days N  projects 只处理该天数前未改动的构建产物（默认 30）" \
    "  --dshtmp-age-days N    dshtmp 只清空该天数前未改动的 .dsh/tmp（默认 0 = 全部可删）" \
    "  --projectcache-age-days N  projectcache 只处理该天数前未改动的目录（默认 3）" \
    "  --projects-roots <p>   projects/dshtmp/projectcache 的扫描根（默认 \$HOME/Documents，可用冒号分隔多个）" \
    "  --projects-keep <p>    projects/dshtmp/projectcache 里排除的具体路径（可重复传）" \
    "  --orphans-list         卸载残留：显示全部疑似条目（默认只显示最大的 15 项）" \
    "  --orphans-age-days N   卸载残留：只列出该天数前未改动的条目（默认 0 = 不限）" \
    "  --orphans-delete <p>   卸载残留：要删除的绝对路径（可重复传；必须是扫描根直接子项且在本次候选里）" \
    "" \
    "可用编码: $KNOWN_IDS" \
    "需 sudo 的项: tmp snapshots；--orphans-delete 指向 /Library 下路径时也需 sudo" \
    "  （agent 环境会被跳过，命令交给用户自己的终端执行）" \
    "orphans 例外：只报告；删除只认 --orphans-delete 点名的路径，不参与 --all"
}

list_items() {
  local id
  for id in $KNOWN_IDS; do
    if is_sudo_id "$id"; then
      printf '  %-12s %s\n' "$id" "$(item_label "$id")    [需 sudo]"
    else
      printf '  %-12s %s\n' "$id" "$(item_label "$id")"
    fi
    printf '  %-12s   %s\n' "" "$(item_desc "$id")"
  done
  printf '%s\n' \
    "" \
    "不含在本脚本里的：" \
    "  opencode 数据库瘦身：由 disk-cleanup skill 走 cleanup-opencode.sh（先备份、先闭库、再 VACUUM）" \
    "  iOS 设备备份、聊天记录、虚拟机镜像等用户数据：只报告大小与路径，不代删"
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
    --cache-age-days|--log-age-days|--projects-age-days|--dshtmp-age-days|--projectcache-age-days)
      if [[ $# -lt 2 ]] || ! is_pos_int "$2"; then echo "$1 需要一个非负整数天数" >&2; exit 1; fi
      case "$1" in
        --cache-age-days) CACHE_AGE_DAYS="$2" ;;
        --log-age-days) LOG_AGE_DAYS="$2" ;;
        --projects-age-days) PROJECTS_AGE_DAYS="$2" ;;
        --dshtmp-age-days) DSHTMP_AGE_DAYS="$2" ;;
        --projectcache-age-days) PROJECTCACHE_AGE_DAYS="$2" ;;
      esac
      shift 2 ;;
    --cache-age-days=*|--log-age-days=*|--projects-age-days=*|--dshtmp-age-days=*|--projectcache-age-days=*)
      # 等号形式：--cache-age-days=3（值仍必须是非负整数）
      _age_val="${1#*=}"
      _age_flag="${1%%=*}"
      if ! is_pos_int "$_age_val"; then echo "${_age_flag} 需要一个非负整数天数" >&2; exit 1; fi
      case "$_age_flag" in
        --cache-age-days) CACHE_AGE_DAYS="$_age_val" ;;
        --log-age-days) LOG_AGE_DAYS="$_age_val" ;;
        --projects-age-days) PROJECTS_AGE_DAYS="$_age_val" ;;
        --dshtmp-age-days) DSHTMP_AGE_DAYS="$_age_val" ;;
        --projectcache-age-days) PROJECTCACHE_AGE_DAYS="$_age_val" ;;
      esac
      shift ;;
    --projects-roots)
      if [[ $# -lt 2 ]]; then echo "$1 需要一个路径" >&2; exit 1; fi
      PROJECT_ROOTS="$2"; shift 2 ;;
    --projects-keep)
      if [[ $# -lt 2 ]]; then echo "$1 需要一个路径" >&2; exit 1; fi
      PROJECTS_KEEP_LIST+=("$(resolve_path "$2")"); shift 2 ;;
    --top)
      TOP_N=10
      if [[ $# -ge 2 ]] && is_pos_int "$2"; then TOP_N="$2"; shift; fi
      shift ;;
    --top=*) TOP_N="${1#--top=}"; is_pos_int "$TOP_N" || { echo "--top 需要整数" >&2; exit 1; }; shift ;;
    --orphans-list) ORPHANS_LIST_ALL=1; shift ;;
    --orphans-age-days)
      if [[ $# -lt 2 ]] || ! is_pos_int "$2"; then echo "--orphans-age-days 需要一个非负整数天数" >&2; exit 1; fi
      ORPHANS_AGE_DAYS="$2"; shift 2 ;;
    --orphans-delete)
      if [[ $# -lt 2 ]]; then echo "--orphans-delete 需要一个绝对路径" >&2; exit 1; fi
      ORPHANS_DELETE_LIST="${ORPHANS_DELETE_LIST}${2}"$'\n'; shift 2 ;;
    --orphans-delete=*)
      ORPHANS_DELETE_LIST="${ORPHANS_DELETE_LIST}${1#--orphans-delete=}"$'\n'; shift ;;
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

# --orphans-delete 的结构校验（不依赖扫描）：绝对路径 / 拒绝尾斜杠 / 拒绝 .. 与 . 组件 /
# 必须存在 / 必须是某个扫描根的直接子项。候选归属在扫描完成后另行校验。
if [[ -n "$ORPHANS_DELETE_LIST" ]]; then
  prevalidate_orphan_delete_paths
fi

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
  NEED_SUDO=0
  want tmp && NEED_SUDO=1
  want snapshots && NEED_SUDO=1
  if [[ "$ORPHANS_NEED_SUDO" == "1" ]] && want orphans; then NEED_SUDO=1; fi
  if [[ "$NEED_SUDO" == "1" ]]; then
    if sudo -v 2>/dev/null; then
      SUDO_OK=1
    else
      echo "⚠️ 无法获取 sudo 权限（可能已取消或环境无 TTY）。" >&2
      echo "   涉及 /tmp、Time Machine 或 /Library 下残留的步骤将被跳过；请在用户自己的终端执行对应 --only 命令。" >&2
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
JSON_CODE_IDS=()           # codes[] 聚合：与 items[] 并行的明细（同编码可能多条）
JSON_CODE_STATUSES=()
JSON_CODE_TOTALS=()
JSON_CODE_DELS=()
REPORT_JSON=""             # 「只报告：系统级大户」的 reports[] 片段
REPORT_SEP=""

# status_rank <status>：codes[] 聚合时取最严重的状态（数字越大越严重）
status_rank() {
  case "${1:-}" in
    failed) echo 7 ;;
    partial) echo 6 ;;
    done) echo 5 ;;
    dry-run) echo 4 ;;
    reported) echo 3 ;;
    queried) echo 2 ;;
    skipped-sudo) echo 1 ;;
    *) echo 0 ;;   # skipped-unselected / 未知
  esac
}

# build_codes_json：把 items[] 的并行明细按 id 聚合为 codes[]（首次出现顺序）
build_codes_json() {
  local i j id total del count rank best best_rank out="" sep="" found
  for ((i = 0; i < ${#JSON_CODE_IDS[@]}; i++)); do
    id="${JSON_CODE_IDS[$i]}"
    found=0
    for ((j = 0; j < i; j++)); do
      [[ "${JSON_CODE_IDS[$j]}" == "$id" ]] && { found=1; break; }
    done
    [[ "$found" -eq 1 ]] && continue
    total=0; del=0; count=0; best=""; best_rank=0
    for ((j = i; j < ${#JSON_CODE_IDS[@]}; j++)); do
      [[ "${JSON_CODE_IDS[$j]}" == "$id" ]] || continue
      count=$((count + 1))
      total=$((total + ${JSON_CODE_TOTALS[$j]:-0}))
      del=$((del + ${JSON_CODE_DELS[$j]:-0}))
      rank=$(status_rank "${JSON_CODE_STATUSES[$j]}")
      if [[ "$rank" -gt "$best_rank" ]]; then
        best_rank="$rank"
        best="${JSON_CODE_STATUSES[$j]}"
      fi
    done
    out="${out}${sep}{\"id\":\"$(json_esc "$id")\",\"status\":\"${best}\",\"total_kb\":${total},\"deletable_kb\":${del},\"items\":${count}}"
    sep=","
  done
  printf '%s' "$out"
}

# report_add <json 片段>：追加到 reports[]（A6 只报告段用）
report_add_json() {
  REPORT_JSON="${REPORT_JSON}${REPORT_SEP}${1}"
  REPORT_SEP=","
}

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
  JSON_CODE_IDS+=("$id")
  JSON_CODE_STATUSES+=("$status")
  JSON_CODE_TOTALS+=("${STEP_TOTAL_KB:-0}")
  JSON_CODE_DELS+=("${STEP_DEL_KB:-0}")
  # estimated_freed_kb：只统计确定成功（done）的项；partial 表示有失败条目，
  # 实际删了多少无法确认，用 deletable_kb 估算会把「rm 全失败」也报成已释放
  case "$status" in
    done) ESTIMATED_FREED_KB=$((ESTIMATED_FREED_KB + ${STEP_DEL_KB:-0})) ;;
  esac
}

# run <编码> <描述> <内部函数或命令...>
# 未勾选 → 跳过；需 sudo 但无权限 → 跳过并打印可交接的命令；
# 仅当 --clean 时执行；再配 --dry-run 则只打印 PLAN_CMD（调用方负责设置）。
# 执行时函数/命令的 stdout 统一 >&2（保证 --json 模式下 stdout 只有 JSON）。
run() {
  local id="$1" desc="$2" rc=0 status; shift 2
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
  # 只有 --json 需要把外部命令/函数输出赶到 stderr；文本模式保持原样（便于管道消费）
  if [[ "$JSON" == "1" ]]; then
    "$@" >&2 || rc=$?
  else
    "$@" || rc=$?
  fi
  if [[ "$rc" -eq 0 ]]; then
    REPORT_STEPS+=("${desc}${STEP_NOTE:+（${STEP_NOTE}）}")
    json_add "$id" "$desc" "done"
  else
    HAD_FAILURE=1
    FAILED_COUNT=$((FAILED_COUNT + 1))
    status="partial"
    # 命令直接不存在（127）记为 failed；其余（有失败条目）为 partial
    [[ "$rc" -eq 127 ]] && status="failed"
    SKIPPED_STEPS+=("${desc}（${STEP_NOTE:-命令返回 ${rc}，可能部分未删}）")
    json_add "$id" "$desc" "$status"
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

# delete_aged <path> <days>：删除 mtime 超过 days 天的条目，失败数写进 STEP_NOTE；
# 有失败条目返回 1（供 run 记 partial）。
delete_aged() {
  local p="$1" d="$2" fails err
  [[ -e "$p" ]] || { say "      （路径不存在，跳过）"; STEP_NOTE="路径不存在"; return 0; }
  err=$(find "$p" -mindepth 1 -mtime +"$d" -delete 2>&1 >/dev/null || true)
  fails=$(count_real_fails "$err")
  fails="${fails:-0}"
  say "      删除完成；失败 ${fails} 条（受保护/正在使用的条目会留在原处）"
  STEP_NOTE="失败 ${fails} 条"
  [[ "$fails" -eq 0 ]]
}

# delete_aged_sudo：sudo 项的 mtime 清理（仅当 SUDO_OK=1 时会被调用）
delete_aged_sudo() {
  local p="$1" d="$2" fails err
  [[ -e "$p" ]] || { say "      （路径不存在，跳过）"; STEP_NOTE="路径不存在"; return 0; }
  err=$(sudo find "$p" -mindepth 1 -mtime +"$d" -delete 2>&1 >/dev/null || true)
  fails=$(count_real_fails "$err")
  fails="${fails:-0}"
  say "      删除完成；失败 ${fails} 条（系统占用的条目属正常）"
  STEP_NOTE="失败 ${fails} 条"
  [[ "$fails" -eq 0 ]]
}

# delete_whole <path>：整目录删除；失败返回 1
delete_whole() {
  local p="$1"
  if [[ ! -e "$p" ]]; then
    say "      （路径不存在，跳过）"
    STEP_NOTE="路径不存在"
    return 0
  fi
  if rm -rf -- "$p" 2>/dev/null; then
    say "      已删除 $p"
    STEP_NOTE="已删除"
    return 0
  fi
  say "      ⚠️ 未能完全删除 ${p}（可能受保护）"
  STEP_NOTE="删除失败（可能受保护）"
  return 1
}

# lower <str>：bash 3.2 没有 ${var,,}，统一走 tr
lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

# is_purge_cache <条目名>：已知纯缓存/更新器目录 → 整目录清理，不套 mtime 阈值。
# 判据：内容是仍可从服务端重新下载的副本（浏览器缓存、更新包）。
# 注意：这里只判「名字属于纯缓存」；Chrome 的真实缓存位于 Google/Chrome 子目录，
# 具体删哪一层由 cache_purge_targets 决定（orphans 跳过判断仍用本函数）。
is_purge_cache() {
  local n
  n=$(lower "$1")
  case "$n" in
    "microsoft edge"|"google"|"google/chrome"|"chromium"|"bravesoftware"|"vivaldi"|"opera"|"firefox") return 0 ;;
    *updater*|*-updater) return 0 ;;
    "com.apple.softwareupdate"|"com.apple.appstore"|"com.apple.appstoreagent") return 0 ;;
    "com.apple.safari"|"safari") return 0 ;;
  esac
  return 1
}

# cache_purge_targets <entry>：输出该顶层条目下要整删的路径（每行一个；不存在由调用方跳过）。
# Chrome 只删 $entry/Chrome，不删整个 Google（Google 下还有别的 App 数据）。
cache_purge_targets() {
  local entry="${1:-}" n
  [[ -n "$entry" ]] || return 0
  n=$(lower "$(basename -- "$entry")")
  case "$n" in
    "google") printf '%s\n' "${entry}/Chrome" ;;
    "microsoft edge"|"chromium"|"bravesoftware"|"vivaldi"|"opera"|"firefox") printf '%s\n' "$entry" ;;
    *updater*|*-updater) printf '%s\n' "$entry" ;;
    "com.apple.softwareupdate"|"com.apple.appstore"|"com.apple.appstoreagent") printf '%s\n' "$entry" ;;
    "com.apple.safari"|"safari") printf '%s\n' "$entry" ;;
  esac
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

# 沙箱预检（查询/清理都跑一次）：workspace-write 一类沙箱里 $HOME 下部分路径不可写，
# 删除会被拒绝。只提示、不改变退出码，但会置 SANDBOX_SUSPECT=1：
# 此时 "Operation not permitted" 不再当作 TCC 已知跳过（否则会假报 done）。
SANDBOX_SUSPECT=0
if [[ ! -w "$HOME/Library" || ! -w "$HOME/.Trash" ]]; then
  SANDBOX_SUSPECT=1
  say "⚠️ 当前进程对 \$HOME 下部分路径不可写（常见于 workspace-write 沙箱）。"
  say "   工作区外的删除会被拒绝；请改用可写沙箱执行，或把命令交给用户终端。"
  say ""
fi

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
  local p fails=0 n=0 err real skipped=0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    n=$((n + 1))
    if ! err=$(rm -rf -- "$p" 2>&1 >/dev/null); then
      real=$(count_real_fails "$err")
      if [[ "${real:-0}" -eq 0 ]]; then
        skipped=$((skipped + 1))   # TCC/沙箱 EPERM：已知跳过，不算失败
      else
        fails=$((fails + 1))
      fi
    fi
  done < <(printf '%s\n' "$CACHE_PURGE_LIST")
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    err=$(find "$p" -mindepth 1 -mtime +"$CACHE_AGE_DAYS" -delete 2>&1 >/dev/null || true)
    real=$(count_real_fails "$err")
    fails=$((fails + ${real:-0}))
  done < <(printf '%s\n' "$CACHE_AGED_LIST")
  say "      纯缓存整删 ${n} 个目录（失败 ${fails} 个；TCC/权限跳过 ${skipped} 个）；其余按 ${CACHE_AGE_DAYS} 天阈值清理"
  STEP_NOTE="整删 ${n} 个目录（失败 ${fails} 个，跳过 ${skipped} 个）"
  [[ "$fails" -eq 0 ]]
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
    purge_used=0
    purge_targets=$(cache_purge_targets "$entry")
    if [[ -n "$purge_targets" ]]; then
      while IFS= read -r tgt; do
        [[ -n "$tgt" ]] || continue
        [[ -e "$tgt" ]] || continue
        purge_used=1
        sz=$(du_kb "$tgt")
        CACHE_DEL_KB=$((CACHE_DEL_KB + sz))
        CACHE_PURGE_LIST="${CACHE_PURGE_LIST}${tgt}"$'\n'
        CACHE_PURGE_N=$((CACHE_PURGE_N + 1))
        CACHE_TOP="${CACHE_TOP}${sz}	${tgt#"$CACHE_DIR"/}（纯缓存，整删）"$'\n'
      done < <(printf '%s\n' "$purge_targets")
    fi
    if [[ "$purge_used" == "0" ]]; then
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
  out=$(find "$FOLDERS_USER_DIR/T" -mindepth 1 -mtime +7 -delete 2>&1 >/dev/null || true)
  fails=$((fails + $(count_real_fails "$out")))
  out=$(find "$FOLDERS_USER_DIR/C" -mindepth 1 -mtime +7 -delete 2>&1 >/dev/null || true)
  fails=$((fails + $(count_real_fails "$out")))
  # X：只删顶层条目（code_sign_clone 整个目录 + 7 天前条目）。-maxdepth 1 -delete 对
  # 非空目录会静默空转，所以必须列出来逐个 rm -rf。
  rm_nul_stdin < <(find "$FOLDERS_USER_DIR/X" -mindepth 1 -maxdepth 1 \
      \( -name '*code_sign_clone*' -o -mtime +7 \) -print0 2>/dev/null)
  fails=$((fails + RM_FAILS))
  # T/go-build*：同样是顶层目录，整棵删
  rm_nul_stdin < <(find "$FOLDERS_USER_DIR/T" -mindepth 1 -maxdepth 1 \
      -type d -name 'go-build*' -mtime +1 -print0 2>/dev/null)
  fails=$((fails + RM_FAILS))
  say "      T/C/X 与 go-build 清理完成；失败 ${fails} 条（受保护/正在使用的条目会留在原处）"
  STEP_NOTE="失败 ${fails} 条"
  [[ "$fails" -eq 0 ]]
}

if [[ -z "$FOLDERS_USER_DIR" ]]; then
  say "  ⚠️ 未定位到当前用户的 /var/folders 容器目录，跳过本步清理。"
else
  say "  当前用户容器目录：$FOLDERS_USER_DIR"
  VF_TOTAL_KB=$(du_kb "$FOLDERS_USER_DIR")
  # 测量与删除谓词一致：T/C 用 mtime 文件求和；X 与 go-build 用「会被删的顶层条目」du 求和
  VF_DEL_KB=$(( $(subset_kb "$FOLDERS_USER_DIR/T" 7) + $(subset_kb "$FOLDERS_USER_DIR/C" 7) + $(sum_top_kb "$FOLDERS_USER_DIR/X" \( -name '*code_sign_clone*' -o -mtime +7 \)) + $(sum_top_kb "$FOLDERS_USER_DIR/T" -type d -name 'go-build*' -mtime +1) ))
  say "  目录总量: $(human "$VF_TOTAL_KB") / 本次可删（T/C/X 7 天前，顶层条目实测）: $(human "$VF_DEL_KB")"
  STEP_TOTAL_KB="$VF_TOTAL_KB"
  STEP_DEL_KB="$VF_DEL_KB"
  STEP_PATH="$FOLDERS_USER_DIR"
  PLAN_CMD="find ${FOLDERS_USER_DIR}/T -mindepth 1 -mtime +7 -delete; find ${FOLDERS_USER_DIR}/C -mindepth 1 -mtime +7 -delete; find ${FOLDERS_USER_DIR}/X -mindepth 1 -maxdepth 1 \\( -name '*code_sign_clone*' -o -mtime +7 \\) -print0 | xargs -0 rm -rf --; find ${FOLDERS_USER_DIR}/T -mindepth 1 -maxdepth 1 -type d -name 'go-build*' -mtime +1 -print0 | xargs -0 rm -rf --"
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
  local fails=0 n=0 left=0 p
  # 用 NUL 分隔遍历，覆盖 .Trash 里的隐藏项（glob * 不会匹配 dotfile）
  while IFS= read -r -d '' p; do
    n=$((n + 1))
    rm -rf -- "$p" 2>/dev/null || fails=$((fails + 1))
  done < <(find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  # 回读：仍有条目（隐藏/删不掉/并发写入）计入失败
  while IFS= read -r -d '' p; do
    left=$((left + 1))
  done < <(find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  [[ "$left" -gt "$fails" ]] && fails="$left"
  say "      清空完成（含隐藏项，共 ${n} 项）；未能删除 ${fails} 项（可能被占用）"
  STEP_NOTE="未能删除 ${fails} 项"
  [[ "$fails" -eq 0 ]]
}
if [[ -d "$HOME/.Trash" ]]; then
  TRASH_TOTAL_KB=$(du_kb "$HOME/.Trash")
  say "  占用大小: $(human "$TRASH_TOTAL_KB")"
  STEP_TOTAL_KB="$TRASH_TOTAL_KB"
  STEP_DEL_KB="$TRASH_TOTAL_KB"
  STEP_PATH="$HOME/.Trash"
  PLAN_CMD="find ${HOME}/.Trash -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +"
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

# ---------- 8. 大体积高危项目 [homebrew][cocoapods][gradle][xcode-ios][docker] ----------
say "----- 8. 大体积项目检测与清理 [homebrew][cocoapods][gradle][xcode-ios][docker] -----"

brew_cleanup() {
  local rc1=0 rc2=0
  say "  正在运行 brew cleanup --prune=all ..."
  brew cleanup --prune=all >&2 || rc1=$?
  brew autoremove >&2 || rc2=$?
  if [[ "$rc1" -eq 0 && "$rc2" -eq 0 ]]; then
    say "      Homebrew 缓存与旧版本已清理"
    STEP_NOTE="brew cleanup --prune=all + autoremove"
    return 0
  fi
  say "      ⚠️ brew cleanup/autoremove 返回非 0（可能权限或网络问题）"
  STEP_NOTE="brew cleanup/autoremove 失败"
  return 1
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
  run xcode-ios "清理旧 iOS 固件" delete_whole "$IPSW_DIR"
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
  run homebrew "清理 Homebrew 缓存与旧版本" brew_cleanup
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
  run cocoapods "清理 CocoaPods 缓存" delete_whole "$PODS_CACHE"
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
  run jvm "清理 Gradle 缓存" delete_whole "$GRADLE_CACHE"
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
  run xcode-ios "清理旧 iOS DeviceSupport 符号文件" delete_whole "$DEVSUPPORT"
else
  say "  ⑦ Xcode iOS DeviceSupport: 未找到"
fi

if command -v xcrun &> /dev/null; then
  say "  ⑧ 清理不可用的旧 iOS 模拟器 ..."
  STEP_TOTAL_KB=0; STEP_DEL_KB=0; STEP_PATH=""
  PLAN_CMD="xcrun simctl delete unavailable"
  run xcode-ios "删除不可用的旧模拟器" xcrun simctl delete unavailable
  SIM_CACHE="$HOME/Library/Developer/CoreSimulator/Caches"
  if [[ -d "$SIM_CACHE" ]]; then
    SIM_CACHE_KB=$(du_kb "$SIM_CACHE")
    say "      CoreSimulator/Caches: $(human "$SIM_CACHE_KB")"
    STEP_TOTAL_KB="$SIM_CACHE_KB"; STEP_DEL_KB="$SIM_CACHE_KB"; STEP_PATH="$SIM_CACHE"
    PLAN_CMD="rm -rf ${SIM_CACHE}"
    run xcode-ios "清理 CoreSimulator 缓存" delete_whole "$SIM_CACHE"
  fi
else
  say "  ⑧ 未安装 Xcode 命令行工具，跳过模拟器清理"
fi
say ""

# ---------- 9. 语言工具链与包管理器缓存 [node][go][python][rust][jvm] ----------
# 每个工具一个编码，可单独勾选清理；路径按工具分组，删除时只动所勾编码的路径。
say "----- 9. 语言工具链与包管理器缓存（安全可再生）[node][go][python][rust][jvm] -----"

# 按工具分组的可再生缓存目录（删除时每组独立 rm_tree）
NODE_CACHE_DIRS=(
  "$HOME/.npm/_npx"
  "$HOME/.npm/_cacache"
  "$HOME/.npm/_logs"
  "$HOME/.cache/yarn"
  "$HOME/.cache/bun"
  "$HOME/.bun/install/cache"
  "$HOME/.cache/node"
  "$HOME/.cache/puppeteer"
  "$HOME/.cache/codex-runtimes"
  "$HOME/.cache/opencode"
  "$HOME/Library/Caches/Yarn"
  "$HOME/Library/Caches/node-gyp"
  "$HOME/Library/Caches/electron"
  "$HOME/Library/Caches/ms-playwright"
  "$HOME/Library/Caches/Cypress"
)
GO_CACHE_DIRS=(
  "$HOME/go/pkg/mod/cache/download"
  "$HOME/Library/Caches/go-build"
  "$HOME/Library/Caches/goimports"
  "$HOME/Library/Caches/gopls"
  "$HOME/Library/Caches/golangci-lint"
)
PYTHON_CACHE_DIRS=(
  "$HOME/.cache/uv"
  "$HOME/Library/Caches/pip"
)
RUST_CACHE_DIRS=(
  "$HOME/.cargo/registry/cache"
)
JVM_CACHE_DIRS=(
  "$HOME/.m2/repository"
)
# 注意：Gradle 的 ~/.gradle/caches 在第 8 节由 gradle 步骤（同样归 jvm 编码）删除，
# 不放进本数组，避免同一路径被删两次。
PNPM_PMS="$HOME/Library/pnpm/package-manager-store"

# 兼容旧变量名（--json/外部引用若提及 SAFE_CACHE_DIRS 时可回溯）；此处只是合并视图，不再用于删除
SAFE_CACHE_DIRS=(
  "${NODE_CACHE_DIRS[@]}" "${GO_CACHE_DIRS[@]}" "${PYTHON_CACHE_DIRS[@]}"
  "${RUST_CACHE_DIRS[@]}" "${JVM_CACHE_DIRS[@]}" "$HOME/Library/Caches/Homebrew"
)

# toolcache_group <id> <desc> <dirs...>：按编码统计并清理一组目录；pnpm 的 store prune 与 PMS 单独附加
toolcache_group() {
  local id="$1" desc="$2"; shift 2
  local dirs=("$@") total=0 exist=0 sz d
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue
    sz=$(du_kb "$d")
    total=$((total + sz))
    exist=$((exist + 1))
    if [[ "$sz" -ge 1024 ]]; then
      say "    - $(human "$sz")  ${d/#$HOME/~}"
    fi
  done
  # pnpm 专属：package-manager-store（整删）+ store prune（回收未引用）
  if [[ "$id" == "node" ]]; then
    if [[ -d "$PNPM_PMS" ]]; then
      local pms; pms=$(du_kb "$PNPM_PMS")
      total=$((total + pms)); exist=$((exist + 1))
      say "    - $(human "$pms")  ~/Library/pnpm/package-manager-store（pnpm 工具版本仓库，删后重新下载）"
    fi
  fi
  PLAN_CMD="rm -rf <本组白名单目录>"
  [[ "$id" == "node" ]] && PLAN_CMD="rm -rf <本组白名单目录>; rm -rf ~/Library/pnpm/package-manager-store; pnpm store prune"
  STEP_TOTAL_KB="$total"; STEP_DEL_KB="$total"; STEP_PATH=""
  STEP_NOTE=""
  [[ "$id" == "node" ]] && STEP_NOTE="另含 pnpm store prune（仅回收未引用包）"
  say "  ${id}: 命中 ${exist} 个目录，合计 $(human "$total")"
  local fails=0
  clean_group() {
    local f=0 p
    for p in "${dirs[@]}"; do
      [[ -d "$p" ]] || continue
      rm_tree "$p" || f=$((f + 1))
    done
    if [[ "$id" == "node" ]]; then
      [[ -d "$PNPM_PMS" ]] && { rm_tree "$PNPM_PMS" || f=$((f + 1)); }
      prune_pnpm_store || true
    fi
    STEP_NOTE="失败 ${f} 个"
    return "$f"
  }
  run "$id" "$desc" clean_group
}

# corepack 在 Node 25+ 已不再随发行版分发：缺失时回落直接调用 pnpm。
prune_pnpm_store() {
  command -v pnpm >/dev/null 2>&1 || return 0
  if command -v corepack >/dev/null 2>&1; then
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack pnpm store prune
    return $?
  fi
  printf '%s\n' "  （未找到 corepack，改用 pnpm store prune）" >&2
  pnpm store prune
}

toolcache_group node "清理 Node 生态缓存（npm/yarn/bun/pnpm）" "${NODE_CACHE_DIRS[@]}"
toolcache_group go "清理 Go 缓存" "${GO_CACHE_DIRS[@]}"
toolcache_group python "清理 Python 缓存（uv/pip）" "${PYTHON_CACHE_DIRS[@]}"
toolcache_group rust "清理 Rust 缓存（cargo）" "${RUST_CACHE_DIRS[@]}"
toolcache_group jvm "清理 JVM 缓存（Maven/Gradle）" "${JVM_CACHE_DIRS[@]}"
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
  done < <(printf '%s\n' "$APPCACHE_LIST")
  say "      删除 ${n} 个目录，失败 ${fails} 个（app 正在写入的多半会失败，可退出 app 后重试）"
  STEP_NOTE="删除 ${n} 个目录，失败 ${fails} 个"
  [[ "$fails" -eq 0 ]]
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
  done < <(printf '%s\n' "$UPD_LIST")
  say "      删除 ${n} 个目录，失败 ${fails} 个"
  STEP_NOTE="删除 ${n} 个目录，失败 ${fails} 个"
  [[ "$fails" -eq 0 ]]
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
    [[ "$sz" -lt 10240 ]] && continue     # < 10MB 不入清单、不计可删量（与 appcache 一致）
    UPD_TOTAL_KB=$((UPD_TOTAL_KB + sz))
    UPD_LIST="${UPD_LIST}${d}"$'\n'
    UPD_TOP="${UPD_TOP}${sz}	${d#"$APPSUPPORT"/}"$'\n'
  done < <(printf '%s\n' "$UPD_FOUND")
  say "  本次可删合计: $(human "$UPD_TOTAL_KB")（>10 MB 的更新残留目录）"
  printf '%s' "$UPD_TOP" | sort -rn | head -8 | while IFS=$'\t' read -r kb nm; do
    [[ -n "${nm:-}" ]] && say "    - $(human "$kb")  ${nm}"
  done
  STEP_TOTAL_KB="$UPD_TOTAL_KB"
  STEP_DEL_KB="$UPD_TOTAL_KB"
  STEP_PATH="$APPSUPPORT"
  PLAN_CMD="rm -rf <上列 >10 MB 的 crx_cache / auto-updater / app-recovery-cache 目录>"
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
  done < <(printf '%s\n' "$PROJ_DEL_LIST")
  say "      删除 ${n} 个构建产物目录，失败 ${fails} 个"
  STEP_NOTE="删除 ${n} 个目录，失败 ${fails} 个"
  [[ "$fails" -eq 0 ]]
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
    mtime=$(stat -f '%m' "$d" 2>/dev/null || true)
    if [[ -z "$mtime" ]]; then
      # mtime 读不到就不判新旧：绝不进可删清单（宁可漏清，不可误删活跃项目）
      PROJ_TOP="${PROJ_TOP}${sz}	$(human "$sz")  ${d#"$HOME"/}  （mtime 读取失败，跳过）"$'\n'
      continue
    fi
    age_days=$(( ( $(date +%s) - mtime ) / 86400 ))
    if keep_matches "$d"; then
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
  done < <(printf '%s\n' "$PROJ_FOUND")
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

# ---------- 13. 项目内 .dsh/tmp 过程产物 [dshtmp] ----------
say "----- 13. 项目内 .dsh/tmp 过程产物 [dshtmp] -----"
say "  扫描根: ${PROJECT_ROOTS}（--projects-roots 可改；只清空内容、保留 .dsh/tmp 目录）"
clean_dshtmp() {
  local fails=0 n=0 d
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    n=$((n + 1))
    # rm_tree_stdin 内每个子项都会 chmod -R u+w，这里不再做外层整树 chmod（避免双份递归）
    rm_tree_stdin < <(find "$d" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    fails=$((fails + RM_FAILS))
    # 回读：目录仍在且为空才算成功
    if [[ -d "$d" ]] && [[ -z "$(find "$d" -mindepth 1 -maxdepth 1 -print 2>/dev/null | head -1)" ]]; then
      :
    else
      fails=$((fails + 1))
    fi
  done < <(printf '%s\n' "$DSHTMP_DEL_LIST")
  say "      清空 ${n} 个 .dsh/tmp 的内容（保留目录）；失败 ${fails} 个"
  STEP_NOTE="清空 ${n} 个目录，失败 ${fails} 个"
  [[ "$fails" -eq 0 ]]
}
DSHTMP_TOTAL_KB=0
DSHTMP_DEL_KB=0
DSHTMP_DEL_LIST=""
DSHTMP_TOP=""
DSHTMP_N=0
DSHTMP_DEL_N=0
while IFS= read -r root; do
  if [[ ! -d "$root" ]]; then
    say "  ⚠️ 扫描根不存在: $root"
    continue
  fi
  DSHTMP_FOUND=$(find "$root" -maxdepth 7 -type d -path '*/.dsh/tmp' -prune -print 2>/dev/null || true)
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    sz=$(du_kb "$d")
    [[ "$sz" -lt 10240 ]] && continue     # < 10MB 不进清单，减少噪音（与 appcache 一致）
    DSHTMP_N=$((DSHTMP_N + 1))
    DSHTMP_TOTAL_KB=$((DSHTMP_TOTAL_KB + sz))
    mtime=$(stat -f '%m' "$d" 2>/dev/null || true)
    if [[ -z "$mtime" ]]; then
      DSHTMP_TOP="${DSHTMP_TOP}${sz}	$(human "$sz")  ${d#"$HOME"/}  （mtime 读取失败，跳过）"$'\n'
      continue
    fi
    age_days=$(( ( $(date +%s) - mtime ) / 86400 ))
    [[ "$age_days" -lt 0 ]] && age_days=0
    if keep_matches "$d"; then
      DSHTMP_TOP="${DSHTMP_TOP}${sz}	$(human "$sz")  ${d#"$HOME"/}  （保留：--projects-keep）"$'\n'
      continue
    fi
    if [[ "$age_days" -ge "$DSHTMP_AGE_DAYS" ]]; then
      DSHTMP_DEL_KB=$((DSHTMP_DEL_KB + sz))
      DSHTMP_DEL_LIST="${DSHTMP_DEL_LIST}${d}"$'\n'
      DSHTMP_DEL_N=$((DSHTMP_DEL_N + 1))
      DSHTMP_TOP="${DSHTMP_TOP}${sz}	$(human "$sz")  ${d#"$HOME"/}  （${age_days} 天未改动，可删）"$'\n'
    else
      DSHTMP_TOP="${DSHTMP_TOP}${sz}	$(human "$sz")  ${d#"$HOME"/}  （${age_days} 天内有改动，跳过）"$'\n'
    fi
  done < <(printf '%s\n' "$DSHTMP_FOUND")
done < <(project_roots_list)
say "  命中 ${DSHTMP_N} 个 .dsh/tmp（≥10 MB），合计 $(human "$DSHTMP_TOTAL_KB")；其中可删（≥${DSHTMP_AGE_DAYS} 天，0=全部）$(human "$DSHTMP_DEL_KB")"
printf '%s' "$DSHTMP_TOP" | sort -rn | head -12 | while IFS=$'\t' read -r kb nm; do
  [[ -n "${nm:-}" ]] && say "    - ${nm}"
done
if [[ "$DSHTMP_N" -gt 12 ]]; then
  say "    …（仅显示最大的 12 项；完整清单用 --json）"
fi
say "  注：只清空 */.dsh/tmp 的内容并保留目录本身；不触碰同级 .dsh/docs。"
STEP_TOTAL_KB="$DSHTMP_TOTAL_KB"
STEP_DEL_KB="$DSHTMP_DEL_KB"
STEP_PATH=""
PLAN_CMD="清空 ${DSHTMP_DEL_N} 个 .dsh/tmp 的内容（保留目录；$(human "$DSHTMP_DEL_KB")）"
run dshtmp "清空项目内 .dsh/tmp 过程产物（保留目录）" clean_dshtmp
say ""

# ---------- 14. 项目内编译缓存 [projectcache] ----------
say "----- 14. 项目内编译缓存（Go/pnpm 等）[projectcache] -----"
say "  扫描根: ${PROJECT_ROOTS}（--projects-roots 可改；整目录删，只处理 ${PROJECTCACHE_AGE_DAYS} 天前未改动的目录）"
clean_projectcache() {
  local fails=0 n=0 p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    n=$((n + 1))
    rm_tree "$p" || fails=$((fails + 1))
  done < <(printf '%s\n' "$PROJCACHE_DEL_LIST")
  say "      删除 ${n} 个项目编译缓存目录，失败 ${fails} 个"
  STEP_NOTE="删除 ${n} 个目录，失败 ${fails} 个"
  [[ "$fails" -eq 0 ]]
}
PROJCACHE_TOTAL_KB=0
PROJCACHE_DEL_KB=0
PROJCACHE_DEL_LIST=""
PROJCACHE_TOP=""
PROJCACHE_N=0
while IFS= read -r root; do
  if [[ ! -d "$root" ]]; then
    say "  ⚠️ 扫描根不存在: $root"
    continue
  fi
  PROJCACHE_FOUND=$(find "$root" -maxdepth 7 -type d \
      \( -name .gocache -o -name .tmp-gocache -o -name .pnpm-store -o -name .corepack \
         -o -path '*/.dsh/gocache' \) \
      -prune -print 2>/dev/null || true)
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    sz=$(du_kb "$d")
    [[ "$sz" -lt 51200 ]] && continue      # < 50MB 不列为候选（与 projects 一致）
    PROJCACHE_N=$((PROJCACHE_N + 1))
    PROJCACHE_TOTAL_KB=$((PROJCACHE_TOTAL_KB + sz))
    mtime=$(stat -f '%m' "$d" 2>/dev/null || true)
    if [[ -z "$mtime" ]]; then
      PROJCACHE_TOP="${PROJCACHE_TOP}${sz}	$(human "$sz")  ${d#"$HOME"/}  （mtime 读取失败，跳过）"$'\n'
      continue
    fi
    age_days=$(( ( $(date +%s) - mtime ) / 86400 ))
    [[ "$age_days" -lt 0 ]] && age_days=0
    if keep_matches "$d"; then
      PROJCACHE_TOP="${PROJCACHE_TOP}${sz}	$(human "$sz")  ${d#"$HOME"/}  （保留：--projects-keep）"$'\n'
      continue
    fi
    if [[ "$age_days" -ge "$PROJECTCACHE_AGE_DAYS" ]]; then
      PROJCACHE_DEL_KB=$((PROJCACHE_DEL_KB + sz))
      PROJCACHE_DEL_LIST="${PROJCACHE_DEL_LIST}${d}"$'\n'
      PROJCACHE_TOP="${PROJCACHE_TOP}${sz}	$(human "$sz")  ${d#"$HOME"/}  （${age_days} 天未改动，可删）"$'\n'
    else
      PROJCACHE_TOP="${PROJCACHE_TOP}${sz}	$(human "$sz")  ${d#"$HOME"/}  （${age_days} 天内有改动，跳过）"$'\n'
    fi
  done < <(printf '%s\n' "$PROJCACHE_FOUND")
done < <(project_roots_list)
say "  命中 ${PROJCACHE_N} 个编译缓存目录（≥50 MB），合计 $(human "$PROJCACHE_TOTAL_KB")；其中可删（≥${PROJECTCACHE_AGE_DAYS} 天未改动）$(human "$PROJCACHE_DEL_KB")"
printf '%s' "$PROJCACHE_TOP" | sort -rn | head -12 | while IFS=$'\t' read -r kb nm; do
  [[ -n "${nm:-}" ]] && say "    - ${nm}"
done
if [[ "$PROJCACHE_N" -gt 12 ]]; then
  say "    …（仅显示最大的 12 项；完整清单用 --json）"
fi
say "  注：删除后下次构建/install 需要重跑；.gocache 等是只读目录，删除前会先 chmod u+w。"
STEP_TOTAL_KB="$PROJCACHE_TOTAL_KB"
STEP_DEL_KB="$PROJCACHE_DEL_KB"
STEP_PATH=""
PLAN_CMD="rm -rf <上列项目编译缓存目录>"
run projectcache "清理项目内编译缓存（可再生成）" clean_projectcache
say ""

# ---------- 15. 已卸载应用的残留 [orphans] ----------
say "----- 15. 已卸载应用的残留文件 [orphans] -----"
# 判定方式：macOS 没有「谁装过什么」的台账，只能反推——
#   已装名单 = /Applications、/System/Applications、~/Applications、Input Methods 下所有 .app 的
#              bundle id + 名称（plutil 读 Info.plist，不依赖 Spotlight，索引关了也能用）
#   候选     = ORPHAN_ROOTS 下的顶层条目
#   残留     = 候选里既匹配不上已装名单、也不属于系统共用组件的条目
# 这是启发式：App 可能装在别处（例如项目目录里的 Ollama.app）、目录名可能与 App 名无关、
# 更新器 / helper 的 bundle id 也和主 App 不同。所以本项**只报告**，
# 删除只认 --orphans-delete 点名的路径，避免「按名字猜」把活数据删了。

# alnum_only_var <str>：只留字母数字，结果写进全局 ALNUM_OUT。
# 不用 $(norm ...)：命令替换会为每个条目 fork 一个子 shell，扫描 1600 个条目就是 1600 次 fork。
ALNUM_OUT=""
alnum_only_var() {
  local s="${1:-}" i c
  ALNUM_OUT=""
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-z0-9]) ALNUM_OUT="${ALNUM_OUT}${c}" ;;
    esac
  done
}

# orphan_skip <小写原名>：系统/共用组件不参与判定——它们不是「某个 App 的残留」
orphan_skip() {
  case "$1" in
    com.apple|com.apple.*|group.com.apple|group.com.apple.*) return 0 ;;
    apple|"app store"|appstore|"script editor"|btserver|livefsd|proapps|ilifemediabrowser) return 0 ;;
    cloudkit|familycircle|crashreporter|diagnosticreports|install|installation|dws) return 0 ;;
    # /Library 下的系统自身配置，不是任何 App 的残留
    systemconfiguration|logging|opendirectory|directoryservice|xsan|security|audio) return 0 ;;
    org.cups.*) return 0 ;;   # 系统打印配置
    homebrew|pnpm|go-build|ms-playwright|cocoapods) return 0 ;;   # 已由 node/go/homebrew/cocoapods 等工具编码覆盖
  esac
  return 1
}

# 反查用的是「集合串」而不是逐条循环：条目数 × 已装 App 数会到十万级比较，
# 用 while read 拼进程替换会把这个函数拖成十几秒（实测）。这里统一
# "|a|b|c|" 形式的集合串 + glob 判断，纯内建、零 fork。
APP_ID_SET="|"       # 已装 App 的 bundle id（小写）
APP_SEG_SET="|"      # bundle id 的段（≥6 字符，剔除 desktop/helper 之类通用段）
APP_NAME_SET="|"     # 已装 App 名（只留 a-z0-9）
APP_TOKEN_SET="|"    # 已装 App 名按空格/标点切出的词（≥4 字符），用于 Code ⊂ Visual Studio Code
APP_NAME_PREFIX_SET="|"  # 已装 App 名自身的所有前缀（≥4 字符），用于「条目比 App 名短」：Sogou ⊂ SogouInput
APP_VENDORS=""       # bundle id 前两段（com.tencent、party.mihomo），识别「同一厂商的 helper」

# bundle id 里过于通用的段不能拿来反推归属，否则「StepFun Desktop」会被其它 App 的 ".desktop" 掩盖
is_generic_seg() {
  case "$1" in
    desktop|client|helper|update|updater|service|shared|plugin|widget|launcher|extension) return 0 ;;
    framework|runtime|electron|binary|server|daemon|installer|preferences|application) return 0 ;;
  esac
  return 1
}

load_installed_apps() {
  local root app bid nm id seg tok raw_name old_ifs v1 v2 rest i
  for root in "/Applications" "/System/Applications" "$HOME/Applications" \
              "/Library/Input Methods" "$HOME/Library/Input Methods"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      bid=$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null) || bid=""
      raw_name=$(lower "$(basename "$app" .app)")
      if [[ -n "$bid" ]]; then
        id=$(lower "$bid")
        APP_ID_SET="${APP_ID_SET}${id}|"
        v1="${id%%.*}"
        rest="${id#*.}"
        if [[ "$rest" == *.* ]]; then
          v2="${rest%%.*}"
          APP_VENDORS="${APP_VENDORS}${v1}.${v2}"$'\n'
        fi
        # 段（com.bilibili.bilibiliPC → bilibili / bilibilipc）：认「目录名 = 厂商/产品名」
        old_ifs="$IFS"; IFS='.'
        for seg in $id; do
          [[ ${#seg} -ge 6 ]] || continue
          is_generic_seg "$seg" && continue
          APP_SEG_SET="${APP_SEG_SET}${seg}|"
        done
        IFS="$old_ifs"
      fi
      alnum_only_var "$raw_name"; nm="$ALNUM_OUT"
      if [[ -n "$nm" ]]; then
        APP_NAME_SET="${APP_NAME_SET}${nm}|"
        i=4
        while [[ "$i" -le "${#nm}" ]]; do
          APP_NAME_PREFIX_SET="${APP_NAME_PREFIX_SET}${nm:0:i}|"
          i=$((i + 1))
        done
      fi
      old_ifs="$IFS"; IFS=' .-_'
      for tok in $raw_name; do
        [[ ${#tok} -ge 4 ]] && APP_TOKEN_SET="${APP_TOKEN_SET}${tok}|"
      done
      IFS="$old_ifs"
    done < <(find "$root" -maxdepth 3 -name '*.app' -prune -print 2>/dev/null)
  done
}

# entry_is_installed <小写原名> <名字归一串>：命中返回 0（= 属于已装 App，不是残留）
entry_is_installed() {
  local lc="$1" nm="$2" cur t p i comp old_ifs
  # 1) bundle id：完全相等 / 子 bundle（com.x.y ↔ com.x.y.helper）/ 以段开头（bilibili、mihomo-party）
  cur="$lc"
  while :; do
    t="${cur#"${cur%%[a-z0-9]*}"}"     # 去掉开头的非字母数字（@deepseek-ai → deepseek-ai）
    [[ -n "$t" ]] || t="$cur"
    [[ "$APP_ID_SET" == *"|${t}|"* ]] && return 0
    [[ "$APP_SEG_SET" == *"|${t}|"* ]] && return 0
    case "$cur" in
      *[.-]*) cur="${cur%[.-]*}" ;;
      *) break ;;
    esac
  done
  # 2) 名字：完全相等 / 条目以 App 名开头（LarkShell ⊃ lark）/ 条目是 App 名的前缀
  #    （Sogou ⊂ SogouInput，≥4 字符才认）/ 条目是 App 名的独立词（Code）
  if [[ -n "$nm" ]]; then
    [[ "$APP_NAME_SET" == *"|${nm}|"* ]] && return 0
    [[ "$APP_TOKEN_SET" == *"|${nm}|"* ]] && return 0
    [[ "$APP_NAME_PREFIX_SET" == *"|${nm}|"* ]] && return 0   # 条目比 App 名短：Sogou ⊂ SogouInput
    i=${#nm}
    while [[ "$i" -ge 4 ]]; do                                 # 条目比 App 名长：LarkShell ⊃ lark
      [[ "$APP_NAME_SET" == *"|${nm:0:i}|"* ]] && return 0
      i=$((i - 1))
    done
  fi
  # 3) 条目中的某一段就是 App 名/名字前缀，视为它的组件
  #    （dev.orbstack.orbstack.privhelper ⊃ OrbStack、com.sogou.SogouTaskManager ⊃ SogouInput）
  old_ifs="$IFS"
  IFS='.-'
  for comp in $lc; do
    comp="${comp#"${comp%%[a-z0-9]*}"}"   # 去掉开头的非字母数字（@leros → leros）
    if [[ ${#comp} -ge 4 ]] && { [[ "$APP_NAME_SET" == *"|${comp}|"* ]] \
         || [[ "$APP_TOKEN_SET" == *"|${comp}|"* ]] \
         || [[ "$APP_NAME_PREFIX_SET" == *"|${comp}|"* ]]; }; then
      IFS="$old_ifs"
      return 0
    fi
  done
  IFS="$old_ifs"
  # 4) helper/daemon：与已装 App 同厂商前缀，视为它的组件（party.mihomo.helper）
  case "$lc" in
    *helper*|*daemon*|*.agent|*.service|*.xpc|*.plugin)
      while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        [[ "$lc" == "$p".* ]] && return 0
      done < <(printf '%s\n' "$APP_VENDORS")
      ;;
  esac
  return 1
}

load_installed_apps
ORPHAN_NOW=$(date +%s)
ORPHAN_TOTAL_KB=0
ORPHAN_N=0
ORPHAN_UNKNOWN=0
ORPHAN_ROWS=""
for root in "${ORPHAN_ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  root_real=$(cd -- "$root" 2>/dev/null && pwd -P) || root_real="$root"
  ORPHAN_PATHS=()
  ORPHAN_NAMES=()
  for entry in "$root"/*; do
    [[ -e "$entry" ]] || continue
    ORPHAN_PATHS+=("$entry")
    ORPHAN_NAMES+=("${entry##*/}")
  done
  [[ ${#ORPHAN_PATHS[@]} -eq 0 ]] && continue
  # 一个目录只 fork 一次 tr：逐条目 `tr`/`basename` 会把扫描拖到 50 秒级（实测）
  ORPHAN_LOWER=$(printf '%s\n' "${ORPHAN_NAMES[@]}" | tr '[:upper:]' '[:lower:]')
  oi=0
  while IFS= read -r lc; do
    entry="${ORPHAN_PATHS[$oi]}"
    base="${ORPHAN_NAMES[$oi]}"
    oi=$((oi + 1))
    lc="${lc%.plist}"
    alnum_only_var "$lc"; nm="$ALNUM_OUT"
    orphan_skip "$lc" && continue
    # ~/Library/Caches 里「已知纯缓存/更新器」由 caches 编码负责，这里不重复报
    [[ "$root" == "$HOME/Library/Caches" ]] && is_purge_cache "$base" && continue
    entry_is_installed "$lc" "$nm" && continue
    # 目录名恰好是 $PATH 上的命令（codex、gitkraken 的 gk、pdfcpu 等 CLI）：
    # 这类是命令行工具的数据目录，不是「卸载了 GUI App」的残留，不列入
    case "$lc" in
      *[!a-z0-9_-]*) ;;
      *) command -v "$lc" >/dev/null 2>&1 && continue ;;
    esac
    # 归一化候选路径：父目录取真实路径 + 原 basename（末段符号链接不解析）
    resolved="${root_real}/${base}"
    if [[ -f "$resolved" ]]; then
      kb=$(( ($(stat -f '%z' "$resolved" 2>/dev/null || printf '0') + 1023) / 1024 ))
    else
      kb=$(du -sk "$resolved" 2>/dev/null | awk '{print $1}')
      # 读不到大小就记「未知」，不能当 0：Group Containers 常见 Operation not permitted
      [[ -z "$kb" ]] && ORPHAN_UNKNOWN=$((ORPHAN_UNKNOWN + 1))
    fi
    mtime=$(stat -f '%m' "$resolved" 2>/dev/null || printf '0')
    mtime="${mtime:-0}"
    age=$(( ( ORPHAN_NOW - mtime ) / 86400 ))
    [[ "$age" -lt 0 ]] && age=0
    [[ "$ORPHANS_AGE_DAYS" -gt 0 && "$age" -lt "$ORPHANS_AGE_DAYS" ]] && continue
    flags=""
    is_sudo_path "$resolved" && flags="需 sudo"
    [[ -z "$kb" ]] && flags="${flags:+${flags}，}大小未知"
    ORPHAN_N=$((ORPHAN_N + 1))
    [[ -n "$kb" ]] && ORPHAN_TOTAL_KB=$((ORPHAN_TOTAL_KB + kb))
    ORPHAN_CANDIDATE_PATHS+=("$resolved")
    ORPHAN_ROWS="${ORPHAN_ROWS}${kb:-0}	${resolved}	${age}	${flags}"$'\n'
  done < <(printf '%s\n' "$ORPHAN_LOWER")
done

# --orphans-delete 的候选归属校验：必须在本次扫描命中的候选里（JSON candidates 同一套）
if [[ -n "$ORPHANS_DELETE_LIST" ]]; then
  validate_orphan_delete_candidates
fi

say "  扫描根 ${#ORPHAN_ROOTS[@]} 个，命中 ${ORPHAN_N} 项疑似残留，合计 $(human "$ORPHAN_TOTAL_KB")"
if [[ "$ORPHAN_UNKNOWN" -gt 0 ]]; then
  say "  ⚠️ 另有 ${ORPHAN_UNKNOWN} 项大小读不到（TCC/权限拒绝），未计入合计——按未知处理，不是 0。"
fi
if [[ "$ORPHAN_N" -eq 0 ]]; then
  say "  未发现疑似残留。"
else
  SHOW_N="$ORPHANS_MAX"
  [[ "$ORPHANS_LIST_ALL" == "1" ]] && SHOW_N="$ORPHAN_N"
  say "  按体积排序（显示 ${SHOW_N} 项；--orphans-list 看全部）:"
  printf '%s' "$ORPHAN_ROWS" | sort -t$'\t' -k1,1 -rn | head -n "$SHOW_N" | \
  while IFS=$'\t' read -r kb p age flags; do
    [[ -n "${p:-}" ]] || continue
    say "    - $(human "$kb")  ${p/#$HOME/~}  （${age} 天未改动${flags:+，$flags}）"
  done
fi
say "  判据是「已装 App 名单 vs 目录名」的反推，不是系统卸载记录：可能误报（App 装在别处）或漏报。"
say "  只报告、不自动删除，也不参与 --all；确认后按路径删："
say "    bash $0 --clean --only orphans --orphans-delete <路径> [--orphans-delete <路径> ...]"
say "  反查某个 id 是否真的没有 App：mdfind \"kMDItemCFBundleIdentifier == '<bundle-id>'\""

json_orphans() {
  local status="$1" obj cands="" sep="" kb p age flags sudo
  obj=$(printf '{"id":"orphans","label":"%s","status":"%s","total_kb":%s,"deletable_kb":0' \
    "$(json_esc "$(item_label orphans)")" "$status" "$ORPHAN_TOTAL_KB")
  obj="${obj},\"unknown_size\":${ORPHAN_UNKNOWN}"
  obj="${obj},\"note\":\"$(json_esc "只报告；删除用 --orphans-delete <路径> 逐条指定")\""
  while IFS=$'\t' read -r kb p age flags; do
    [[ -n "${p:-}" ]] || continue
    sudo=false
    is_sudo_path "$p" && sudo=true
    cands="${cands}${sep}{\"path\":\"$(json_esc "$p")\",\"kb\":${kb:-0},\"age_days\":${age:-0},\"sudo\":${sudo}}"
    sep=","
  done < <(printf '%s\n' "$ORPHAN_ROWS")
  JSON_ITEMS+=("${obj},\"candidates\":[${cands}]}")
  JSON_CODE_IDS+=("orphans")
  JSON_CODE_STATUSES+=("$status")
  JSON_CODE_TOTALS+=("$ORPHAN_TOTAL_KB")
  JSON_CODE_DELS+=(0)
}

clean_orphans() {
  local p n=0 fails=0 sudo_n=0
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if is_sudo_path "$p" && [[ "$SUDO_OK" != "1" ]]; then
      say "      [跳过·需 sudo] ${p}"
      sudo_n=$((sudo_n + 1))
      continue
    fi
    if is_sudo_path "$p"; then
      sudo rm -rf -- "$p" 2>/dev/null && n=$((n + 1)) || fails=$((fails + 1))
    else
      rm -rf -- "$p" 2>/dev/null && n=$((n + 1)) || fails=$((fails + 1))
    fi
  done < <(printf '%s\n' "$ORPHANS_DELETE_LIST")
  STEP_NOTE="删除 ${n} 项，失败 ${fails} 项"
  [[ "$sudo_n" -gt 0 ]] && STEP_NOTE="${STEP_NOTE}，${sudo_n} 项待 sudo"
  say "      完成：删除 ${n} 项，失败 ${fails} 项，待 sudo ${sudo_n} 项"
  if [[ "$sudo_n" -gt 0 ]]; then
    say "      需在用户自己的终端执行："
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      is_sudo_path "$p" && say "        sudo rm -rf ${p}"
    done < <(printf '%s\n' "$ORPHANS_DELETE_LIST")
  fi
  [[ "$fails" -eq 0 ]]
}

run_orphans() {
  if [[ "$CLEAN" == "1" ]] && ! want orphans; then
    LAST_RUN_SELECTED=0
    mark_unselected orphans
    say "   [跳过] 卸载残留（未勾选：orphans）"
    json_orphans "skipped-unselected"
    return 0
  fi
  LAST_RUN_SELECTED=1
  if [[ -z "$ORPHANS_DELETE_LIST" ]]; then
    if [[ "$CLEAN" == "1" ]]; then
      say "   [未删] 勾了 orphans 但没给 --orphans-delete 路径：本次只报告，不删除。"
      SKIPPED_STEPS+=("卸载残留：只报告未删除（需 --orphans-delete 点名路径）")
      json_orphans "reported"
    else
      say "   [查询] 卸载残留只做报告（删除需 --clean + --orphans-delete）"
      json_orphans "queried"
    fi
    return 0
  fi
  if [[ "$CLEAN" != "1" ]]; then
    say "   [查询] 已给出 --orphans-delete 路径，但未加 --clean，本次不删除"
    json_orphans "queried"
    return 0
  fi
  ORPHAN_DEL_N=0
  while IFS= read -r p; do
    [[ -n "$p" ]] && ORPHAN_DEL_N=$((ORPHAN_DEL_N + 1))
  done < <(printf '%s\n' "$ORPHANS_DELETE_LIST")
  if [[ "$DRY_RUN" == "1" ]]; then
    say "   [预览] 将删除 ${ORPHAN_DEL_N} 项（已校验：扫描根直接子项 + 本次候选）："
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      if is_sudo_path "$p"; then say "      sudo rm -rf ${p}"; else say "      rm -rf ${p}"; fi
    done < <(printf '%s\n' "$ORPHANS_DELETE_LIST")
    json_orphans "dry-run"
    return 0
  fi
  say "   [执行] 删除 --orphans-delete 指定的 ${ORPHAN_DEL_N} 项残留"
  if clean_orphans; then
    REPORT_STEPS+=("删除 ${ORPHAN_DEL_N} 项卸载残留（${STEP_NOTE}）")
    json_orphans "done"
  else
    HAD_FAILURE=1
    FAILED_COUNT=$((FAILED_COUNT + 1))
    SKIPPED_STEPS+=("删除 ${ORPHAN_DEL_N} 项卸载残留（${STEP_NOTE}）")
    json_orphans "partial"
  fi
}
run_orphans
say ""

# ---------- 16. 只报告：系统级大户（只读，不代删） ----------
say "----- 16. 只报告：系统级大户（只读，不代删） -----"
say "  本节只报告、不代删，也不改变退出码；读不到的项如实写「读不到」，不当 0。"

# report_line <id> <label> <kb> <note>：文本一行 + reports[] 一条（kb<0 表示读不到）
report_line() {
  local id="$1" label="$2" kb="$3" note="$4" json_note="$4"
  if [[ "$kb" -lt 0 ]]; then
    say "  ${label}: 读不到${note:+（${note}）}"
    # JSON 侧也要让 note 自解释：kb=-1 时统一带「读不到」前缀（已含则不重复）
    case "$json_note" in
      *读不到*) ;;
      "") json_note="读不到" ;;
      *) json_note="读不到（${json_note}）" ;;
    esac
  else
    say "  ${label}: $(human "$kb")${note:+（${note}）}"
  fi
  report_add_json "{\"id\":\"$(json_esc "$id")\",\"label\":\"$(json_esc "$label")\",\"kb\":${kb},\"note\":\"$(json_esc "$json_note")\"}"
}

# report_path <id> <label> <path> <ok_note> <unreadable_note>
report_path() {
  local id="$1" label="$2" path="$3" oknote="$4" badnote="$5" kb
  if [[ ! -e "$path" ]]; then
    report_line "$id" "$label" 0 "未找到"
    return 0
  fi
  kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
  if [[ -z "$kb" ]]; then
    report_line "$id" "$label" -1 "$badnote"
  else
    report_line "$id" "$label" "$kb" "$oknote"
  fi
}

# /cores：崩溃转储（root 属主；确认后可删，但本节不代删）
CORES_KB=$(du -sk /cores 2>/dev/null | awk '{print $1}')
CORES_N=$(find /cores -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ ! -d /cores ]]; then
  report_line cores "崩溃转储 /cores" 0 "未找到"
elif [[ -z "$CORES_KB" ]]; then
  report_line cores "崩溃转储 /cores" -1 "root 属主，读不到；确认后可删 sudo rm -f /cores/core.*（交用户终端）"
else
  report_line cores "崩溃转储 /cores" "$CORES_KB" "${CORES_N} 个 core 文件；确认后可删 sudo rm -f /cores/core.*（交用户终端）"
fi

# Apple Intelligence：三个位置，读不到按 SIP/TCC 处理
AI_TOTAL=0
AI_SEEN=0
AI_UNREADABLE=0
_ai_measure() {
  local p="$1" kb
  [[ -e "$p" ]] || return 0
  AI_SEEN=1
  kb=$(du -sk "$p" 2>/dev/null | awk '{print $1}')
  if [[ -z "$kb" ]]; then
    AI_UNREADABLE=1
  else
    AI_TOTAL=$((AI_TOTAL + kb))
  fi
}
for _ai_hit in /System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_*; do
  _ai_measure "$_ai_hit"   # 无匹配时是字面量，_ai_measure 里 -e 为假直接跳过
done
_ai_measure "/private/var/db/AppleIntelligencePlatform"
_ai_measure "$HOME/Library/Caches/com.apple.intelligence"
if [[ "$AI_SEEN" -eq 0 ]]; then
  report_line apple_intelligence "Apple Intelligence" 0 "未找到"
elif [[ "$AI_UNREADABLE" -eq 1 ]]; then
  report_line apple_intelligence "Apple Intelligence" -1 "SIP/TCC"
else
  report_line apple_intelligence "Apple Intelligence" "$AI_TOTAL" "系统托管，只能看不能删；入口「系统设置 → 通用 → 储存空间」"
fi

report_path vm "交换/睡眠镜像 /private/var/vm" "/private/var/vm" "不要手删，系统自行回收" "SIP/权限拒绝"
report_path diagnostics "系统统一日志 /private/var/db/diagnostics" "/private/var/db/diagnostics" "不要手删，系统自行轮转" "SIP/权限拒绝"
report_path uuidtext "系统统一日志 /private/var/db/uuidtext" "/private/var/db/uuidtext" "不要手删，系统自行轮转" "SIP/权限拒绝"
report_path updates "系统更新暂存 /Library/Updates" "/Library/Updates" "不要动" "权限拒绝"
report_path applications "应用体积 /Applications" "/Applications" "只报告；卸载不需要的 App 由用户决定" "权限拒绝"
report_path icloud "iCloud 本地副本 ~/Library/Mobile Documents" "$HOME/Library/Mobile Documents" "只报告；应用内「移除下载」" "权限拒绝"
say ""

# ---------- 17. 最占空间 Top N（只读） ----------
if [[ "$TOP_N" -gt 0 ]]; then
  say "----- 17. \$HOME 下最占空间的 ${TOP_N} 项（只读）-----"
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
DF_DELTA_KB=$((DISK_FREE_AFTER_KB - DISK_FREE_BEFORE_KB))
FINAL_EXIT=0
[[ "$HAD_FAILURE" == "1" ]] && FINAL_EXIT=1
# freed_kb：只有真实执行（--clean 且非 dry-run）才等于估算值；查询/预览恒为 0
FREED_KB=0
if [[ "$CLEAN" == "1" && "$DRY_RUN" != "1" ]]; then
  FREED_KB="$ESTIMATED_FREED_KB"
fi

if [[ "$CLEAN" != "1" ]]; then
  say "======================================"
  say "           清理报告"
  say "======================================"
  say "  （查询模式，仅统计占用，未执行任何清理）"
  if [[ "$DRY_RUN" == "1" ]]; then
    say ""
    say "  ⚠️ --dry-run 需配合 --clean 才有效；本次按只读查询执行，以上没有计划命令。"
  fi
  say ""
  say "  下一步：把上面的清理项按编码交给用户勾选，再执行"
  say "    bash $0 --clean --only <勾选的编码>"
  say "  预览所选：加 --dry-run；排除某项：用 --skip <编码>"
  say "======================================"
elif [[ "$DRY_RUN" == "1" ]]; then
  say "======================================"
  say "           清理报告（预览）"
  say "======================================"
  say "  预览模式，未实际清理；JSON 里 freed_kb / estimated_freed_kb 均为 0。"
  say "  确认上列计划命令与勾选一致后，去掉 --dry-run 执行。"
  say "======================================"
else
  say "======================================"
  say "           清理报告"
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
  if [[ "$HAD_FAILURE" == "1" ]]; then
    say "  有 ${FAILED_COUNT} 个清理项未完全成功（partial/failed，见下方「已勾选但未完成」）。"
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
  if [[ "$HAD_FAILURE" == "1" ]]; then
    say "退出码：1（存在 partial/failed 项）"
  fi
fi
say ""

if [[ "$JSON" == "1" ]]; then
  MODE="query"
  [[ "$CLEAN" == "1" ]] && MODE="clean"
  [[ "$DRY_RUN" == "1" ]] && MODE="dry-run"
  CODES_JSON=$(build_codes_json)
  printf '{"schema":1,"mode":"%s","exit_code":%s,"failed_count":%s,"disk":{"free_before_kb":%s,"free_after_kb":%s,"freed_kb":%s,"estimated_freed_kb":%s,"df_delta_kb":%s},"codes":[%s],"reports":[%s],"items":[' \
    "$MODE" "$FINAL_EXIT" "$FAILED_COUNT" "$DISK_FREE_BEFORE_KB" "$DISK_FREE_AFTER_KB" \
    "$FREED_KB" "$ESTIMATED_FREED_KB" "$DF_DELTA_KB" "$CODES_JSON" "$REPORT_JSON"
  sep=""
  if [[ ${#JSON_ITEMS[@]} -gt 0 ]]; then
    for it in "${JSON_ITEMS[@]}"; do
      printf '%s%s' "$sep" "$it"
      sep=","
    done
  fi
  printf ']}\n'
fi

exit "$FINAL_EXIT"
