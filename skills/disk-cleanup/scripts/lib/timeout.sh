#!/usr/bin/env bash
# 超时执行器：纯 bash 3.2，不依赖 gtimeout / perl。
# 调用方：run_timeout <秒> <命令...>；超时或被杀返回 124。
[[ -n "${_DC_TIMEOUT_LOADED:-}" ]] && return 0
_DC_TIMEOUT_LOADED=1

# run_timeout <秒> <命令...>
# 说明：只保证终止直接子进程。find/du 这类单进程足够；brew/docker 若有孙进程，
# 由它们自己收尾（不引入进程组操作，避免 set -m 影响非交互环境）。
run_timeout() {
    local secs="${1:-10}" rc=0 pid wd
    shift
    [[ $# -gt 0 ]] || return 2
    case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
    [[ "$secs" -gt 0 ]] || secs=1

    ( "$@" ) &
    pid=$!
    # 看门狗必须「目标一结束就退出」：早先写法是 `sleep $secs` 一觉睡到底，
    # 每次调用都留一个长睡进程；删除漏斗按路径调用时，几千个路径就能顶满
    # macOS 默认 4000 的进程上限（fork: Resource temporarily unavailable）。
    # 这里改成轮询 + 退避：进程没了立刻退出，长任务最多 1+2+4+… 次 sleep。
    ( _el=0 _iv=1
      while [[ "$_el" -lt "$secs" ]]; do
          sleep "$_iv" 2>/dev/null
          _el=$((_el + _iv))
          kill -0 "$pid" 2>/dev/null || exit 0
          [[ "$_iv" -lt 30 ]] && _iv=$((_iv * 2))
      done
      kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    wd=$!

    wait "$pid" 2>/dev/null || rc=$?
    kill -TERM "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null || true

    # 被信号终止时 wait 返回 128+signum，统一归为超时
    if [[ "$rc" -gt 128 && "$rc" -ne 127 ]]; then rc=124; fi
    return "$rc"
}

# 常用档位（集中常量，避免散落魔数）
DC_TIMEOUT_QUICK=3      # lsof 能力探针、lsappinfo
DC_TIMEOUT_QUERY=10     # osascript / mdfind 单次查询
DC_TIMEOUT_DU=120       # du 统计
DC_TIMEOUT_FIND=60      # find -mmin 活跃度探测
DC_TIMEOUT_BREW=900     # brew cleanup
DC_TIMEOUT_DOCKER=300   # docker system prune
