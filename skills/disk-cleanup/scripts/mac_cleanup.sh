#!/usr/bin/env bash
# ============================================
# Mac 磁盘清理脚本（加固版）
# 用途：清理缓存、日志、临时文件、本地 Time Machine 快照等
# 相比初版的安全改进：
#   - 默认只查询，不删任何东西；--dry-run 只预览命令
#   - 每个清理项有稳定编码（--list 查看），--only / --skip 让用户决定最终清哪些
#   - 保留运行中程序可能占用的活动文件：只清理 mtime 过期内容，不再整体 rm -rf 日志
#   - 修正 Time Machine 快照计数（过滤标题行，避免误判）
#   - 开头用 sudo -v 预取权限并提示；取不到时明确跳过并给出用户终端命令
#   - 数量校验与更硬的 shell 选项
#   - 第 7 步：Xcode DerivedData（编码 xcode）
#   - 第 8 步：大体积高危项目（iOS 备份只提示、ipsw、Homebrew、
#     CocoaPods、Gradle、Docker、Xcode DeviceSupport、旧模拟器）
#   - 第 9 步：安全可再生缓存（npm/pnpm/go/uv/puppeteer/codex/opencode 等）
# 使用方法（本脚本随 disk-cleanup 技能分发，位于 skills/disk-cleanup/scripts/）：
#   1. 只查询占用（默认，不删任何东西）：bash skills/disk-cleanup/scripts/mac_cleanup.sh
#   2. 查看清理项编码：                 bash skills/disk-cleanup/scripts/mac_cleanup.sh --list
#   3. 预览所选清理项：                 bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --dry-run --only caches,logs
#   4. 清理所选（用户勾选后执行）：      bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --only caches,logs,trash
#   5. 不带 --only/--skip 时清理全部（只建议用户本人在终端手动使用）
# ============================================

set -uo pipefail

CLEAN=0
DRY_RUN=0
ONLY_RAW=""
SKIP_RAW=""

# 清理项编码：勾选单位。新增清理项时必须同时更新这里、references/cleanup.md 与 SKILL.md 的清单。
KNOWN_IDS="caches logs tmp varfolders snapshots trash xcode toolcache bigbuild docker"

usage() {
  cat <<EOF
用法: $0 [--clean] [--dry-run] [--only <ids>] [--skip <ids>] [--list]

  默认            只查询并输出各目录占用情况，不删除任何内容
  --clean         执行实际清理
  --dry-run       配合 --clean 时，只预览将清理的命令，不实际删除
  --only <ids>    只清理指定项（英文逗号分隔），如 --only caches,logs,tmp
  --skip <ids>    排除指定项，如 --skip docker,bigbuild
  --list          列出全部清理项编码与说明后退出

可用编码: $KNOWN_IDS
需 sudo 的项: tmp snapshots（agent 环境会被跳过，命令交给用户自己的终端执行）
EOF
}

list_items() {
  cat <<EOF
可用清理项（--only / --skip 用英文逗号分隔，可组合）:

  caches       用户缓存 ~/Library/Caches（仅 1 天前未改动）
  logs         用户日志 ~/Library/Logs（仅 7 天前的旧文件）
  tmp          /tmp 中 1 天前的临时内容                                    [需 sudo]
  varfolders   /var/folders 当前用户容器的过期残留（T/C/X、go-build）
  snapshots    Time Machine 本地快照                                      [需 sudo]
  trash        废纸篓（清空后不可恢复）
  xcode        Xcode DerivedData（下次构建会重建）
  toolcache    语言工具链/包管理器缓存（npm、pnpm、go、uv、playwright 等）
  bigbuild     ipsw、Homebrew、CocoaPods、Gradle、iOS DeviceSupport、旧模拟器
  docker       docker system prune -a（删未使用镜像、停止的容器、构建缓存）

不含在本脚本里的：
  opencode 数据库瘦身：由 disk-cleanup skill 走 cleanup-opencode.sh（先备份、先闭库、再 VACUUM）
  iOS 设备备份、聊天记录、虚拟机镜像等用户数据：只报告大小与路径，不代删
EOF
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

is_sudo_id() {
  case "$1" in
    tmp|snapshots) return 0 ;;
    *) return 1 ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) CLEAN=1; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    --only)
      if [[ $# -lt 2 ]]; then echo "--only 需要一个逗号分隔的编码列表" >&2; exit 1; fi
      ONLY_RAW="$2"; shift 2 ;;
    --only=*) ONLY_RAW="${1#--only=}"; shift ;;
    --skip)
      if [[ $# -lt 2 ]]; then echo "--skip 需要一个逗号分隔的编码列表" >&2; exit 1; fi
      SKIP_RAW="$2"; shift 2 ;;
    --skip=*) SKIP_RAW="${1#--skip=}"; shift ;;
    --list) list_items; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "未知参数: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

