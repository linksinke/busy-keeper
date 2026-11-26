#!/usr/bin/env bash
# =============================================================================
# common.sh — 压测工具集公共库
#
# 版本     : 1.0.0
# 许可证   : MIT
# 作者     : 压测工具维护组
# 功能     : 被 cpu/mem/disk *_ctl.sh source 的公共库：
#            LOGO 横幅 / 解释器解析 / 日志 / 环境检查 / PID 安全 /
#            进程操作 / 脱敏 / 日志轮转 / 统一运维命令与主入口
# 注意     : 本文件非独立可执行，须由 ctl 脚本 source（勿直接运行）。
#
# 分区说明:
#   [0] LOGO / 版本        — _logo_show
#   [1] 解释器与日志       — _common_resolve_python / _common_log / _common_die
#   [2] 环境检查           — _common_ensure_env
#   [3] PID 安全区         — 杀进程前必须「本用户 + cmdline 含标记」
#   [4] 进程公共操作       — is_alive / is_our_worker / safe_kill
#   [5] 脱敏 / 日志轮转    — redact / rotate
#   [6] 运维通用 OPS       — logs / usage / main（命令分发框架）
# =============================================================================

set -u

# =============================================================================
# [0.1] 公共默认变量（三工具都 source common.sh，故公共配置放这里兜底）
# 说明: 这些变量属于「公共能力」（脱敏 / 日志轮转），不依赖 safety_policy.sh，
#       故磁盘等不含策略库的工具也能用；safety_policy.sh 可再覆盖同名默认值。
# =============================================================================
: "${SAFETY_REDACT:=0}"        # 1=脱敏模式：help/params/safety/status/logs 不显示路径/PID/精确参数
: "${LOG_MAX_BYTES:=10485760}" # 日志轮转阈值（字节，默认 10MB；超过则 mv 为 .1）
: "${LOG_KEEP_DAYS:=30}"       # 轮转副本(.1)保留天数；超过则删除（默认 30 天≈每月清理一次）；0=不按天清理

# =============================================================================
# [0] LOGO / 版本
# =============================================================================
# 使用前需在 ctl 中定义: STRESS_TOOL_NAME（工具名）、TOOL_VERSION（版本号）
_logo_show() {
  cat <<'LOGO'
  __                           ___                 
 / _\ ___ _ ____   _____ _ __ / __\_   _ ___ _   _ 
 \ \ / _ \ '__\ \ / / _ \ '__/__\// | | / __| | | |
 _\ \  __/ |   \ V /  __/ | / \/  \ |_| \__ \ |_| |
 \__/\___|_|    \_/ \___|_| \_____/\__,_|___/\__, |
                                             |___/ 
  Server Busy · 服务器很忙 · High Load
LOGO
  echo "  ${STRESS_TOOL_NAME:-压测工具}  v${TOOL_VERSION:-1.0.0}"
  echo
}

# =============================================================================
# [1] 解释器与日志
# =============================================================================

# 解析 python 解释器；优先 STRESS_PYTHON，其次 python2 / python / python3
_common_resolve_python() {
  if [ -n "${STRESS_PYTHON}" ]; then
    echo "${STRESS_PYTHON}"
    return
  fi
  if command -v python2 >/dev/null 2>&1; then
    echo "python2"
    return
  fi
  if command -v python >/dev/null 2>&1; then
    ver="$(python -c 'import sys; print(sys.version_info[0])' 2>/dev/null || echo 0)"
    case "$ver" in
      2|3) echo "python"; return ;;
    esac
  fi
  if command -v python3 >/dev/null 2>&1; then
    echo "python3"
    return
  fi
  echo ""
}

CFG_PYTHON="$(_common_resolve_python)"

