#!/usr/bin/env bash
# opencode 接入脚本（幂等，可重复执行）：
#   1) 技能：把本源 ~/.agents/skills/<name> 软链到 <config>/skills/<name>（= skills-fanout.sh）
#   2) 命令：把 commands-opencode/git、handoff.md 与 cleanup.md 软链到 <config>/command
#
# 模型：**本源是 ~/.agents/skills**（真实内容，由 skills-install.sh 用 skills CLI 从本仓发布）；
# 各 agent 目录只放指向本源的软链。本脚本不碰本源内容，只生成 opencode 这一侧的软链。
# 命令没法搬（opencode 只认配置目录下的 command/），所以这一半由本脚本软链。
#
# 为什么不用通配的 `ln -sfn ...`：通配会把松散文件也链过去，且不会清理改名后的悬空软链。
# 技能侧逻辑集中在 skills-fanout.sh（只遍历目录、清理悬空、遇真实目录不覆盖）；命令侧同规则。
#
# 用法：./scripts/opencode-install.sh [选项]
#
#   --skills-only    只做技能软链（= skills-fanout.sh --agents opencode），不碰命令
#   --commands-only  只软链命令，不碰技能
#   --check          只检查（不建目录、不改软链）：报告缺失/不一致/悬空，问题数 >0 时退出 1
#   --dry-run        打印将要做的操作，不落盘
#   -h, --help       显示帮助
#
# 环境变量：
#   OPENCODE_CONFIG     opencode 配置根，默认 ~/.config/opencode
#   AGENTS_SKILLS_DIR   技能本源目录，默认 ~/.agents/skills
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${OPENCODE_CONFIG:-$HOME/.config/opencode}"
SKILLS_SRC="$REPO_ROOT/skills"
COMMANDS_SRC="$REPO_ROOT/commands-opencode"
HUB="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
SKILLS_DST="$CONFIG_DIR/skills"
COMMAND_DST="$CONFIG_DIR/command"
FANOUT="$REPO_ROOT/scripts/skills-fanout.sh"

MODE="all" # all | skills | commands
CHECK=0
DRY_RUN=0

linked=0
updated=0
unchanged=0
skipped=0
removed=0
issues=0
skills_status=0

usage() {
  cat <<'EOF'
用法: ./scripts/opencode-install.sh [选项]

  --skills-only    只做技能软链：<config>/skills/<name> -> ~/.agents/skills/<name>。
  --commands-only  只软链 commands-opencode/{git,handoff.md,cleanup.md} 到 command 目录。
  --check          只检查不修改：缺失、指向错误、悬空软链都算问题，有问题退出 1。
  --dry-run        只打印将执行的操作。
  -h, --help       显示本帮助。

环境变量:
  OPENCODE_CONFIG     opencode 配置根，默认 ~/.config/opencode
  AGENTS_SKILLS_DIR   技能本源目录，默认 ~/.agents/skills

说明:
  技能本源是 ~/.agents/skills（由 ./scripts/skills-install.sh 从本仓发布），
  opencode 侧只放指向本源的软链，因此**不需要**再在 opencode.json 里配 skills。
  命令必须落在配置目录下的 command/（opencode v2.x 源码里 scan("{command,commands}/**/*.md")），
  本仓沿用 command/。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --skills-only)
      if [ "$MODE" = "commands" ]; then
        echo "错误：--skills-only 与 --commands-only 不能同时使用" >&2
        exit 2
      fi
      MODE="skills"
      shift
      ;;
    --commands-only)
      if [ "$MODE" = "skills" ]; then
        echo "错误：--skills-only 与 --commands-only 不能同时使用" >&2
        exit 2
      fi
      MODE="commands"
      shift
      ;;
    --check)
      CHECK=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "错误：未知参数 $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# 软链一个路径：已一致则跳过；是软链则更新；是真实目录/文件则跳过不覆盖。
link_path() {
  local src="$1"
  local dst="$2"
  local label="$3"
  local current

  if [ ! -e "$src" ]; then
    echo "  ✗ ${label}: 源不存在：$src"
    issues=$((issues + 1))
    return 0
  fi

  if [ -L "$dst" ]; then
    current="$(readlink "$dst")"
    if [ "$current" = "$src" ]; then
      if [ "$CHECK" -eq 1 ]; then
        echo "  ✓ ${label}: ${dst}"
      fi
      unchanged=$((unchanged + 1))
      return 0
    fi
    if [ "$CHECK" -eq 1 ]; then
      echo "  ✗ ${label}: $dst -> ${current}（应为 ${src}）"
      issues=$((issues + 1))
      return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  [dry-run] 更新软链 ${dst} -> ${src}"
    else
      ln -sfn "$src" "$dst"
      echo "  更新软链 ${dst} -> ${src}"
    fi
    updated=$((updated + 1))
    return 0
  fi

  if [ -e "$dst" ]; then
    echo "  ! 跳过 ${label}: $dst 已存在且不是软链（不覆盖真实目录/文件）"
    skipped=$((skipped + 1))
    if [ "$CHECK" -eq 1 ]; then
      issues=$((issues + 1))
    fi
    return 0
  fi

  if [ "$CHECK" -eq 1 ]; then
    echo "  ✗ ${label}: 缺少软链 $dst -> $src"
    issues=$((issues + 1))
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] 软链 ${dst} -> ${src}"
  else
    mkdir -p "$(dirname "$dst")"
    ln -sfn "$src" "$dst"
    echo "  软链 ${dst} -> ${src}"
  fi
  linked=$((linked + 1))
}

