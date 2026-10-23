#!/usr/bin/env bash
# opencode 接入安装脚本（幂等，可重复执行）：
#   1) 把本仓 skills/* 软链到「本地技能统一安装位」（默认 ~/.agents/skills，见 skills-link.sh）
#   2) 把 commands-opencode/git、handoff.md 与 cleanup.md 软链到 opencode 的 command 目录
#
# 技能只有**一个**安装位（~/.agents/skills），opencode 通过 config 的 `skills` 数组去那里读；
# 命令没法搬（opencode 只认配置目录下的 command/），所以这一半仍由本脚本软链。
#
# 为什么不用通配的 `ln -sfn skills/*`：通配会把 skills/ 下的松散文件也一起链过去，
# 且不会清理技能改名后留下的悬空软链。技能链接逻辑集中在 skills-link.sh（只遍历目录、
# 清理悬空链、遇真实目录默认不覆盖）；命令链接沿用同样的规则。
#
# 用法：./scripts/opencode-install.sh [选项]
#
#   --skills-only    只软链技能（= skills-link.sh），不碰命令
#   --commands-only  只软链命令，不碰技能
#   --check          只检查（不建目录、不改软链）：报告缺失/不一致/悬空，问题数 >0 时退出 1
#   --dry-run        打印将要做的操作，不落盘
#   -h, --help       显示帮助
#
# 环境变量：
#   OPENCODE_CONFIG     opencode 配置根，默认 ~/.config/opencode
#   AGENTS_SKILLS_DIR   技能安装位，默认 ~/.agents/skills
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${OPENCODE_CONFIG:-$HOME/.config/opencode}"
SKILLS_SRC="$REPO_ROOT/skills"
COMMANDS_SRC="$REPO_ROOT/commands-opencode"
SKILLS_DST="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
COMMAND_DST="$CONFIG_DIR/command"
SKILLS_LINK="$REPO_ROOT/scripts/skills-link.sh"

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

  --skills-only    只把 skills/ 软链到技能安装位（默认 ~/.agents/skills）。
  --commands-only  只软链 commands-opencode/{git,handoff.md,cleanup.md} 到 command 目录。
  --check          只检查不修改：缺失、指向错误、悬空软链都算问题，有问题退出 1。
  --dry-run        只打印将执行的操作。
  -h, --help       显示本帮助。

环境变量:
  OPENCODE_CONFIG     opencode 配置根，默认 ~/.config/opencode
  AGENTS_SKILLS_DIR   技能安装位，默认 ~/.agents/skills

说明:
  技能只链到统一安装位一份，opencode 靠 config 的 skills 去读：
    { "skills": ["~/.agents/skills"] }        # 或 "compatibility": { "agents": ["~/.agents"] }
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

# 旧布局（技能软链直接挂在 <config>/skills）会让同一技能出现两次：提示清理，不算失败。
warn_legacy_skill_links() {
  local legacy="$CONFIG_DIR/skills"
  local target
  local real
  local found=0

  [ -d "$legacy" ] || return 0
  for target in "$legacy"/*; do
    [ -L "$target" ] || continue
    real="$(readlink "$target")"
    case "$real" in
      "$SKILLS_SRC"/*|"$SKILLS_DST"/*)
        if [ "$found" -eq 0 ]; then
          echo "  ! 检测到旧布局：${legacy} 下仍有技能软链（现已统一到 ${SKILLS_DST}）"
          found=1
        fi
        echo "      可删：rm \"${target}\""
        ;;
    esac
  done
}

# 技能可见性靠 opencode 配置；这里只做尽力而为的提示（不解析 JSONC，不影响退出码）。
opencode_config_hint() {
  local cfg="$CONFIG_DIR/opencode.json"
  local alt="$CONFIG_DIR/opencode.jsonc"

  if [ -f "$cfg" ] && grep -q 'agents/skills\|"skills"\|compatibility' "$cfg"; then
    return 0
  fi
  if [ -f "$alt" ] && grep -q 'agents/skills\|"skills"\|compatibility' "$alt"; then
    return 0
  fi
  echo "  ! opencode 还没配置技能根。在 ${cfg} 里加一行："
  echo '      "skills": ["~/.agents/skills"]'
  echo '    或等价写法：  "compatibility": { "agents": ["~/.agents"] }'
  echo "    （不加这行，opencode 看不到 ${SKILLS_DST} 下的技能，/git/* 会在加载 skill 时失败。）"
}

echo "==> agent-skills 根目录:  $REPO_ROOT"
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
  echo "==> skills -> ${SKILLS_DST}（统一安装位，链接逻辑在 scripts/skills-link.sh）"
  if [ "$CHECK" -eq 1 ]; then
    bash "$SKILLS_LINK" --target "$SKILLS_DST" --check || skills_status=$?
  elif [ "$DRY_RUN" -eq 1 ]; then
    bash "$SKILLS_LINK" --target "$SKILLS_DST" --dry-run || skills_status=$?
  else
    bash "$SKILLS_LINK" --target "$SKILLS_DST" || skills_status=$?
  fi
  if [ "$skills_status" -ne 0 ]; then
    issues=$((issues + 1))
  fi
  warn_legacy_skill_links
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

if [ "$MODE" != "commands" ]; then
  opencode_config_hint
fi

if [ "$CHECK" -eq 1 ]; then
  echo "==> 检查完成：${issues} 项问题（命令侧已一致 ${unchanged} 项，悬空 ${removed} 项；技能侧结论见上）"
  if [ "$issues" -gt 0 ]; then
    echo "    修复：技能侧去掉 --check 重跑 scripts/skills-link.sh；命令侧先移走「已存在且不是软链」的真实目录。"
    exit 1
  fi
  echo "    全部就绪。"
  exit 0
fi

echo "==> 完成（命令侧）：新建 ${linked} 项，更新 ${updated} 项，已最新 ${unchanged} 项，跳过 ${skipped} 项，清理 ${removed} 项"
if [ "$MODE" != "commands" ]; then
  echo "    技能安装位：$SKILLS_DST"
fi
if [ "$MODE" != "skills" ]; then
  echo "    命令目录：$COMMAND_DST"
fi
echo "    重新打开 opencode 会话（或重启）后即可使用 /git/*、/handoff 与 /cleanup。"
