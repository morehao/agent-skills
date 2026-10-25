#!/usr/bin/env bash
#
# cleanup-opencode.sh — 清理 opencode 数据库中的旧会话数据（按保留天数）并回收空间
#
# 用法:
#   bash skills/disk-cleanup/scripts/cleanup-opencode.sh                  # 默认保留最近 7 天
#   bash skills/disk-cleanup/scripts/cleanup-opencode.sh 30               # 保留最近 30 天
#   bash skills/disk-cleanup/scripts/cleanup-opencode.sh --dry-run        # 只统计将被删除的行数，不动数据
#   bash skills/disk-cleanup/scripts/cleanup-opencode.sh --kill           # 检测到 opencode 运行时询问后终止再清理
#   bash skills/disk-cleanup/scripts/cleanup-opencode.sh --kill --yes 7   # 一键: 直接杀掉(不询问)并按 7 天清理
#
# 说明:
#   - 只清理数据库/会话相关表和孤儿 snapshot 目录；不碰 account / auth / credential 等鉴权数据
#   - 默认先备份（$HOME/opencode-backup/opencode-<时间戳>.db）并跑 integrity_check，
#     备份失败或校验不通过直接中止；确实没有空间时用 --no-backup 显式跳过（危险）
#   - VACUUM 前检查剩余空间（约需与库同量级），不足时跳过 VACUUM 并说明（删除已提交，只是空间未回收）
#   - 检测到 opencode 正在运行(CLI/serve 或桌面版)时:
#       * 不带 --kill → 列出进程并拒绝执行, 提示可用 --kill
#       * 带 --kill   → 列出进程, 逐项询问(或 --yes 直接)终止相关进程后再继续
#   - 注意: 若脚本由运行中的 opencode 会话触发, --kill 会终止其宿主进程(即当前会话)。
#
set -uo pipefail

DB="${OC_DATA_DIR:-$HOME/.local/share/opencode}/opencode.db"
KEEP_DAYS=7
DO_KILL=0
ASSUME_YES=0
DRY_RUN=0
DO_BACKUP=1
BACKUP_DIR="$HOME/opencode-backup"
DO_VACUUM=1

# 危险: OC_FORCE=1 可跳过所有进程检测。仅用于对离线副本(备份)做验证,
#       切勿对线上正在被 opencode 使用的数据库使用。默认关闭。
FORCE="${OC_FORCE:-0}"

usage() {
  cat <<EOF
用法: $0 [天数] [--kill] [--yes] [--dry-run] [--backup-dir <目录>] [--no-backup] [--no-vacuum]

  [天数]          保留最近 N 天（默认 7）
  --dry-run       只统计将被删除的行数，不修改数据库、不备份、不 VACUUM
  --kill          检测到 opencode 运行时，列出并询问后终止相关进程
  --yes / -y      配合 --kill，跳过询问直接终止
  --backup-dir    备份目录（默认 ~/opencode-backup）
  --no-backup     跳过备份（危险：不可逆）
  --no-vacuum     不执行 VACUUM（删除已提交但不回收物理空间）

环境变量:
  OC_DATA_DIR     数据目录（默认 ~/.local/share/opencode）
  OC_FORCE=1      危险：跳过进程检测，仅用于对离线副本验证
EOF
}

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kill)       DO_KILL=1; shift ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --no-backup)  DO_BACKUP=0; shift ;;
    --no-vacuum)  DO_VACUUM=0; shift ;;
    --backup-dir)
      if [[ $# -lt 2 ]]; then echo "--backup-dir 需要目录" >&2; exit 1; fi
      BACKUP_DIR="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    [0-9]*)       KEEP_DAYS="$1"; shift ;;
    *)            echo "未知参数: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if ! [[ "$KEEP_DAYS" =~ ^[0-9]+$ ]]; then
  echo "错误: 保留天数必须是非负整数（默认 7）。" >&2
  exit 1
fi

# ---------- 环境检查 ----------
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "错误: 找不到 sqlite3 命令（macOS 自带 /usr/bin/sqlite3；若被 PATH 影响请先修正）。" >&2
  exit 1
fi

if [[ ! -f "$DB" ]]; then
  echo "错误: 找不到数据库文件 $DB" >&2
  echo "      若 opencode 装在自定义目录，用 OC_DATA_DIR 指定（如 OC_DATA_DIR=~/opencode-data）。" >&2
  exit 1
fi

THRESHOLD=$(( $(date +%s) * 1000 - KEEP_DAYS * 86400 * 1000 ))

# ---------- 工具函数 ----------
db_kb() { du -k "$DB" 2>/dev/null | awk '{print $1}'; }
free_kb() { df -k "$(dirname "$DB")" 2>/dev/null | awk 'NR==2{print $4}'; }
human() {
  awk -v kb="${1:-0}" 'BEGIN{
    if (kb>=1048576) printf "%.2f GB", kb/1048576
    else if (kb>=1024) printf "%.0f MB", kb/1024
    else if (kb>0) printf "%d KB", kb
    else printf "0"
  }'
}
have_table() {
  local n
  n=$(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='$1';" 2>/dev/null)
  [[ "${n:-0}" == "1" ]]
}

# 子表挂到会话上的外键列名：事件表用 aggregate_id，其余用 session_id
child_key() {
  case "$1" in
    event|event_sequence) echo "aggregate_id" ;;
    *)                    echo "session_id" ;;
  esac
}

