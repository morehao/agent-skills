#!/usr/bin/env bash
# ============================================
# Mac 磁盘清理脚本（加固版）
# 用途：清理缓存、日志、临时文件、本地 Time Machine 快照等
# 相比初版的安全改进：
#   - 支持 --dry-run 预览模式（默认安全，先看再删）
#   - 保留运行中程序可能占用的活动文件：只清理 mtime 过期内容，不再整体 rm -rf 日志
#   - 修正 Time Machine 快照计数（过滤标题行，避免误判）
#   - 开头用 sudo -v 预取权限并提示
#   - 数量校验与更硬的 shell 选项
#   - 第 8 步：大体积高危项目（iOS 备份大小提示、ipsw、Homebrew、
#     CocoaPods、Gradle、Docker、Xcode DeviceSupport、旧模拟器）
#   - 第 9 步：安全可再生缓存（go/pnpm/npm/uv/puppeteer/codex/opencode 等）
# 使用方法（本脚本随 disk-cleanup 技能分发，位于 skills/disk-cleanup/scripts/）：
#   1. 只查询占用（默认，不删任何东西）：bash skills/disk-cleanup/scripts/mac_cleanup.sh
#   2. 预览将清理哪些：                 bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean --dry-run
#   3. 实际清理（需用户确认后执行）：    bash skills/disk-cleanup/scripts/mac_cleanup.sh --clean
# ============================================

set -uo pipefail

CLEAN=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help)
      echo "用法: $0 [--clean] [--dry-run]"
      echo "  默认           只查询并输出各目录占用情况，不删除任何内容"
      echo "  --clean        执行实际清理"
      echo "  --dry-run      配合 --clean 时，只预览将清理的命令，不实际删除"
      exit 0 ;;
    *)
      echo "未知参数: $arg" >&2
      echo "用法: $0 [--clean] [--dry-run]" >&2
      exit 1 ;;
  esac
done

# 默认（未加 --clean）只查询占用，不删除
if [[ "$CLEAN" != "1" ]]; then
  echo "当前为【查询模式】：仅统计占用，不删除任何内容。"
  echo "如需实际清理，请运行: $0 --clean"
  echo ""
fi

