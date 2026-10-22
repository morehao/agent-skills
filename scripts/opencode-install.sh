#!/usr/bin/env bash
# opencode 接入安装脚本（幂等，可重复执行）：
#   1) 把本仓 skills/* 逐目录软链到 opencode 的 skills 目录
#   2) 把 commands-opencode/git、handoff.md 与 cleanup.md 软链到 opencode 的 command 目录
#
# 为什么不用通配的 `ln -sfn skills/*`：通配会把 skills/ 下的松散文件也一起链过去，
# 且不会清理技能改名后留下的悬空软链。本脚本只遍历目录，并先清理「指向本仓但目标已不存在」
# 的软链；目标位置已有同名真实目录时跳过、不覆盖。
#
# 用法：./scripts/opencode-install.sh [选项]
#
#   --skills-only    只软链技能，不碰命令
#   --commands-only  只软链命令，不碰技能
#   --check          只检查（不建目录、不改软链）：报告缺失/不一致/悬空，问题数 >0 时退出 1
#   --dry-run        打印将要做的操作，不落盘
#   -h, --help       显示帮助
#
# 环境变量：
#   OPENCODE_CONFIG  opencode 配置根，默认 ~/.config/opencode
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${OPENCODE_CONFIG:-$HOME/.config/opencode}"
SKILLS_SRC="$REPO_ROOT/skills"
COMMANDS_SRC="$REPO_ROOT/commands-opencode"
SKILLS_DST="$CONFIG_DIR/skills"
COMMAND_DST="$CONFIG_DIR/command"

MODE="all" # all | skills | commands
CHECK=0
DRY_RUN=0

linked=0
updated=0
unchanged=0
skipped=0
removed=0
issues=0

usage() {
  cat <<'EOF'
用法: ./scripts/opencode-install.sh [选项]

  --skills-only    只软链 skills/ 到 opencode 的 skills 目录。
  --commands-only  只软链 commands-opencode/{git,handoff.md,cleanup.md} 到 command 目录。
  --check          只检查不修改：缺失、指向错误、悬空软链都算问题，有问题退出 1。
  --dry-run        只打印将执行的操作。
  -h, --help       显示本帮助。

环境变量:
  OPENCODE_CONFIG  opencode 配置根，默认 ~/.config/opencode

说明:
  opencode 同时扫描配置目录下的 command/ 与 commands/（v2.x 源码里的
  scan("{command,commands}/**/*.md")），本仓沿用 command/。
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

echo "==> ai-kit 根目录:  $REPO_ROOT"
echo "==> opencode 配置:  $CONFIG_DIR"
if [ "$CHECK" -eq 1 ]; then
  echo "==> 模式: 只检查（不修改）"
elif [ "$DRY_RUN" -eq 1 ]; then
  echo "==> 模式: dry-run（不落盘）"
fi

if [ "$MODE" != "commands" ] && [ ! -d "$SKILLS_SRC" ]; then
  echo "错误：找不到技能源目录 $SKILLS_SRC" >&2
  exit 2
fi
if [ "$MODE" != "skills" ] && [ ! -d "$COMMANDS_SRC/git" ]; then
  echo "错误：找不到命令源目录 $COMMANDS_SRC/git" >&2
  exit 2
fi

# ---------- 1) skills ----------
if [ "$MODE" != "commands" ]; then
  echo "==> skills -> $SKILLS_DST"
  prepare_target "$SKILLS_DST"
  clean_stale "$SKILLS_DST" "$SKILLS_SRC"
  for skill_dir in "$SKILLS_SRC"/*/; do
    [ -d "$skill_dir" ] || continue
    skill_dir="${skill_dir%/}"
    link_path "$skill_dir" "$SKILLS_DST/$(basename "$skill_dir")" "技能 $(basename "$skill_dir")"
  done
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
  echo "==> 检查完成：${issues} 项问题（已一致 ${unchanged} 项，悬空 ${removed} 项）"
  if [ "$issues" -gt 0 ]; then
    echo "    修复：先移走「已存在且不是软链」的真实目录，再去掉 --check 重跑本脚本。"
    exit 1
  fi
  echo "    全部就绪。"
  exit 0
fi

echo "==> 完成：新建 ${linked} 项，更新 ${updated} 项，已最新 ${unchanged} 项，跳过 ${skipped} 项，清理 ${removed} 项"
if [ "$MODE" != "commands" ]; then
  echo "    技能目录：$SKILLS_DST"
fi
if [ "$MODE" != "skills" ]; then
  echo "    命令目录：$COMMAND_DST"
fi
echo "    重新打开 opencode 会话（或重启）后即可使用 /git/*、/handoff 与 /cleanup。"