# 会话子表（先子后父；缺失的表会被跳过并在报告里说明）
CHILD_TABLES="event event_sequence part message session_message session_input session_share session_context_epoch todo"
PRESENT_CHILDREN=""
for t in $CHILD_TABLES; do
  if have_table "$t"; then
    PRESENT_CHILDREN="${PRESENT_CHILDREN}${PRESENT_CHILDREN:+ }${t}"
  fi
done

# ---------- 进程查询与终止 ----------
CLI_PATTERN="opencode-ai/bin/opencode"
GUI_PATTERN="OpenCode.app"

list_procs() {
  local pat="$1"
  ps -axo pid,command 2>/dev/null | grep -F "$pat" | grep -v "grep" || true
}

running_procs() {
  local pat="$1"
  ps -axo pid,command 2>/dev/null | grep -F "$pat" | grep -v "grep" | wc -l | tr -d ' ' || true
}

ask_confirm() {
  echo -n "  确认终止以上进程, 并继续清理? [y/N] "
  local ans
  read -r ans
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *)           echo "  已取消。"; return 1 ;;
  esac
}

kill_procs() {
  local pat="$1" label="$2"
  local n
  n=$(running_procs "$pat")
  if [[ "$n" == "0" ]]; then
    echo "[$label] 未发现相关进程。"
    return 0
  fi
  echo ""
  echo ">>> [$label] 发现 $n 个相关进程:"
  list_procs "$pat"
  if [[ "$ASSUME_YES" == "1" ]]; then
    echo ">>> [--yes] 直接终止 [$label] 相关进程..."
  else
    ask_confirm || return 1
  fi
  pkill -f "$pat" 2>/dev/null || true
  sleep 1
  echo "  终止后剩余: $(running_procs "$pat") 个"
}

handle_processes() {
  local cli_n gui_n
  cli_n=$(running_procs "$CLI_PATTERN")
  gui_n=$(running_procs "$GUI_PATTERN")

  if [[ "$cli_n" == "0" && "$gui_n" == "0" ]]; then
    echo "未检测到 opencode 相关进程, 继续。"
    return 0
  fi

  echo ""
  echo "=============================================="
  echo "  检测到 opencode 相关进程 (CLI: $cli_n, 桌面版: $gui_n)"
  echo "=============================================="

  if [[ "$DO_KILL" == "1" ]]; then
    echo ""
    echo ">>> 请注意: 若当前会话正运行在 opencode 中, 终止操作会关闭它(包括本命令行)。"
    if [[ "$ASSUME_YES" != "1" ]]; then
      echo -n ">>> 确认对 opencode 相关进程执行终止操作并继续? [y/N] "
      local ans; read -r ans
      case "$ans" in y|Y|yes|YES) : ;; *) echo "已取消。"; exit 1 ;; esac
    fi
    kill_procs "$CLI_PATTERN" "CLI / serve" || exit 1
    kill_procs "$GUI_PATTERN" "桌面版 OpenCode.app" || exit 1
  else
    echo ""
    echo ">>> 检测到 opencode 正在运行, 默认不清理。"
    echo ">>> 如确认要终止这些进程后继续, 请改用: $0 [天数] --kill"
    exit 1
  fi

  if [[ "$(running_procs "$CLI_PATTERN")" != "0" || "$(running_procs "$GUI_PATTERN")" != "0" ]]; then
    echo "错误: 仍有 opencode 进程残留, 中止清理以防数据损坏。" >&2
    exit 1
  fi
}