# 统一日志：stdout + CTL 日志文件（写前轮转）。
# STRESS_LOG_QUIET=1 时只写 ctl.log、不 echo stdout：
#   供后台调度器使用，避免每拍心跳大量刷入 schedule.out；
#   操作诊断仍完整写入 ctl.log，schedule.out 只保留启动留痕与异常。
_common_log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')"
  if [ "${STRESS_LOG_QUIET:-0}" != "1" ]; then
    echo "[$ts] [$STRESS_ROLE] $*"
  fi
  mkdir -p "${STRESS_DATADIR}" "${STRESS_LOGDIR}" 2>/dev/null || true
  _common_rotate_file "${CFG_LOG_CTL}"
  echo "[$ts] [$STRESS_ROLE] $*" >>"${CFG_LOG_CTL}" 2>/dev/null || true
}

_common_die() {
  _common_log "ERROR: $*"
  exit 1
}

# =============================================================================
# [2] 环境检查
# =============================================================================
# 校验：解释器 / 负载脚本 / common.sh / 可写目录；
# 当 ctl 定义 STRESS_NEED_SAFETY=1 时，额外校验 safety_policy.sh 存在
_common_ensure_env() {
  [ -n "${CFG_PYTHON}" ] || _common_die "需要 python2 或 python3（export STRESS_PYTHON=python2）"
  [ -f "${CFG_WORKER_PY}" ] || _common_die "找不到 ${CFG_WORKER_PY}"
  [ -f "${CFG_SCRIPT_DIR}/common.sh" ] || _common_die "找不到 common.sh"
  if [ "${STRESS_NEED_SAFETY:-0}" = "1" ]; then
    [ -f "${CFG_SCRIPT_DIR}/safety_policy.sh" ] || _common_die "找不到 safety_policy.sh"
  fi
  mkdir -p "${STRESS_PIDDIR}" "${STRESS_DATADIR}" "${STRESS_LOGDIR}" || _common_die "无法创建 ${STRESS_PIDDIR} 或 ${STRESS_DATADIR}"
}

# =============================================================================
# [3] PID 安全区 — 杀进程前必须「本用户 + cmdline 含标记」
# =============================================================================

# 进程是否属于当前用户（读 /proc/pid/status 的 Uid）
# $1 = pid
safety_pid_owned_by_me() {
  local pid="$1" uid me
  echo "$pid" | grep -Eq '^[0-9]+$' || return 1
  [ -d "/proc/$pid" ] || return 1
  me="$(id -u 2>/dev/null || echo 0)"
  uid="$(awk '/^Uid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null)"
  [ -n "$uid" ] && [ "$uid" = "$me" ]
}

# cmdline 是否包含标记串（建议传脚本绝对路径）
# $1 = pid  $2 = needle
safety_pid_cmdline_has() {
  local pid="$1" needle="$2" cmd
  [ -n "$needle" ] || return 1
  [ -r "/proc/$pid/cmdline" ] || return 1
  cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)"
  case "$cmd" in
    *"$needle"*) return 0 ;;
    *) return 1 ;;
  esac
}

# 是否可视为「本工具拉起的进程」
# $1 = pid  $2 = cmdline 标记（如 .../cpu_burn.py）
safety_is_our_pid() {
  local pid="$1" marker="$2"
  echo "$pid" | grep -Eq '^[0-9]+$' || return 1
  [ "$pid" -gt 1 ] || return 1
  safety_pid_owned_by_me "$pid" || return 1
  safety_pid_cmdline_has "$pid" "$marker" || return 1
  return 0
}

# 安全 kill：校验通过才发信号；失败打印 REFUSE（stdout），返回非 0
# $1 = pid  $2 = marker  $3 = 可选信号（默认 -TERM）
safety_safe_kill() {
  local pid="$1" marker="$2" sig="${3:--TERM}"
  if ! safety_is_our_pid "$pid" "$marker"; then
    echo "REFUSE kill pid=${pid} marker=${marker} (not our process or not owned by uid=$(id -u))"
    return 1
  fi
  kill "$sig" "$pid" 2>/dev/null
}

