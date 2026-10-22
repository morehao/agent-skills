#!/usr/bin/env bash
#
# cleanup-opencode.sh — 清理 opencode 数据库中的旧会话数据(按保留天数)并回收空间
#
# 用法:
#   bash skills/disk-cleanup/scripts/cleanup-opencode.sh                  # 默认保留最近 7 天
#   bash skills/disk-cleanup/scripts/cleanup-opencode.sh 30               # 保留最近 30 天
#   bash skills/disk-cleanup/scripts/cleanup-opencode.sh --kill           # 检测到 opencode 运行时查询并逐项询问后杀掉
#   bash skills/disk-cleanup/scripts/cleanup-opencode.sh --kill --yes 7   # 一键: 直接杀掉(不询问)并按 7 天清理
#
# 说明:
#   - 只清理数据库 / 会话相关表和孤儿 snapshot 目录
#   - 不会触碰 account / auth / credential 等鉴权数据
#   - 检测到 opencode 正在运行(CLI/serve 或桌面版)时:
#       * 不带 --kill → 列出进程并拒绝执行, 提示可用 --kill
#       * 带 --kill   → 列出进程, 逐项询问(或 --yes 直接)终止相关进程后再继续
#   - 注意: 若脚本由运行中的 opencode 会话触发, --kill 会终止其宿主进程(即当前会话)。
#   - 建议先备份: 见 references/cleanup.md「先备份」一节
#
set -euo pipefail

DB="${OC_DATA_DIR:-$HOME/.local/share/opencode}/opencode.db"
KEEP_DAYS=7
DO_KILL=0
ASSUME_YES=0

# 危险: OC_FORCE=1 可跳过所有进程检测。仅用于对离线副本(备份)做干跑验证,
#       切勿对线上正在被 opencode 使用的数据库使用。默认关闭。
FORCE="${OC_FORCE:-0}"

# ---------- 参数解析 ----------
for arg in "$@"; do
  case "$arg" in
    --kill)      DO_KILL=1 ;;
    --yes|-y)    ASSUME_YES=1 ;;
    [0-9]* )     KEEP_DAYS="$arg" ;;
    *)           echo "未知参数: $arg" >&2; echo "用法: $0 [天数] [--kill] [--yes]" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$DB" ]]; then
  echo "错误: 找不到数据库文件 $DB" >&2
  exit 1
fi

# ---------- 参数校验 ----------
if ! [[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || (( KEEP_DAYS < 0 )); then
  echo "错误: 保留天数必须是正整数(默认 7)。" >&2
  exit 1
fi

THRESHOLD=$(( $(date +%s) * 1000 - KEEP_DAYS * 86400 * 1000 ))

# ---------- 进程查询与终止 ----------
# 匹配串:
#   CLI/serve  : opencode-ai/bin/opencode*  (node 运行的 CLI、serve 实例)
#   桌面版     : OpenCode.app 及其 Helper 进程
CLI_PATTERN="opencode-ai/bin/opencode"
GUI_PATTERN="OpenCode.app"

list_procs() {
  local pat="$1"
  # 用 ps 拿到 pid+命令行, 避免 pgrep -f 匹配到 bash 自身
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
  local remain
  remain=$(running_procs "$pat")
  echo "  终止后剩余: $remain 个"
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
    [[ "$ASSUME_YES" != "1" ]] && {
      echo -n ">>> 确认对 opencode 相关进程执行终止操作并继续? [y/N] "
      local ans; read -r ans
      case "$ans" in y|Y|yes|YES) : ;; *) echo "已取消。"; exit 1 ;; esac
    }
    kill_procs "$CLI_PATTERN" "CLI / serve" || exit 1
    kill_procs "$GUI_PATTERN" "桌面版 OpenCode.app" || exit 1
  else
    echo ""
    echo ">>> 检测到 opencode 正在运行, 默认不清理。"
    echo ">>> 如确认要终止这些进程后继续, 请改用: $0 [天数] --kill"
    exit 1
  fi

  # ---------- 杀后复检: 有任何残留则阻断数据库操作 ----------
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
echo "=============================================="

count() {
  sqlite3 "$DB" "$1"
}

echo ""
echo ">>> 清理前数据量:"
echo "  session : $(count 'SELECT count(*) FROM session')"
echo "  message : $(count 'SELECT count(*) FROM message')"
echo "  part    : $(count 'SELECT count(*) FROM part')"
echo "  event   : $(count 'SELECT count(*) FROM event')"

# ---------- 执行删除(事务内, 先子表后父表) ----------
# 生成的 SQL 在事务中执行, 中途失败则整体回滚
SQL=$(cat <<SQL
BEGIN IMMEDIATE;
PRAGMA foreign_keys = OFF;

DELETE FROM event
 WHERE aggregate_id IN (
   SELECT id FROM session WHERE time_updated < $THRESHOLD
 );

DELETE FROM event_sequence
 WHERE aggregate_id IN (
   SELECT id FROM session WHERE time_updated < $THRESHOLD
 );

DELETE FROM part
 WHERE session_id IN (
   SELECT id FROM session WHERE time_updated < $THRESHOLD
 );

DELETE FROM message
 WHERE session_id IN (
   SELECT id FROM session WHERE time_updated < $THRESHOLD
 );

DELETE FROM session_message
 WHERE session_id IN (
   SELECT id FROM session WHERE time_updated < $THRESHOLD
 );

DELETE FROM session_input
 WHERE session_id IN (
   SELECT id FROM session WHERE time_updated < $THRESHOLD
 );

DELETE FROM session_share
 WHERE session_id IN (
   SELECT id FROM session WHERE time_updated < $THRESHOLD
 );

DELETE FROM session_context_epoch
 WHERE session_id IN (
   SELECT id FROM session WHERE time_updated < $THRESHOLD
 );

DELETE FROM todo
 WHERE session_id IN (
   SELECT id FROM session WHERE time_updated < $THRESHOLD
 );

DELETE FROM session
 WHERE time_updated < $THRESHOLD;

COMMIT;
SQL
)

echo ""
echo ">>> 正在删除 ${KEEP_DAYS} 天前的旧会话..."
sqlite3 "$DB" "$SQL"
echo ">>> 删除完成。"

echo ""
echo ">>> 清理后数据量:"
echo "  session : $(count 'SELECT count(*) FROM session')"
echo "  message : $(count 'SELECT count(*) FROM message')"
echo "  part    : $(count 'SELECT count(*) FROM part')"
echo "  event   : $(count 'SELECT count(*) FROM event')"

# ---------- 清理孤儿 snapshot 目录 ----------
SNAP_DIR="$(dirname "$DB")/snapshot"
if [[ -d "$SNAP_DIR" ]]; then
  echo ""
  echo ">>> 清理孤儿 snapshot 目录(snapshot 中已不在 project 表里的):"
  removed=0
  for d in "$SNAP_DIR"/*; do
    [[ -d "$d" ]] || continue
    id="$(basename "$d")"
    if [[ -z "$(sqlite3 "$DB" "SELECT id FROM project WHERE id='$id'")" ]]; then
      rm -rf "$d"
      removed=$((removed + 1))
    fi
  done
  echo "  已删除孤儿 snapshot 目录: $removed 个"
fi

# ---------- VACUUM 回收物理空间 ----------
echo ""
echo ">>> 执行 VACUUM 回收空间(可能耗时较长)..."
sqlite3 "$DB" "VACUUM;"
echo ">>> VACUUM 完成。"

echo ""
echo ">>> 数据库文件大小:"
du -h "$DB"
echo ">>> 完成 ✔"