if [[ "$FORCE" == "1" ]]; then
  echo "警告: OC_FORCE=1, 已跳过 opencode 进程检测。请确认目标数据库非线上活动库!" >&2
else
  handle_processes
fi

echo "=============================================="
echo "  opencode 旧会话清理"
echo "  数据库: $DB"
echo "  保留最近: ${KEEP_DAYS} 天 (阈值 ms=${THRESHOLD})"
[[ "$DRY_RUN" == "1" ]] && echo "  模式: 干跑（只统计，不修改）"
echo "=============================================="

# ---------- 干跑：只统计 ----------
# 子表先于父表统计，父表谓词是 time_updated，子表是通过 session 关联的
count_sql() {
  local t="$1" key
  if [[ "$t" == "session" ]]; then
    echo "SELECT count(*) FROM session WHERE time_updated < $THRESHOLD;"
  else
    key=$(child_key "$t")
    echo "SELECT count(*) FROM $t WHERE $key IN (SELECT id FROM session WHERE time_updated < $THRESHOLD);"
  fi
}

if [[ "$DRY_RUN" == "1" ]]; then
  echo ""
  echo ">>> 干跑：将被删除的行数（不修改任何数据）"
  total=0
  current="$(sqlite3 "$DB" 'SELECT count(*) FROM session;')"
  echo "  （当前 session 总数: ${current:-0}）"
  for t in $PRESENT_CHILDREN session; do
    n=$(sqlite3 "$DB" "$(count_sql "$t")" 2>/dev/null || echo 0)
    total=$((total + ${n:-0}))
    printf '  %-22s %s\n' "$t" "${n:-0}"
  done
  for t in $CHILD_TABLES; do
    case " $PRESENT_CHILDREN session " in
      *" $t "*) ;;
      *) echo "  ${t}（表不存在，跳过）" ;;
    esac
  done
  echo ""
  echo ">>> 合计将删除 ${total} 行；数据库当前大小: $(du -h "$DB" | awk '{print $1}')"
  echo ">>> 干跑结束，未做任何修改。去掉 --dry-run 才会真正执行（并先备份）。"
  exit 0
fi

# ---------- 空间检查 ----------
DB_KB=$(db_kb); DB_KB="${DB_KB:-0}"
FREE_KB=$(free_kb); FREE_KB="${FREE_KB:-0}"
echo ""
echo ">>> 空间检查: 库 $(human "$DB_KB")，所在卷可用 $(human "$FREE_KB")"

if [[ "$DO_BACKUP" == "1" ]]; then
  if (( FREE_KB < DB_KB + DB_KB / 20 )); then
    echo "错误: 可用空间不足以做备份（需约 $(human "$DB_KB")）。" >&2
    echo "      先腾出空间，或用 --no-backup 显式跳过备份（不可逆，谨慎）。" >&2
    exit 1
  fi
else
  echo "⚠️ --no-backup：本次不做备份，删除不可逆。" >&2
fi

VACUUM_OK=1
if [[ "$DO_VACUUM" == "1" ]]; then
  # VACUUM 需要重建一份库，峰值约等于库大小
  if (( FREE_KB < DB_KB + DB_KB / 10 )); then
    VACUUM_OK=0
    echo "⚠️ 可用空间不足以 VACUUM（峰值约 $(human "$DB_KB")）；本次将只删数据、跳过 VACUUM，空间不会立刻回收。" >&2
  fi
fi