# 仅扫本用户、cmdline 含标记的进程并终止（替代裸 pkill -f，避免误伤）
# $1 = marker
safety_sweep_ours() {
  local marker="$1" pid
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -u "$(id -u)" -f "$marker" 2>/dev/null | while read -r pid; do
      [ -n "$pid" ] || continue
      safety_safe_kill "$pid" "$marker" >/dev/null 2>&1 || true
    done
    return 0
  fi
  # 无 pgrep 时退化为扫 /proc（仅本 uid）
  for pid in /proc/[0-9]*; do
    pid="${pid#/proc/}"
    echo "$pid" | grep -Eq '^[0-9]+$' || continue
    safety_safe_kill "$pid" "$marker" >/dev/null 2>&1 || true
  done
}

# 列出本 uid 下 cmdline 含标记的本工具进程；stdout=每行一个 pid
# $1 = marker
safety_list_ours() {
  local marker="$1" pid
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -u "$(id -u)" -f "$marker" 2>/dev/null | while read -r pid; do
      [ -n "$pid" ] || continue
      safety_is_our_pid "$pid" "$marker" && echo "$pid"
    done
    return 0
  fi
  for pid in /proc/[0-9]*; do
    pid="${pid#/proc/}"
    echo "$pid" | grep -Eq '^[0-9]+$' || continue
    safety_is_our_pid "$pid" "$marker" && echo "$pid"
  done
}

# 杀掉本工具进程中「不在保留列表」的；保留列表文件每行一个 pid
# $1 = marker  $2 = keep 文件路径（可空/不存在=全杀，等同 sweep）
safety_kill_ours_except() {
  local marker="$1" keepf="${2:-}" pid
  safety_list_ours "$marker" | while read -r pid; do
    [ -n "$pid" ] || continue
    if [ -n "$keepf" ] && [ -f "$keepf" ] && grep -qx "$pid" "$keepf" 2>/dev/null; then
      continue
    fi
    safety_safe_kill "$pid" "$marker" >/dev/null 2>&1 || true
  done
}

# =============================================================================
# [4] 进程公共操作
# =============================================================================

# 进程是否存活
_common_is_alive() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

# 是否为本工具 worker（属主 + cmdline 含 CFG_WORKER_PY）
_common_is_our_worker() {
  local pid="$1"
  _common_is_alive "$pid" && safety_is_our_pid "$pid" "${CFG_WORKER_PY}"
}

# 安全 kill worker；假 PID 拒绝
_common_safe_kill_worker() {
  local pid="$1" msg rc
  msg="$(safety_safe_kill "$pid" "${CFG_WORKER_PY}" 2>&1)"
  rc=$?
  if [ $rc -ne 0 ]; then
    [ -n "$msg" ] && _common_log "$msg"
    return 1
  fi
  return 0
}

# 安全 kill 调度器
_common_safe_kill_schedule() {
  local pid="$1" msg
  if msg="$(safety_safe_kill "$pid" "${CFG_CTL_SCRIPT}" 2>&1)"; then
    return 0
  fi
  if msg="$(safety_safe_kill "$pid" "${CFG_CTL_BASENAME}" 2>&1)"; then
    return 0
  fi
  [ -n "$msg" ] && _common_log "$msg"
  return 1
}

# =============================================================================
# [5] 脱敏 / 日志轮转
# =============================================================================

