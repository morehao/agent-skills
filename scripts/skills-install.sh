#!/usr/bin/env bash
# 把本仓 skills/* 发布到「技能本源目录」~/.agents/skills（走 skills CLI）。
#
# 模型（方向别搞反）：
#   本仓（编辑/版本源） --skills CLI 安装--> ~/.agents/skills（本源，真实内容）
#                                              |
#                                              +--软链--> ~/.config/opencode/skills/<name>
#                                              +--软链--> ~/.dsh/skills/<name>（skills-fanout.sh 负责）
#   所以：改本仓**不会**自动生效，要 push 到远端后再跑本脚本；软链那一侧只指向本源。
#
# 安装命令与 dsh-commands 的 /skill-init 一致：
#   npx -y skills add <来源> --skill <名> ... -g -a universal -y
#   （`-a universal` 只写 ~/.agents/skills，不往各 agent 目录撒链；撒链由 skills-fanout.sh 负责）
#
# 用法：./scripts/skills-install.sh [选项]
#
#   --source <owner/repo|url>  技能来源，默认 morehao/agent-skills
#   --check                    只读：比对本源与本仓内容，列出缺失/落后项；有问题退出 1
#   --dry-run                  只打印将执行的 skills 命令
#   -h, --help                 显示帮助
#
# 环境变量：
#   AGENTS_SKILLS_DIR  本源目录，默认 $HOME/.agents/skills
#   SKILLS_CLI         覆盖 CLI 调用（测试用，可按空格分词），默认 `npx -y skills`
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_SRC="$REPO_ROOT/skills"
HUB="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
SOURCE="morehao/agent-skills"

CHECK=0
DRY_RUN=0
issues=0

usage() {
  cat <<'EOF'
用法: ./scripts/skills-install.sh [选项]

  --source <owner/repo|url>  技能来源，默认 morehao/agent-skills。
  --check                    只读比对：本源 ~/.agents/skills 与本仓内容是否一致，有问题退出 1。
  --dry-run                  只打印将执行的 skills 命令，不落盘。
  -h, --help                 显示本帮助。

环境变量:
  AGENTS_SKILLS_DIR  本源目录，默认 $HOME/.agents/skills
  SKILLS_CLI         覆盖 CLI 调用（测试用），默认 `npx -y skills`

说明:
  本仓是编辑源，不是运行时真源。发布 = push 到远端 + 本脚本（skills CLI 安装）。
  各 agent 目录的软链由 skills-fanout.sh 生成，本脚本不碰。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      if [ $# -lt 2 ]; then
        echo "错误：--source 需要一个参数" >&2
        exit 2
      fi
      SOURCE="$2"
      shift 2
      ;;
    --source=*)
      SOURCE="${1#*=}"
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

if [ ! -d "$SKILLS_SRC" ]; then
  echo "错误：找不到技能源目录 ${SKILLS_SRC}" >&2
  exit 2
fi

# 收集本仓技能名（只遍历目录）
SKILL_NAMES=""
SKILL_COUNT=0
for skill_dir in "$SKILLS_SRC"/*/; do
  [ -d "$skill_dir" ] || continue
  name="$(basename "${skill_dir%/}")"
  SKILL_NAMES="${SKILL_NAMES}${SKILL_NAMES:+ }${name}"
  SKILL_COUNT=$((SKILL_COUNT + 1))
done
if [ "$SKILL_COUNT" -eq 0 ]; then
  echo "错误：${SKILLS_SRC} 下没有技能目录" >&2
  exit 2
fi

echo "==> agent-skills 根目录:  ${REPO_ROOT}"
echo "==> 技能本源:  ${HUB}"
echo "==> 技能来源:  ${SOURCE}（${SKILL_COUNT} 个技能）"

# git 预检：CLI 装的是**远端**内容，本地未提交/未推送时先提醒
git_warnings() {
  local dirty
  local ahead
  dirty="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | head -5 || true)"
  if [ -n "$dirty" ]; then
    echo "  ! 本仓有未提交改动；skills CLI 装的是远端内容，这些改动不会被发布："
    echo "$dirty" | sed 's/^/      /'
  fi
  ahead="$(git -C "$REPO_ROOT" rev-list --count origin/main..HEAD 2>/dev/null || true)"
  case "$ahead" in
    ''|0) ;;
    *)
      echo "  ! 本地领先 origin/main ${ahead} 个提交；先 push 再安装，否则装到的是旧内容。"
      ;;
  esac
}

# ---------- --check：只读比对本源与本仓 ----------
if [ "$CHECK" -eq 1 ]; then
  if [ ! -d "$HUB" ]; then
    echo "  ✗ 本源目录不存在：${HUB}"
    echo "    修复：去掉 --check 跑一次 ./scripts/skills-install.sh"
    exit 1
  fi
  for name in $SKILL_NAMES; do
    if [ ! -d "$HUB/$name" ]; then
      echo "  ✗ 本源缺少技能：${name}（跑 ./scripts/skills-install.sh 安装）"
      issues=$((issues + 1))
      continue
    fi
    diff_out="$(diff -rq -x node_modules -x .git -x '.DS_Store' "$SKILLS_SRC/$name" "$HUB/$name" 2>&1 | head -5 || true)"
    if [ -n "$diff_out" ]; then
      echo "  ! 本源与本仓不一致：${name}"
      echo "$diff_out" | sed 's/^/      /'
      issues=$((issues + 1))
    else
      echo "  ✓ ${name}"
    fi
  done
  git_warnings
  if [ "$issues" -gt 0 ]; then
    echo "==> 检查完成：${issues} 个技能需要发布（本源与仓库不同步）"
    echo "    发布：git push（到 ${SOURCE} 的默认分支）→ ./scripts/skills-install.sh"
    exit 1
  fi
  echo "==> 检查完成：本源与仓库一致（${SKILL_COUNT} 个技能）"
  exit 0
fi

# ---------- 安装 ----------
git_warnings

run_cli() {
  if [ -n "${SKILLS_CLI:-}" ]; then
    # 测试钩子：允许带参数（如 "/tmp/stub-skills --flag"），刻意按空格分词
    # shellcheck disable=SC2086
    ${SKILLS_CLI} "$@"
  else
    npx -y skills "$@"
  fi
}

set -- add "$SOURCE"
for name in $SKILL_NAMES; do
  set -- "$@" --skill "$name"
done
set -- "$@" -g -a universal -y

if [ "$DRY_RUN" -eq 1 ]; then
  echo "  [dry-run] ${SKILLS_CLI:-npx -y skills} $*"
  exit 0
fi

echo "==> 安装：${SKILLS_CLI:-npx -y skills} $*"
if ! run_cli "$@"; then
  echo "错误：skills CLI 安装失败。" >&2
  echo "  排错：确认网络可达 ${SOURCE}（GitHub），或先用 --dry-run 看命令；CI/无网环境不要跑本脚本。" >&2
  exit 1
fi

# ---------- 安装后校验本源 ----------
missing=0
for name in $SKILL_NAMES; do
  if [ ! -f "$HUB/$name/SKILL.md" ]; then
    echo "  ✗ 安装后仍缺少 ${HUB}/${name}/SKILL.md"
    missing=$((missing + 1))
  fi
done
if [ "$missing" -gt 0 ]; then
  echo "错误：${missing} 个技能未落到本源目录。" >&2
  exit 1
fi

echo "==> 完成：${SKILL_COUNT} 个技能已就位 -> ${HUB}"
echo "    下一步：./scripts/skills-fanout.sh    # 把本源软链到各 agent 目录（opencode / dsh）"
