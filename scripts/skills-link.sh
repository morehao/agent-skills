#!/usr/bin/env bash
# 把本仓 skills/* 软链到「本地技能统一安装位」（默认 ~/.agents/skills）。
#
# 为什么统一到 ~/.agents/skills：
#   - 这是 `skills` CLI（`-g -a universal`）的 canonical 全局目录，也是 dsh 默认扫描的技能根；
#   - opencode 等工具只需一条配置指过来（opencode：config 的 `skills` 数组），不必每个工具各挂一份；
#   - 本仓仍是唯一真源：软链让「改本仓即生效」在结构上成立，而不是靠记得 --update。
#   第三方技能（officecli、weather-query 等）仍由 `skills` CLI 装进同一个目录，二者互不干扰。
#
# 幂等：已一致的软链跳过；指向别处的软链更新；指向本仓但目标已不存在的悬空软链清理。
# 遇到同名**真实目录**（例如之前用 skills CLI 装过的快照）默认跳过、不覆盖；要替换用 --force
# （先把旧目录改名成 <name>.bak-<时间戳>，不删数据）。
#
# 用法：./scripts/skills-link.sh [选项]
#
#   --check          只检查不修改：缺失/指向错误/悬空/被真实目录占位 都算问题，有问题退出 1
#   --dry-run        只打印将执行的操作，不落盘
#   --force          遇到同名真实目录时，先重命名为 <name>.bak-<时间戳> 再软链（不删除）
#   --target <dir>   覆盖安装位，默认 ~/.agents/skills
#   -h, --help       显示帮助
#
# 环境变量：
#   AGENTS_SKILLS_DIR  安装位，默认 $HOME/.agents/skills
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_SRC="$REPO_ROOT/skills"
TARGET="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"

CHECK=0
DRY_RUN=0
FORCE=0

linked=0
updated=0
unchanged=0
skipped=0
replaced=0
removed=0
issues=0

usage() {
  cat <<'EOF'
用法: ./scripts/skills-link.sh [选项]

  --check          只检查不修改：缺失、指向错误、悬空软链、被真实目录占位都算问题，有问题退出 1。
  --dry-run        只打印将执行的操作。
  --force          同名真实目录先重命名为 <name>.bak-<时间戳> 再软链（不删除数据）。
  --target <dir>   覆盖安装位，默认 ~/.agents/skills。
  -h, --help       显示本帮助。

环境变量:
  AGENTS_SKILLS_DIR  安装位，默认 $HOME/.agents/skills

说明:
  技能只有一个安装位；各工具去那里读（opencode 用 config 的 skills 数组，dsh 默认扫描）。
  本仓 skills/<name> 软链进去，改本仓即生效；第三方技能由 skills CLI 装进同一目录，互不干扰。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check)
      CHECK=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --target)
      if [ $# -lt 2 ]; then
        echo "错误：--target 需要一个目录参数" >&2
        exit 2
      fi
      TARGET="$2"
      shift 2
      ;;
    --target=*)
      TARGET="${1#*=}"
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

if [ ! -d "$SKILLS_SRC" ]; then
  echo "错误：找不到技能源目录 ${SKILLS_SRC}" >&2
  exit 2
fi

# 软链一个技能目录：一致则跳过；是软链则更新；真实目录默认跳过（--force 时改名备份后替换）。
link_skill() {
  local src="$1"
  local dst="$2"
  local label="$3"
  local current
  local backup

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
      echo "  ✗ ${label}: ${dst} -> ${current}（应为 ${src}）"
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
    if [ "$FORCE" -eq 0 ]; then
      echo "  ! 跳过 ${label}: ${dst} 已存在且不是软链（可能是 skills CLI 装的快照；确认后用 --force 备份并替换）"
      skipped=$((skipped + 1))
      if [ "$CHECK" -eq 1 ]; then
        issues=$((issues + 1))
      fi
      return 0
    fi
    backup="${dst}.bak-$(date +%Y%m%d-%H%M%S)"
    if [ "$CHECK" -eq 1 ]; then
      echo "  ✗ ${label}: ${dst} 被真实目录占位（--force 会先改名为 ${backup}）"
      issues=$((issues + 1))
      return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  [dry-run] 备份 ${dst} -> ${backup}，再软链 -> ${src}"
    else
      mv "$dst" "$backup"
      ln -sfn "$src" "$dst"
      echo "  备份并替换 ${dst}（旧目录：${backup}）-> ${src}"
    fi
    replaced=$((replaced + 1))
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

# 清理悬空软链：只处理「指向本仓 skills/、但目标已不存在」的链接（技能改名后残留）。
clean_stale() {
  local target_root="$1"
  local target
  local real

  [ -d "$target_root" ] || return 0
  for target in "$target_root"/*; do
    [ -L "$target" ] || continue
    real="$(readlink "$target")"
    case "$real" in
      "$SKILLS_SRC"/*)
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

echo "==> agent-skills 根目录:  ${REPO_ROOT}"
echo "==> 技能安装位:  ${TARGET}"
if [ "$CHECK" -eq 1 ]; then
  echo "==> 模式: 只检查（不修改）"
elif [ "$DRY_RUN" -eq 1 ]; then
  echo "==> 模式: dry-run（不落盘）"
fi

if [ "$CHECK" -eq 1 ]; then
  if [ ! -d "$TARGET" ]; then
    echo "  ✗ 目录不存在：${TARGET}"
    issues=$((issues + 1))
  fi
elif [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$TARGET"
fi

clean_stale "$TARGET"

for skill_dir in "$SKILLS_SRC"/*/; do
  [ -d "$skill_dir" ] || continue
  skill_dir="${skill_dir%/}"   # 去掉 glob 的尾部斜杠，让软链目标干净可比对
  link_skill "$skill_dir" "$TARGET/$(basename "$skill_dir")" "技能 $(basename "$skill_dir")"
done

if [ "$CHECK" -eq 1 ]; then
  echo "==> 检查完成：${issues} 项问题（已一致 ${unchanged} 项，悬空 ${removed} 项）"
  if [ "$issues" -gt 0 ]; then
    echo "    修复：去掉 --check 重跑；被真实目录占位的用 --force（会先备份成 <name>.bak-<时间戳>）。"
    exit 1
  fi
  echo "    全部就绪。"
  exit 0
fi

echo "==> 完成：新建 ${linked} 项，更新 ${updated} 项，已最新 ${unchanged} 项，备份替换 ${replaced} 项，跳过 ${skipped} 项，清理 ${removed} 项"
echo "    技能安装位：${TARGET}"