# 日志轮转：超过 LOG_MAX_BYTES 则 mv 为 .1（不追日志原文）。
# 按天清理：轮转前若旧副本 .1 已超过 LOG_KEEP_DAYS 天未更新（低频使用场景），
# 先删除再轮转，避免旧日志长期滞留（默认保留 30 天 ≈ 每月清理一次；0=不按天清理）。
_common_rotate_file() {
  local f="$1" sz keep_days
  [ -n "$f" ] && [ -f "$f" ] || return 0
  sz="$(wc -c <"$f" 2>/dev/null | tr -d ' ')"
  [ -n "$sz" ] || sz=0
  if [ "${sz:-0}" -ge "${LOG_MAX_BYTES:-10485760}" ] 2>/dev/null; then
    keep_days="${LOG_KEEP_DAYS:-30}"
    if [ "${keep_days}" -gt 0 ] 2>/dev/null && [ -f "${f}.1" ]; then
      if find "${f}.1" -mtime +"${keep_days}" 2>/dev/null | grep -q .; then
        rm -f "${f}.1" 2>/dev/null || true
      fi
    fi
    mv -f "$f" "${f}.1" 2>/dev/null || true
  fi
}

# 脱敏路径：SAFETY_REDACT=1 时去掉脚本目录前缀，只留相对/占位
_ops_redact_path() {
  local p="$1" base
  base="${CFG_SCRIPT_DIR:-.}/"
  if [ "${SAFETY_REDACT}" = "1" ]; then
    case "$p" in
      "${base}"*) echo "${p#"$base"}" ;;
      *) echo "<path>" ;;
    esac
  else
    echo "$p"
  fi
}

# 脱敏提示行（REDACT=1 时输出提示）
_ops_redact_note() {
  if [ "${SAFETY_REDACT}" = "1" ]; then
    echo "[已脱敏] 路径/PID/精确参数等内部信息仅由授权运维在服务器本机查看"
  fi
}

# =============================================================================
# [6] 运维通用 OPS — logs / usage / main（命令分发框架）
# =============================================================================

# 展示最近日志；SAFETY_REDACT=1（脱敏）时仅显示行数，不输出原文。
# $1 = 行数 N（默认 40）。日志位置由各 ctl 的 CFG_LOG_CTL / CFG_LOG_SCHEDULE 决定。
_ops_logs() {
  local n="${1:-40}"
  local c1=0 c2=0
  _common_ensure_env
  if [ "${SAFETY_REDACT}" = "1" ]; then
    [ -f "${CFG_LOG_CTL}" ] && c1="$(wc -l <"${CFG_LOG_CTL}" | tr -d ' ')"
    [ -n "${CFG_LOG_SCHEDULE:-}" ] && [ -f "${CFG_LOG_SCHEDULE}" ] && c2="$(wc -l <"${CFG_LOG_SCHEDULE}" | tr -d ' ')"
    echo "=== 日志（脱敏模式，仅显示行数） ==="
    echo "ctl.log: ${c1} 行 | schedule.out: ${c2} 行"
    $(_ops_redact_note)
    return 0
  fi
  echo "=== ${CFG_LOG_CTL} (last $n) ==="
  if [ -f "${CFG_LOG_CTL}" ]; then tail -n "$n" "${CFG_LOG_CTL}"; else echo "(empty)"; fi
  if [ -n "${CFG_LOG_SCHEDULE:-}" ] && [ -f "${CFG_LOG_SCHEDULE}" ]; then
    echo "=== ${CFG_LOG_SCHEDULE} (last $n) ==="
    tail -n "$n" "${CFG_LOG_SCHEDULE}"
  fi
  if [ -n "${CFG_SCHEDULE_PID_FILE:-}" ] && [ -f "${CFG_SCHEDULE_PID_FILE}" ]; then
    echo "schedule.pid=$(cat "${CFG_SCHEDULE_PID_FILE}") alive=$(_common_is_alive "$(cat "${CFG_SCHEDULE_PID_FILE}")" && echo YES || echo NO)"
  fi
}