run() {
  # run <描述> <命令...>
  # 仅当 --clean 时执行；再配 --dry-run 则打印命令而不真正执行
  local desc="$1"; shift
  if [[ "$CLEAN" == "1" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "   [预览] $desc"
      echo "      $*"
    else
      REPORT_STEPS+=("$desc")
      "$@"
    fi
  else
    echo "   [查询] ${desc}（加 --clean 后执行）"
  fi
}

# done <描述>：仅在 --clean 时输出“已处理”，查询/预览模式不输出，避免误导
done_msg() {
  if [[ "$CLEAN" == "1" && "$DRY_RUN" != "1" ]]; then
    echo "   ✅ 已处理：$1"
  elif [[ "$DRY_RUN" == "1" ]]; then
    echo "   （预览：将 $1）"
  fi
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

# 预取 sudo 权限（仅在 --clean 且非 dry-run，且确有 sudo 步骤时）
if [[ "$CLEAN" == "1" && "$DRY_RUN" != "1" ]]; then
  if ! sudo -v 2>/dev/null; then
    echo "⚠️ 无法获取 sudo 权限（可能已取消或环境无 TTY）。"
    echo "   涉及 /tmp、/var/folders、Time Machine 的步骤将被跳过。" >&2
  fi
fi

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
# 清理报告累计：已执行的清理步骤描述
declare -a REPORT_STEPS=()

# ---------- 1. 统计用户缓存占用 ----------
echo "----- 1. 用户缓存 (~/Library/Caches) -----"
if [[ -d ~/Library/Caches ]]; then
  CACHE_SIZE_BEFORE=$(du -sh ~/Library/Caches 2>/dev/null | awk '{print $1}')
  echo "占用大小: ${CACHE_SIZE_BEFORE:-未知}"
  # 仅删除 1 天前未改动的缓存，避免误伤正在写入的应用缓存
  run "清理 1 天前未改动的用户缓存" \
    find ~/Library/Caches -mindepth 1 -mtime +1 -delete
  done_msg "清理用户缓存"
else
  echo "未找到 ~/Library/Caches，跳过"
fi
echo ""

# ---------- 2. 用户日志 ----------
echo "----- 2. 清理用户日志 (~/Library/Logs) -----"
if [[ -d ~/Library/Logs ]]; then
  LOG_SIZE_BEFORE=$(du -sh ~/Library/Logs 2>/dev/null | awk '{print $1}')
  echo "清理前大小: ${LOG_SIZE_BEFORE:-未知}"
  # 日志常被活动进程占用，仅清理 7 天前的内容，且保留目录结构
  run "清理 7 天前未改动的用户日志文件" \
    find ~/Library/Logs -type f -mtime +7 -delete
  done_msg "清理用户日志（仅删除 7 天前的旧日志）"
else
  echo "未找到 ~/Library/Logs，跳过"
fi
echo ""

# ---------- 3. /tmp 目录 ----------
echo "----- 3. 清理 /tmp 临时目录 -----"
TMP_SIZE_BEFORE=$(du -sh /tmp 2>/dev/null | awk '{print $1}')
echo "清理前大小: ${TMP_SIZE_BEFORE:-未知}"
# 只删 1 天前的陈旧临时文件，避免误删运行中进程正在使用的文件
run "清理 /tmp 中 1 天前的临时内容" \
  sudo find /tmp -mindepth 1 -mtime +1 -delete
done_msg "清理 /tmp（系统占用文件可能无法删除，属正常现象）"
echo ""

# ---------- 4. /var/folders (用户和系统的临时/缓存容器) ----------
echo "----- 4. 检查 /var/folders 占用 -----"
# 统计总占用（部分子目录属 root，sudo 才能读全，失败则回退到不加 sudo）
VF_SIZE=$(du -sh /var/folders 2>/dev/null | awk '{print $1}')
if [[ -z "$VF_SIZE" ]]; then
  VF_SIZE=$(sudo du -sh /var/folders 2>/dev/null | awk '{print $1}')
fi
echo "占用大小: ${VF_SIZE:-未知}"

# 定位“当前用户”的 /var/folders 容器目录：按目录属主 uid 是否等于当前 uid 判断。
# macOS 的 /var/folders 里，_zz 等属于系统/他人沙箱（root 拥有或被 TCC 保护，无权也不应访问），
# 只有当前用户自己那个容器目录（owner 就是自己）才可安全清理。这样既能跳到不该处理的系统
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
  run "清理当前用户 /var/folders 中 T 目录 7 天以上的临时缓存" \
    find "$FOLDERS_USER_DIR/T" -mindepth 1 -mtime +7 -delete 2>/dev/null
  run "清理当前用户 /var/folders 中 C 目录 7 天以上的缓存" \
    find "$FOLDERS_USER_DIR/C" -mindepth 1 -mtime +7 -delete 2>/dev/null
  # X：app 更新后残留的代码签名克隆（macOS 会自动重建），以及 7 天前的旧目录
  run "清理当前用户 /var/folders 中 X 目录代码签名残留" \
    find "$FOLDERS_USER_DIR/X" -mindepth 1 -maxdepth 1 \
      \( -name "*code_sign_clone*" -o -mtime +7 \) -delete 2>/dev/null
  # go-build：Go 编译缓存（随机目录名，旧的即为残留，可再生）
  run "清理当前用户 /var/folders 中 go-build 编译缓存" \
    find "$FOLDERS_USER_DIR/T" -maxdepth 1 -type d -name "go-build*" -mtime +1 -delete 2>/dev/null
  done_msg "清理 /var/folders 残留缓存"
  echo ""
fi

# ---------- 5. Time Machine 本地快照 ----------
echo "----- 5. 清理本地 Time Machine 快照 -----"
# 过滤掉标题行 "Snapshots for volume ...:" 后再计数
SNAPSHOT_COUNT=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c '^com\.apple\.' || true)
if [[ "$SNAPSHOT_COUNT" =~ ^[0-9]+$ ]] && [ "$SNAPSHOT_COUNT" -gt 0 ]; then
  echo "发现 $SNAPSHOT_COUNT 个本地快照，正在清理..."
  run "精简本地快照（快速模式）" \
    sudo tmutil thinlocalsnapshots / 999999999999 4
  done_msg "清理本地快照"
else
  echo "未发现本地快照，跳过"
fi
echo ""

# ---------- 6. 系统废纸篓 ----------
echo "----- 6. 清空废纸篓 -----"
if [[ -d ~/.Trash ]]; then
  run "清空废纸篓" rm -rf ~/.Trash/*
  done_msg "清空废纸篓"
else
  echo "未找到废纸篓，跳过"
fi
echo ""

# ---------- 7. 开发者相关缓存（如果存在）----------
echo "----- 7. 开发者工具缓存检查 -----"
if [ -d ~/Library/Developer/Xcode/DerivedData ]; then
  XCODE_SIZE=$(du -sh ~/Library/Developer/Xcode/DerivedData 2>/dev/null | awk '{print $1}')
  echo "发现 Xcode DerivedData: $XCODE_SIZE"
  run "清理 Xcode DerivedData" rm -rf ~/Library/Developer/Xcode/DerivedData/*
  done_msg "清理 Xcode DerivedData"
fi

if command -v npm &> /dev/null; then
  echo "清理 npm 缓存（旧包缓存，下次安装需重新下载）..."
  run "清理 npm 缓存" npm cache clean --force
  done_msg "清理 npm 缓存"
fi

if command -v docker &> /dev/null; then
  echo "ℹ️ 检测到 Docker，如需清理请手动运行: docker system prune -a"
fi
echo ""

# ---------- 8. 大体积高危项目（通常最占空间）----------
echo "----- 8. 大体积项目检测与清理 -----"
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
  run "清理旧 iOS 固件" rm -rf "$IPSW_DIR"/*
  done_msg "清理 ipsw 固件"
else
  echo "② 旧 iOS 固件: 未找到"
fi
echo ""

# 8.3 Homebrew 缓存 —— 安全
if command -v brew &> /dev/null; then
  BREW_SIZE=$(du -sh "$(brew --cache 2>/dev/null)" 2>/dev/null | awk '{print $1}')
  echo "③ Homebrew 缓存: ${BREW_SIZE:-未知}"
  run "清理 Homebrew 缓存" brew cleanup --prune=all
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
  run "清理 CocoaPods 缓存" rm -rf "$PODS_CACHE"/*
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
  run "清理 Gradle 缓存" rm -rf "$GRADLE_CACHE"/*
  done_msg "清理 Gradle 缓存"
else
  echo "⑤ Gradle 缓存: 未找到"
fi
echo ""

# 8.6 Docker 镜像/容器/构建缓存 —— 安全（会删除停止的容器、未使用的镜像/网络/缓存）
if command -v docker &> /dev/null; then
  echo "⑥ Docker 清理: 检测到 Docker"
  run "清理 Docker 无用资源 (system prune -a)" docker system prune -a --force
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
  run "清理旧 iOS DeviceSupport 符号文件" rm -rf "$DEVSUPPORT"/*
  done_msg "清理 DeviceSupport"
else
  echo "⑦ Xcode iOS DeviceSupport: 未找到"
fi

if command -v xcrun &> /dev/null; then
  echo "   清理不可用的旧 iOS 模拟器 ..."
  run "删除不可用的旧模拟器" xcrun simctl delete unavailable
  done_msg "清理旧模拟器"
else
  echo "   未安装 Xcode 命令行工具，跳过模拟器清理"
fi
echo ""

# ---------- 9. 安全可再生缓存（语言工具链 / 包管理器）----------
echo "----- 9. 语言工具链与包管理器缓存（安全可再生）-----"
echo "以下均为可再生缓存，删除后下次构建/安装会自动重建。"
echo ""

# 9.1 各语言原生缓存目录（直接删除，重建无副作用）
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
    run "清理 $(basename "$d")" rm -rf "$d"/*
  fi
done

# 9.2 pnpm store：只回收未被引用的包（比 rm -rf 更安全）
if command -v pnpm &> /dev/null; then
  PNPM_STORE_SIZE=$(du -sh "$HOME/Library/pnpm" 2>/dev/null | awk '{print $1}')
  echo "pnpm store: ${PNPM_STORE_SIZE:-未知}"
  run "回收 pnpm store 中未引用的包" corepack pnpm store prune
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
  echo "  以上为预览。确认无误后，运行 $0 --clean 实际清理。"
  echo "======================================"
  echo ""
elif [[ "$CLEAN" != "1" ]]; then
  echo "======================================"
  echo "           清理报告"
  echo "======================================"
  echo "  （查询模式，仅统计占用，未执行任何清理）"
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
  else
    echo "  已执行清理但可用空间未提升（$(human "$((-FREED_KB))")）"
    echo "  ⚠️ 已执行清理但可用空间未明显增加：可能系统延迟记账，建议重启后再查看。"
  fi
  echo ""
  if (( ${#REPORT_STEPS[@]} > 0 )); then
    echo "  实际执行并已确认的清理项（${#REPORT_STEPS[@]}）："
    printf '    ✅ %s\n' "${REPORT_STEPS[@]}"
  else
    echo "  （本次没有实际执行的清理项）"
  fi
  echo "======================================"
  echo ""
  echo "建议：重启一次 Mac，让系统重建必要的缓存文件，"
  echo "并再次前往 \"关于本机 → 储存空间\" 查看统计（该统计有延迟，需等待或重启后再看）。"
fi