# 清理悬空软链：只处理「指向本仓某目录、但该目标已不存在」的链接（技能/命令改名后残留）。
clean_stale() {
  local target_root="$1"
  local source_root="$2"
  local target
  local real

  for target in "$target_root"/* "$target_root"/.[!.]*; do
    [ -L "$target" ] || continue
    real="$(readlink "$target")"
    case "$real" in
      "$source_root"/*)
        if [ ! -e "$real" ]; then
          if [ "$CHECK" -eq 1 ]; then
            echo "  ✗ 悬空软链 ${target} -> ${real}（目标已不存在）"
            issues=$((issues + 1))
          elif [ "$DRY_RUN" -eq 1 ]; then
            echo "  [dry-run] 清理悬空软链 ${target} -> ${real}"
          else
            rm "$target"
            echo "  清理悬空软链 ${target} -> ${real}"
          fi
          removed=$((removed + 1))
        fi
        ;;
    esac
  done
}

prepare_target() {
  local target="$1"
  if [ "$CHECK" -eq 1 ]; then
    if [ ! -d "$target" ]; then
      echo "  ✗ 目录不存在：$target"
      issues=$((issues + 1))
    fi
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ ! -d "$target" ]; then
      echo "  [dry-run] 创建目录 ${target}"
    fi
    return 0
  fi
  mkdir -p "$target"
}

echo "==> agent-skills 根目录:  $REPO_ROOT"
echo "==> opencode 配置:  $CONFIG_DIR"
echo "==> 技能本源:  $HUB"
if [ "$CHECK" -eq 1 ]; then
  echo "==> 模式: 只检查（不修改）"
elif [ "$DRY_RUN" -eq 1 ]; then
  echo "==> 模式: dry-run（不落盘）"
fi

if [ "$MODE" != "commands" ] && [ ! -d "$HUB" ]; then
  echo "错误：技能本源目录不存在：$HUB" >&2
  echo "  先发布技能：./scripts/skills-install.sh（它用 skills CLI 从本仓安装到本源）" >&2
  exit 2
fi
if [ "$MODE" != "skills" ] && [ ! -d "$COMMANDS_SRC/git" ]; then
  echo "错误：找不到命令源目录 $COMMANDS_SRC/git" >&2
  exit 2
fi

# ---------- 1) skills（只建软链：本源 -> opencode 配置目录） ----------
if [ "$MODE" != "commands" ]; then
  echo "==> skills -> ${SKILLS_DST}（软链指向本源 ${HUB}，逻辑在 scripts/skills-fanout.sh）"
  if [ "$CHECK" -eq 1 ]; then
    bash "$FANOUT" --agents opencode --check || skills_status=$?
  elif [ "$DRY_RUN" -eq 1 ]; then
    bash "$FANOUT" --agents opencode --dry-run || skills_status=$?
  else
    bash "$FANOUT" --agents opencode || skills_status=$?
  fi
  if [ "$skills_status" -ne 0 ]; then
    issues=$((issues + 1))
  fi
fi

# ---------- 2) commands ----------
if [ "$MODE" != "skills" ]; then
  echo "==> commands -> $COMMAND_DST"
  prepare_target "$COMMAND_DST"
  clean_stale "$COMMAND_DST" "$COMMANDS_SRC"
  link_path "$COMMANDS_SRC/git" "$COMMAND_DST/git" "命令 git/"
  link_path "$COMMANDS_SRC/handoff.md" "$COMMAND_DST/handoff.md" "命令 handoff"
  link_path "$COMMANDS_SRC/cleanup.md" "$COMMAND_DST/cleanup.md" "命令 cleanup"
fi

if [ "$CHECK" -eq 1 ]; then
  echo "==> 检查完成：${issues} 项问题（命令侧已一致 ${unchanged} 项，悬空 ${removed} 项；技能侧结论见上）"
  if [ "$issues" -gt 0 ]; then
    echo "    修复：技能侧去掉 --check 重跑 scripts/skills-fanout.sh --agents opencode；"
    echo "          本源内容缺失/落后先跑 scripts/skills-install.sh；命令侧先移走「已存在且不是软链」的真实目录。"
    exit 1
  fi
  echo "    全部就绪。"
  exit 0
fi

echo "==> 完成（命令侧）：新建 ${linked} 项，更新 ${updated} 项，已最新 ${unchanged} 项，跳过 ${skipped} 项，清理 ${removed} 项"
if [ "$MODE" != "commands" ]; then
  echo "    技能软链目录：${SKILLS_DST}（指向本源 ${HUB}）"
fi
if [ "$MODE" != "skills" ]; then
  echo "    命令目录：$COMMAND_DST"
fi
echo "    重新打开 opencode 会话（或重启）后即可使用 /git/*、/handoff 与 /cleanup。"