# 输出统一命令帮助（含 LOGO 横幅）。
# 命令集对 cpu/mem/disk 完全一致；其中「start [N]」的参数含义
# 由各 ctl 预置的 CFG_USAGE_START_ARG 定制（cpu=worker 数 / mem=MB / disk=MB）。
_ops_usage() {
  _logo_show
  cat <<EOF
用法: $0 <command> [可选参数]

命令:
  start [N]     按安全策略启动
                ${CFG_USAGE_START_ARG}
  stop          停止所有压测进程
  status        状态（是否在跑 + 配置 + 当前占用）
  restart [N]   先 stop 再 start；参数含义同 start
  schedule      前台调度（分时切换 + 保活）
  schedule-bg   后台调度（推荐长期跑）
  safety        策略/配额速览
  params        可调环境变量一览（当前值）
  logs [N]      最近日志；N=行数，默认 40
  help          本说明

示例:
  $0 schedule-bg              # 推荐：后台调度
  $0 start                    # 只启一次
  $0 logs 80

环境变量调参见: $0 params
PID: $(_ops_redact_path "${STRESS_PID_FILE}")
LOG: $(_ops_redact_path "${CFG_LOG_CTL}")
EOF
}

# 校验「不接受额外参数」的命令：若 $2 非空（用户多写了参数）则报错退出。
# 用于 status / stop / schedule / safety 等无参命令，避免 `start safety` 这类误用。
_main_reject_extra() {
  local cmd="$1" junk="$2"
  [ -z "$junk" ] && return 0
  _common_die "命令『${cmd}』不接受参数，你多写了: '${junk}'
正确示例:
  $0 ${cmd}
  $0 start          # 启动（可选数字）
  $0 safety         # 看策略
  $0 params         # 看可调变量
  $0 help"
}

# 可选正整数参数；空则用默认
_main_opt_uint() {
  local name="$1" val="$2" default="$3"
  if [ -z "$val" ]; then
    echo "$default"
    return
  fi
  if ! echo "$val" | grep -Eq '^[0-9]+$'; then
    _common_die "『${name}』必须是非负整数，你写的是: '${val}'
例: $0 ${name% *} 40"
  fi
  echo "$val"
}

# 统一命令分发（cpu/mem/disk 共用）。
# 接收 CLI 首个/次个/多余参数，按命令路由到各 ctl 自己实现的业务函数：
#   start/stop/restart/schedule/schedule-bg → _biz_*（各 ctl 实现）
#   status/params/safety → _ops_status / _ops_params / _ops_safety（各 ctl 实现）
#   logs/help → 本库公共实现。
# 由于在 common.sh 中定义、被 source 到各 ctl 里，故能调用到各 ctl 定义的 _biz_* / _ops_*。
_main() {
  local cmd="${1:-}" arg="${2:-}" extra="${3:-}"
  case "$cmd" in
    start)
      [ -n "$extra" ] && _common_die "start 最多一个数字参数，多余: '${extra}'"
      _logo_show
      _biz_start "$arg"
      ;;
    stop)
      _main_reject_extra stop "$arg"
      _biz_stop_all
      ;;
    status)
      _main_reject_extra status "$arg"
      _ops_status
      ;;
    restart)
      [ -n "$extra" ] && _common_die "restart 最多一个数字参数，多余: '${extra}'"
      _logo_show
      _biz_stop_all
      _biz_start "$arg"
      ;;
    schedule)
      _main_reject_extra schedule "$arg"
      _logo_show
      _biz_schedule_loop
      ;;
    schedule-bg)
      _main_reject_extra "schedule-bg" "$arg"
      _logo_show
      _biz_schedule_bg
      ;;
    safety)
      _main_reject_extra safety "$arg"
      _logo_show
      _ops_safety
      ;;
    params|param)
      _main_reject_extra params "$arg"
      _logo_show
      _ops_params
      ;;
    logs|log)
      [ -n "$extra" ] && _common_die "logs 最多一个数字参数（行数），多余: '${extra}'"
      _ops_logs "$(_main_opt_uint "logs" "$arg" 40)"
      ;;
    help|-h|--help|"")
      _ops_usage
      ;;
    *)
      _ops_usage
      _common_die "未知命令: '${cmd}'  可用: start|stop|status|restart|schedule|schedule-bg|safety|params|logs|help"
      ;;
  esac
}