validate_ids "$ONLY_RAW" "--only"
validate_ids "$SKIP_RAW" "--skip"

ONLY_NORM=$(normalize_ids "$ONLY_RAW")
SKIP_NORM=$(normalize_ids "$SKIP_RAW")
ONLY_IDS=""
SKIP_IDS=""
[[ -n "$ONLY_NORM" ]] && ONLY_IDS=",${ONLY_NORM},"
[[ -n "$SKIP_NORM" ]] && SKIP_IDS=",${SKIP_NORM},"

# 默认（未加 --clean）只查询占用，不删除
if [[ "$CLEAN" != "1" ]]; then
  echo "当前为【查询模式】：仅统计占用，不删除任何内容。"
  echo "如需实际清理，请运行: $0 --clean --only <勾选的编码>"
  echo ""
  if [[ -n "$ONLY_IDS" || -n "$SKIP_IDS" ]]; then
    echo "⚠️ 未加 --clean，--only/--skip 不生效（本次仍是只读查询）。"
    echo ""
  fi
elif [[ -z "$ONLY_IDS" && -z "$SKIP_IDS" ]]; then
  echo "⚠️ 未指定 --only/--skip：将执行【全部】清理项。"
  echo "   给用户勾选场景请显式传 --only <ids>。"
  echo ""
fi

if [[ "$CLEAN" == "1" ]]; then
  if [[ -n "$ONLY_IDS" ]]; then
    echo "已选择清理项: $ONLY_NORM"
    [[ -n "$SKIP_IDS" ]] && echo "其中排除: $SKIP_NORM"
  elif [[ -n "$SKIP_IDS" ]]; then
    echo "已选择清理项: 全部，排除 $SKIP_NORM"
  fi
  echo ""
fi

# 预取 sudo 权限（仅 --clean 且非 dry-run，且所选清理项里确有 sudo 步骤时）
SUDO_OK=0
if [[ "$CLEAN" == "1" && "$DRY_RUN" != "1" ]]; then
  if want tmp || want snapshots; then
    if sudo -v 2>/dev/null; then
      SUDO_OK=1
    else
      echo "⚠️ 无法获取 sudo 权限（可能已取消或环境无 TTY）。"
      echo "   涉及 /tmp、Time Machine 的步骤将被跳过；请在用户自己的终端执行对应 --only 命令。" >&2
      echo ""
    fi
  fi
fi

