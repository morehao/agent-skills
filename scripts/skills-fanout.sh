#!/usr/bin/env bash
# 把「技能本源目录」~/.agents/skills 里的技能软链到各 agent 的技能目录。
#
# 模型（方向别搞反）：
#   ~/.agents/skills/<name>（本源，真实内容，由 skills CLI 安装）
#        └─软链─> ~/.config/opencode/skills/<name>
#        └─软链─> ~/.dsh/skills/<name>
#        └─软链─> ~/.claude/skills/<name>
#   本源内容由 ./scripts/skills-install.sh 从本仓发布；本脚本只负责「让各 agent 看见」。
#
# 幂等：已指向本源的软链跳过；指向别处（如旧布局指向本仓）的软链改指向本源；
# 指向本源但技能已不存在的悬空软链清理；目标位置已有同名真实目录时跳过、不覆盖。
#
# 用法：./scripts/skills-fanout.sh [选项]
#
#   --agents <列表>  逗号分隔，可选 opencode / dsh / claude；默认 opencode,dsh
#   --check          只检查不修改：缺失/指向错误/悬空/被真实目录占位 都算问题，有问题退出 1
#   --dry-run        只打印将执行的操作，不落盘
#   -h, --help       显示帮助
#
# 环境变量：
#   AGENTS_SKILLS_DIR  本源目录，默认 $HOME/.agents/skills
#   OPENCODE_CONFIG    opencode 配置根，默认 $HOME/.config/opencode
#   DSH_HOME           dsh 配置根，默认 $HOME/.dsh
#   CLAUDE_HOME        claude 配置根，默认 $HOME/.claude
set -euo pipefail

HUB="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
AGENTS="opencode,dsh"

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
用法: ./scripts/skills-fanout.sh [选项]

  --agents <列表>  逗号分隔：opencode / dsh / claude。默认 opencode,dsh。
  --check          只检查不修改：缺失、指向错误、悬空软链、被真实目录占位都算问题，退出 1。
  --dry-run        只打印将执行的操作。
  -h, --help       显示本帮助。

环境变量:
  AGENTS_SKILLS_DIR  本源目录，默认 $HOME/.agents/skills
  OPENCODE_CONFIG    opencode 配置根，默认 $HOME/.config/opencode
  DSH_HOME           dsh 配置根，默认 $HOME/.dsh
  CLAUDE_HOME        claude 配置根，默认 $HOME/.claude

说明:
  本源是真源，各 agent 目录只放指向它的软链。内容发布用 ./scripts/skills-install.sh。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --agents)
      if [ $# -lt 2 ]; then
        echo "错误：--agents 需要一个参数（如 opencode,dsh）" >&2
        exit 2
      fi
      AGENTS="$2"
      shift 2
      ;;
    --agents=*)
      AGENTS="${1#*=}"
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

# agent 名 -> 技能目录
agent_dir() {
  case "$1" in
    opencode) echo "${OPENCODE_CONFIG:-$HOME/.config/opencode}/skills" ;;
    dsh) echo "${DSH_HOME:-$HOME/.dsh}/skills" ;;
    claude) echo "${CLAUDE_HOME:-$HOME/.claude}/skills" ;;
    *) return 1 ;;
  esac
}

# agent 列表按逗号转成逐行，避免依赖 IFS 全局改写（bash 3.2 下更稳）
AGENT_LIST="$(printf '%s' "$AGENTS" | tr ',' '\n')"

# 校验 agent 列表
while IFS= read -r agent; do
  [ -n "$agent" ] || continue
  if ! agent_dir "$agent" >/dev/null; then
    echo "错误：未知 agent「${agent}」（可选 opencode / dsh / claude）" >&2
    exit 2
  fi
done <<EOF
$AGENT_LIST
EOF

if [ ! -d "$HUB" ]; then
  echo "错误：技能本源目录不存在：${HUB}" >&2
  echo "  先发布技能：./scripts/skills-install.sh" >&2
  exit 2
fi

# 本源里的技能名（只认目录，且必须有 SKILL.md）
hub_skills() {
  local dir
  for dir in "$HUB"/*/; do
    [ -d "$dir" ] || continue
    [ -f "$dir/SKILL.md" ] || continue
    basename "${dir%/}"
  done
}

# 软链一个技能：一致则跳过；是软链则改指向；真实目录跳过（--check 记问题）
link_skill() {
  local src="$1"
  local dst="$2"
  local label="$3"
  local current

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
      echo "  ✗ ${label}: ${dst} -> ${current}（应指向本源 ${src}）"
      issues=$((issues + 1))
      return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  [dry-run] 改指向 ${dst} -> ${src}（原 ${current}）"
    else
      ln -sfn "$src" "$dst"
      echo "  改指向 ${dst} -> ${src}（原 ${current}）"
    fi
    updated=$((updated + 1))
    return 0
  fi

  if [ -e "$dst" ]; then
    echo "  ! 跳过 ${label}: ${dst} 已存在且不是软链（不覆盖真实目录）"
    skipped=$((skipped + 1))
    if [ "$CHECK" -eq 1 ]; then
      issues=$((issues + 1))
    fi
    return 0
  fi

  if [ "$CHECK" -eq 1 ]; then
    echo "  ✗ ${label}: 缺少软链 ${dst} -> ${src}"
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

# 清理悬空软链：只处理「指向本源的某技能、但该技能已不在本源」的链接
clean_stale() {
  local target_root="$1"
  local target
  local real

  [ -d "$target_root" ] || return 0
  for target in "$target_root"/*; do
    [ -L "$target" ] || continue
    real="$(readlink "$target")"
    case "$real" in
      "$HUB"/*)
        if [ ! -e "$real" ]; then
          if [ "$CHECK" -eq 1 ]; then
            echo "  ✗ 悬空软链 ${target} -> ${real}（本源已无该技能）"
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

echo "==> 技能本源:  ${HUB}"
echo "==> agents:  ${AGENTS}"
if [ "$CHECK" -eq 1 ]; then
  echo "==> 模式: 只检查（不修改）"
elif [ "$DRY_RUN" -eq 1 ]; then
  echo "==> 模式: dry-run（不落盘）"
fi

while IFS= read -r agent; do
  [ -n "$agent" ] || continue
  target_root="$(agent_dir "$agent")"
  echo "==> ${agent} -> ${target_root}"
  clean_stale "$target_root"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    link_skill "$HUB/$name" "$target_root/$name" "${agent} ${name}"
  done <<EOF
$(hub_skills)
EOF
done <<EOF
$AGENT_LIST
EOF

if [ "$CHECK" -eq 1 ]; then
  echo "==> 检查完成：${issues} 项问题（已一致 ${unchanged} 项，悬空 ${removed} 项）"
  if [ "$issues" -gt 0 ]; then
    echo "    修复：去掉 --check 重跑本脚本；被真实目录占位的先自行移走（脚本不覆盖）。"
    exit 1
  fi
  echo "    全部就绪。"
  exit 0
fi

echo "==> 完成：新建 ${linked} 项，改指向 ${updated} 项，已最新 ${unchanged} 项，跳过 ${skipped} 项，清理 ${removed} 项"