# ---------- 备份 ----------
if [[ "$DO_BACKUP" == "1" ]]; then
  mkdir -p "$BACKUP_DIR" || { echo "错误: 无法创建备份目录 $BACKUP_DIR" >&2; exit 1; }
  BACKUP_FILE="$BACKUP_DIR/opencode-$(date +%Y%m%d-%H%M%S).db"
  echo ""
  echo ">>> 备份到: $BACKUP_FILE"
  if ! sqlite3 "$DB" ".backup '$BACKUP_FILE'"; then
    echo "错误: 备份失败，中止清理（数据库未做任何修改）。" >&2
    exit 1
  fi
  ic=$(sqlite3 "$BACKUP_FILE" "PRAGMA integrity_check;" 2>/dev/null | head -1)
  if [[ "$ic" != "ok" ]]; then
    echo "错误: 备份完整性校验未通过（${ic}），中止清理。" >&2
    exit 1
  fi
  echo ">>> 备份完成：$(du -h "$BACKUP_FILE" | awk '{print $1}')，integrity_check: ok"
fi

# ---------- 删除（事务内，先子表后父表） ----------
echo ""
echo ">>> 清理前数据量:"
for t in session message part event; do
  if have_table "$t"; then
    printf '  %-8s %s\n' "$t" "$(sqlite3 "$DB" "SELECT count(*) FROM $t;")"
  fi
done

SQL="BEGIN IMMEDIATE;
PRAGMA foreign_keys = OFF;"
for t in $PRESENT_CHILDREN; do
  key=$(child_key "$t")
  SQL="${SQL}
DELETE FROM $t WHERE $key IN (SELECT id FROM session WHERE time_updated < $THRESHOLD);"
done
SQL="${SQL}
DELETE FROM session WHERE time_updated < $THRESHOLD;
COMMIT;"

echo ""
echo ">>> 正在删除 ${KEEP_DAYS} 天前的旧会话（事务内，失败整体回滚）..."
if ! sqlite3 "$DB" "$SQL"; then
  echo "错误: 删除失败并已回滚，数据库保持原样。" >&2
  exit 1
fi
echo ">>> 删除完成。"

echo ""
echo ">>> 清理后数据量:"
for t in session message part event; do
  if have_table "$t"; then
    printf '  %-8s %s\n' "$t" "$(sqlite3 "$DB" "SELECT count(*) FROM $t;")"
  fi
done

# ---------- 清理孤儿 snapshot 目录 ----------
SNAP_DIR="$(dirname "$DB")/snapshot"
if [[ -d "$SNAP_DIR" ]]; then
  echo ""
  echo ">>> 清理孤儿 snapshot 目录（snapshot 中已不在 project 表里的）:"
  removed=0
  for d in "$SNAP_DIR"/*; do
    [[ -d "$d" ]] || continue
    id="$(basename "$d")"
    if [[ -z "$(sqlite3 "$DB" "SELECT id FROM project WHERE id='$id'" 2>/dev/null)" ]]; then
      rm -rf "$d" && removed=$((removed + 1))
    fi
  done
  echo "  已删除孤儿 snapshot 目录: $removed 个"
fi

# ---------- VACUUM ----------
SIZE_BEFORE_KB=$(db_kb); SIZE_BEFORE_KB="${SIZE_BEFORE_KB:-0}"
if [[ "$VACUUM_OK" != "1" ]]; then
  echo ""
  echo ">>> 已跳过 VACUUM（空间不足）。腾出空间后可单独执行: sqlite3 \"$DB\" \"VACUUM;\""
else
  echo ""
  echo ">>> 执行 VACUUM 回收空间（耗时随库大小增长）..."
  if sqlite3 "$DB" "VACUUM;"; then
    echo ">>> VACUUM 完成。"
  else
    echo "⚠️ VACUUM 失败（数据删除已提交，物理空间未回收）。可在空间充足时单独重试。" >&2
  fi
fi

SIZE_AFTER_KB=$(db_kb); SIZE_AFTER_KB="${SIZE_AFTER_KB:-0}"
echo ""
echo ">>> 数据库文件大小: $(human "$SIZE_BEFORE_KB") → $(human "$SIZE_AFTER_KB")"
du -h "$DB"
echo ">>> 完成 ✔"