UNSELECTED_IDS=""
LAST_RUN_SELECTED=1
run() {
  # run <编码> <描述> <命令...>
  # 未勾选 → 跳过；需 sudo 但无权限 → 跳过并打印用户终端命令；
  # 仅当 --clean 时执行；再配 --dry-run 则打印命令而不真正执行
  local id="$1" desc="$2"; shift 2
  if [[ "$CLEAN" == "1" ]] && ! want "$id"; then
    LAST_RUN_SELECTED=0
    mark_unselected "$id"
    echo "   [跳过] ${desc}（不在所选清理项：${id}）"
    return 0
  fi
  LAST_RUN_SELECTED=1
  if is_sudo_id "$id" && [[ "$CLEAN" == "1" && "$DRY_RUN" != "1" && "$SUDO_OK" != "1" ]]; then
    LAST_RUN_SELECTED=0
    echo "   [跳过] ${desc}（当前环境无 sudo 权限）"
    echo "      请在用户终端执行: $*"
    SKIPPED_STEPS+=("${desc}（需 sudo，已交给用户终端）")
    return 0
  fi
  if [[ "$CLEAN" == "1" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "   [预览] $desc"
      echo "      $*"
    else
      if "$@"; then
        REPORT_STEPS+=("$desc")
      else
        SKIPPED_STEPS+=("${desc}（命令返回非 0，可能部分未删）")
      fi
    fi
  else
    echo "   [查询] ${desc}（加 --clean 后执行）"
  fi
}

# done_msg <描述>：仅在 --clean、非 dry-run、且该步确实被选中并执行时输出，避免误导
done_msg() {
  if [[ "$CLEAN" != "1" || "$DRY_RUN" == "1" || "$LAST_RUN_SELECTED" != "1" ]]; then
    return 0
  fi
  echo "   ✅ 已执行：$1"
}

# human <KB>：把 KB 换算成可读大小（GB/MB）
human() {
  awk -v kb="$1" '
    BEGIN {
      if (kb >= 1048576) { printf "%.2f GB", kb/1048576 }
      else if (kb >= 1024) { printf "%.0f MB", kb/1024 }
      else if (kb != 0) { printf "%d KB", kb }
      else { printf "0" }
    }'
}

echo "======================================"
echo "   Mac 磁盘占用查询"
if [[ "$CLEAN" == "1" ]]; then
  echo "   *** 清理模式：正在执行清理 ***"
  [[ "$DRY_RUN" == "1" ]] && echo "   *** 预览模式：不会实际删除任何内容 ***"
else
  echo "   *** 查询模式：仅统计占用，不删除 ***"
fi
echo "======================================"
echo ""

echo "【磁盘当前可用空间】："
df -h / | awk 'NR==2{print "可用: " $4 " / 总量: " $2}'
# 记录清理前可用空间（KB），用于末段清理报告
DISK_FREE_BEFORE_KB=$(df -k / | awk 'NR==2{print $4}')
echo ""
# 清理报告累计：已执行 / 跳过的清理步骤描述
declare -a REPORT_STEPS=()
declare -a SKIPPED_STEPS=()

# ---------- 1. 统计用户缓存占用 [caches] ----------
echo "----- 1. 用户缓存 (~/Library/Caches) [caches] -----"
if [[ -d ~/Library/Caches ]]; then
  CACHE_SIZE_BEFORE=$(du -sh ~/Library/Caches 2>/dev/null | awk '{print $1}')
  echo "占用大小: ${CACHE_SIZE_BEFORE:-未知}"
  # 仅删除 1 天前未改动的缓存，避免误伤正在写入的应用缓存
  run caches "清理 1 天前未改动的用户缓存" \
    find ~/Library/Caches -mindepth 1 -mtime +1 -delete
  done_msg "清理用户缓存"
else
  echo "未找到 ~/Library/Caches，跳过"
fi
echo ""

# ---------- 2. 用户日志 [logs] ----------
echo "----- 2. 清理用户日志 (~/Library/Logs) [logs] -----"
if [[ -d ~/Library/Logs ]]; then
  LOG_SIZE_BEFORE=$(du -sh ~/Library/Logs 2>/dev/null | awk '{print $1}')
  echo "清理前大小: ${LOG_SIZE_BEFORE:-未知}"
  # 日志常被活动进程占用，仅清理 7 天前的内容，且保留目录结构
  run logs "清理 7 天前未改动的用户日志文件" \
    find ~/Library/Logs -type f -mtime +7 -delete
  done_msg "清理用户日志（仅删除 7 天前的旧日志）"
else
  echo "未找到 ~/Library/Logs，跳过"
fi
echo ""

# ---------- 3. /tmp 目录 [tmp] ----------
echo "----- 3. 清理 /tmp 临时目录 [tmp] -----"
TMP_SIZE_BEFORE=$(du -sh /tmp 2>/dev/null | awk '{print $1}')
echo "清理前大小: ${TMP_SIZE_BEFORE:-未知}"
# 只删 1 天前的陈旧临时文件，避免误删运行中进程正在使用的文件
run tmp "清理 /tmp 中 1 天前的临时内容" \
  sudo find /tmp -mindepth 1 -mtime +1 -delete
done_msg "清理 /tmp（系统占用文件可能无法删除，属正常现象）"
echo ""

# ---------- 4. /var/folders (用户和系统的临时/缓存容器) [varfolders] ----------
echo "----- 4. 检查 /var/folders 占用 [varfolders] -----"
# 统计总占用（部分子目录属 root，sudo 才能读全；用 -n 避免无 TTY 时卡在密码输入）
VF_SIZE=$(du -sh /var/folders 2>/dev/null | awk '{print $1}')
if [[ -z "$VF_SIZE" ]]; then
  VF_SIZE=$(sudo -n du -sh /var/folders 2>/dev/null | awk '{print $1}')
fi
echo "占用大小: ${VF_SIZE:-未知}"

# 定位“当前用户”的 /var/folders 容器目录：按目录属主 uid 是否等于当前 uid 判断。
# macOS 的 /var/folders 里，_zz 等属于系统/他人沙箱（root 拥有或被 TCC 保护，无权也不应访问），
# 只有当前用户自己那个容器目录（owner 就是自己）才可安全清理。这样既能跳过不该处理的系统
# 沙箱目录，避免刷出大量 Operation not permitted 噪音，也更通用（换机器/换用户都能用）。
MY_UID=$(id -u 2>/dev/null)
FOLDERS_USER_DIR=""
for _d in /var/folders/*/*/ ; do
  [ -d "$_d" ] || continue
  if [[ "$(stat -f '%u' "$_d" 2>/dev/null)" == "$MY_UID" ]]; then
    FOLDERS_USER_DIR="${_d%/}"
    break
  fi
done

echo "⚠️ /var/folders 是系统临时/缓存容器。仅清理当前用户（uid ${MY_UID:-?}）容器目录下的明确残留，"
echo "   系统/他人沙箱目录（如 _zz）会被跳过，避免权限噪音。"
if [[ -z "$FOLDERS_USER_DIR" ]]; then
  echo "   ⚠️ 未定位到当前用户的 /var/folders 容器目录，跳过本步清理。"
  done_msg "清理 /var/folders 残留缓存"
  echo ""
else
  echo "   当前用户容器目录：$FOLDERS_USER_DIR"
  # 仅在当前用户目录内清理（这些子目录属主是自己，无需 sudo）；
  # 仍可能个别为 TCC 保护目录，用 2>/dev/null 静默权限噪音。
  # T、C：保守清理 mtime≥7 天的过期缓存
  run varfolders "清理当前用户 /var/folders 中 T 目录 7 天以上的临时缓存" \
    find "$FOLDERS_USER_DIR/T" -mindepth 1 -mtime +7 -delete 2>/dev/null
  run varfolders "清理当前用户 /var/folders 中 C 目录 7 天以上的缓存" \
    find "$FOLDERS_USER_DIR/C" -mindepth 1 -mtime +7 -delete 2>/dev/null
  # X：app 更新后残留的代码签名克隆（macOS 会自动重建），以及 7 天前的旧目录
  run varfolders "清理当前用户 /var/folders 中 X 目录代码签名残留" \
    find "$FOLDERS_USER_DIR/X" -mindepth 1 -maxdepth 1 \
      \( -name "*code_sign_clone*" -o -mtime +7 \) -delete 2>/dev/null
  # go-build：Go 编译缓存（随机目录名，旧的即为残留，可再生）
  run varfolders "清理当前用户 /var/folders 中 go-build 编译缓存" \
    find "$FOLDERS_USER_DIR/T" -maxdepth 1 -type d -name "go-build*" -mtime +1 -delete 2>/dev/null
  done_msg "清理 /var/folders 残留缓存"
  echo ""
fi

# ---------- 5. Time Machine 本地快照 [snapshots] ----------
echo "----- 5. 清理本地 Time Machine 快照 [snapshots] -----"
# 过滤掉标题行 "Snapshots for volume ...:" 后再计数
SNAPSHOT_COUNT=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c '^com\.apple\.' || true)
if [[ "$SNAPSHOT_COUNT" =~ ^[0-9]+$ ]] && [ "$SNAPSHOT_COUNT" -gt 0 ]; then
  echo "发现 $SNAPSHOT_COUNT 个本地快照。"
  run snapshots "精简本地快照（快速模式）" \
    sudo tmutil thinlocalsnapshots / 999999999999 4
  done_msg "清理本地快照"
else
  echo "未发现本地快照，跳过"
fi
echo ""

# ---------- 6. 系统废纸篓 [trash] ----------
echo "----- 6. 清空废纸篓 [trash] -----"
if [[ -d ~/.Trash ]]; then
  run trash "清空废纸篓" find ~/.Trash -mindepth 1 -delete
  done_msg "清空废纸篓"
else
  echo "未找到废纸篓，跳过"
fi
echo ""

# ---------- 7. 开发者相关缓存 [xcode] ----------
echo "----- 7. 开发者工具缓存 [xcode] -----"
if [ -d ~/Library/Developer/Xcode/DerivedData ]; then
  XCODE_SIZE=$(du -sh ~/Library/Developer/Xcode/DerivedData 2>/dev/null | awk '{print $1}')
  echo "发现 Xcode DerivedData: $XCODE_SIZE"
  run xcode "清理 Xcode DerivedData" rm -rf ~/Library/Developer/Xcode/DerivedData
  done_msg "清理 Xcode DerivedData"
else
  echo "未找到 Xcode DerivedData，跳过"
fi

if command -v docker &> /dev/null; then
  echo "ℹ️ 检测到 Docker，如需清理请勾选 docker 项（docker system prune -a），或手动运行。"
fi
echo ""

# ---------- 8. 大体积高危项目（通常最占空间）[bigbuild] [docker] ----------
echo "----- 8. 大体积项目检测与清理 [bigbuild] [docker] -----"
echo "以下项目通常占空间最大，会先显示大小再决定处理方式。"
echo ""

# 8.1 iOS 设备备份 —— 涉及用户数据，只提示不自动删除
IOS_BACKUP=~/Library/Application\ Support/MobileSync/Backup
if [[ -d "$IOS_BACKUP" ]]; then
  IOS_SIZE=$(du -sh "$IOS_BACKUP" 2>/dev/null | awk '{print $1}')
  echo "① iOS 设备备份: ${IOS_SIZE:-未知}"
  echo "   路径: $IOS_BACKUP"
  echo "   ⚠️ 属用户数据，本脚本不自动删除。"
  echo "   如需清理：请在 iTunes/Finder「偏好设置 → 设备」中删除旧备份，"
  echo "   或手动确认后删除该目录下不再需要的子目录。"
else
  echo "① iOS 设备备份: 未找到（或本机未做过 iOS 备份）"
fi
echo ""

# 8.2 旧 iOS 固件 (ipsw) —— 安全删除
IPSW_DIR=~/Library/iTunes/iPhone\ Software\ Updates
if [[ -d "$IPSW_DIR" ]]; then
  IPSW_SIZE=$(du -sh "$IPSW_DIR" 2>/dev/null | awk '{print $1}')
  echo "② 旧 iOS 固件 (ipsw): ${IPSW_SIZE:-未知}"
  run bigbuild "清理旧 iOS 固件" rm -rf "$IPSW_DIR"
  done_msg "清理 ipsw 固件"
else
  echo "② 旧 iOS 固件: 未找到"
fi
echo ""

# 8.3 Homebrew 缓存 —— 安全
if command -v brew &> /dev/null; then
  BREW_SIZE=$(du -sh "$(brew --cache 2>/dev/null)" 2>/dev/null | awk '{print $1}')
  echo "③ Homebrew 缓存: ${BREW_SIZE:-未知}"
  run bigbuild "清理 Homebrew 缓存" brew cleanup --prune=all
  done_msg "清理 Homebrew 缓存"
else
  echo "③ Homebrew 缓存: 未安装 Homebrew，跳过"
fi
echo ""

# 8.4 CocoaPods 缓存 —— 安全（下次 pod install 会重新下载）
PODS_CACHE=~/Library/Caches/CocoaPods
if [[ -d "$PODS_CACHE" ]]; then
  PODS_SIZE=$(du -sh "$PODS_CACHE" 2>/dev/null | awk '{print $1}')
  echo "④ CocoaPods 缓存: ${PODS_SIZE:-未知}"
  run bigbuild "清理 CocoaPods 缓存" rm -rf "$PODS_CACHE"
  done_msg "清理 CocoaPods 缓存"
else
  echo "④ CocoaPods 缓存: 未找到"
fi
echo ""

# 8.5 Gradle 缓存 —— 安全（下次构建会重建）
GRADLE_CACHE=~/.gradle/caches
if [[ -d "$GRADLE_CACHE" ]]; then
  GRADLE_SIZE=$(du -sh "$GRADLE_CACHE" 2>/dev/null | awk '{print $1}')
  echo "⑤ Gradle 缓存: ${GRADLE_SIZE:-未知}"
  run bigbuild "清理 Gradle 缓存" rm -rf "$GRADLE_CACHE"
  done_msg "清理 Gradle 缓存"
else
  echo "⑤ Gradle 缓存: 未找到"
fi
echo ""

# 8.6 Docker 镜像/容器/构建缓存 —— 会删除停止的容器、未使用的镜像/网络/缓存
if command -v docker &> /dev/null; then
  echo "⑥ Docker 清理: 检测到 Docker"
  run docker "清理 Docker 无用资源 (system prune -a)" docker system prune -a --force
  done_msg "清理 Docker 无用资源 (system prune -a)"
else
  echo "⑥ Docker 清理: 未安装，跳过"
fi
echo ""

# 8.7 Xcode iOS DeviceSupport & 旧模拟器 —— 安全
DEVSUPPORT=~/Library/Developer/Xcode/iOS\ DeviceSupport
if [[ -d "$DEVSUPPORT" ]]; then
  DEV_SIZE=$(du -sh "$DEVSUPPORT" 2>/dev/null | awk '{print $1}')
  echo "⑦ Xcode iOS DeviceSupport: ${DEV_SIZE:-未知}"
  run bigbuild "清理旧 iOS DeviceSupport 符号文件" rm -rf "$DEVSUPPORT"
  done_msg "清理 DeviceSupport"
else
  echo "⑦ Xcode iOS DeviceSupport: 未找到"
fi

if command -v xcrun &> /dev/null; then
  echo "   清理不可用的旧 iOS 模拟器 ..."
  run bigbuild "删除不可用的旧模拟器" xcrun simctl delete unavailable
  done_msg "清理旧模拟器"
else
  echo "   未安装 Xcode 命令行工具，跳过模拟器清理"
fi
echo ""

# ---------- 9. 安全可再生缓存（语言工具链 / 包管理器）[toolcache] ----------
echo "----- 9. 语言工具链与包管理器缓存（安全可再生）[toolcache] -----"
echo "以下均为可再生缓存，删除后下次构建/安装会自动重建。"
echo ""

# 9.1 各语言/包管理器原生缓存目录（直接删除，重建无副作用）
declare -a SAFE_CACHE_DIRS=(
  "$HOME/.npm/_npx"
  "$HOME/.npm/_cacache"
  "$HOME/.cache/uv"
  "$HOME/.cache/puppeteer"
  "$HOME/.cache/node"
  "$HOME/.cache/codex-runtimes"
  "$HOME/.cache/opencode"
  "$HOME/Library/Caches/go-build"
  "$HOME/Library/Caches/goimports"
  "$HOME/Library/Caches/gopls"
  "$HOME/Library/Caches/golangci-lint"
  "$HOME/Library/Caches/ms-playwright"
  "$HOME/Library/Caches/pip"
  "$HOME/Library/Caches/node-gyp"
  "$HOME/Library/Caches/electron"
)
for d in "${SAFE_CACHE_DIRS[@]}"; do
  if [[ -d "$d" ]]; then
    sz=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
    echo "清理安全缓存: $(basename "$d") (${sz:-未知})"
    run toolcache "清理 $(basename "$d")" rm -rf "$d"
  fi
done

# 9.2 pnpm store：只回收未被引用的包（比 rm -rf 更安全）
if command -v pnpm &> /dev/null; then
  PNPM_STORE_SIZE=$(du -sh "$HOME/Library/pnpm" 2>/dev/null | awk '{print $1}')
  echo "pnpm store: ${PNPM_STORE_SIZE:-未知}"
  run toolcache "回收 pnpm store 中未引用的包" corepack pnpm store prune
  done_msg "回收 pnpm store 中未引用的包"
else
  echo "pnpm store: 未安装 pnpm，跳过"
fi
echo ""

# ---------- 清理报告 ----------
DISK_FREE_AFTER_KB=$(df -k / | awk 'NR==2{print $4}')
if [[ "$DRY_RUN" == "1" ]]; then
  echo "======================================"
  echo "           清理报告"
  echo "======================================"
  echo "  （预览模式，未实际清理，无释放数据）"
  echo "  以上为预览。确认与勾选一致后，运行 $0 --clean --only <勾选的编码> 实际清理。"
  echo "======================================"
  echo ""
elif [[ "$CLEAN" != "1" ]]; then
  echo "======================================"
  echo "           清理报告"
  echo "======================================"
  echo "  （查询模式，仅统计占用，未执行任何清理）"
  echo ""
  echo "  下一步：把上面的清理项按编码交给用户勾选，再执行"
  echo "    bash $0 --clean --only <勾选的编码>"
  echo "  预览所选：加 --dry-run；排除某项：用 --skip <编码>"
  echo "======================================"
  echo ""
else
  echo "======================================"
  echo "           清理报告"
  echo "======================================"
  FREED_KB=$((DISK_FREE_AFTER_KB - DISK_FREE_BEFORE_KB))
  echo "  磁盘可用空间：$(human "$DISK_FREE_BEFORE_KB") → $(human "$DISK_FREE_AFTER_KB")"
  if (( FREED_KB > 0 )); then
    echo "  本次实际释放：约 $(human "$FREED_KB")"
  elif (( FREED_KB == 0 && ${#REPORT_STEPS[@]} == 0 )); then
    echo "  本次没有实际执行的清理项，空间未变化。"
  elif (( FREED_KB < 0 )); then
    echo "  可用空间反而减少 $(human "$((-FREED_KB))")（清理期间可能有新写入，属正常）"
  else
    echo "  本次实际释放量小于 1 MB（df 精度限制），已执行项见下方。"
  fi
  echo ""
  if (( ${#REPORT_STEPS[@]} > 0 )); then
    echo "  实际执行的清理项（${#REPORT_STEPS[@]}）："
    printf '    ✅ %s\n' "${REPORT_STEPS[@]}"
  else
    echo "  （本次没有实际执行的清理项）"
  fi
  if [[ -n "$UNSELECTED_IDS" ]]; then
    echo ""
    echo "  未勾选（未执行）：$UNSELECTED_IDS"
  fi
  if (( ${#SKIPPED_STEPS[@]} > 0 )); then
    echo ""
    echo "  已勾选但未完成的清理项（${#SKIPPED_STEPS[@]}）："
    printf '    ⏭  %s\n' "${SKIPPED_STEPS[@]}"
  fi
  echo "======================================"
  echo ""
  echo "建议：重启一次 Mac，让系统重建必要的缓存文件，"
  echo "并再次前往 \"关于本机 → 储存空间\" 查看统计（该统计有延迟，需等待或重启后再看）。"
fi
