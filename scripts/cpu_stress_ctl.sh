#!/usr/bin/env bash
# =============================================================================
# cpu_stress_ctl.sh — CPU 利用率压测控制脚本
#
# 版本     : 1.0.0
# 许可证   : MIT
# 作者     : 压测工具维护组
# 依赖组件 : common.sh（必需）、safety_policy.sh（必需）、cpu_burn.py（必需）
# 运行环境 : bash（3.2+）+ python2 / python3（自动探测）
# 功能     : CPU 占用闭环控制（分时 / 保活 / 安全降载 / 孤儿清理 / PID 登记）
#
# 分区说明:
#   [1] 配置区 CONFIG  — 环境变量与路径，可 export 覆盖
#   [2] 公共库 COMMON  — source common.sh（logo/日志/PID 安全/运维框架）
#   [3] 策略库 SAFETY  — source safety_policy.sh（CPU/MEM 业务策略）
#   [4] 业务函数区 BIZ — 本工具业务实现（worker 启停与调度）
#   [5] 运维差异 OPS   — status / params / safety（本工具定制输出）
#   [6] 主入口 MAIN    — _main "$@"（统一分发在 common.sh）
# =============================================================================

set -u

STRESS_TOOL_NAME="CPU 压测工具"
TOOL_VERSION="1.0.0"

# =============================================================================
# [1] 配置区 CONFIG
# =============================================================================

# --- 角色标识（本脚本固定为 cpu）---
STRESS_ROLE="cpu"

# --- 路径与解释器（仅 STRESS_*）---
CFG_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# PID 目录（默认：脚本目录）— 仅放 *.pid
: "${STRESS_PIDDIR:=${CFG_SCRIPT_DIR}}"

# 数据目录（默认：脚本目录/data）— 日志、target、诊断等（不含 pid）
: "${STRESS_DATADIR:=${CFG_SCRIPT_DIR}/data}"

# 日志目录（默认：同 DATADIR；可单独覆盖）
: "${STRESS_LOGDIR:=${STRESS_DATADIR}}"

# Python 环境（python2/python3；空则启动时自动探测）
: "${STRESS_PYTHON:=}"

# 调度周期（秒，默认 15；更快补回异常退出的 worker）
: "${STRESS_SCHEDULE_INTERVAL:=15}"

# PID 文件（默认：${STRESS_PIDDIR}/cpu.pid）
: "${STRESS_PID_FILE:=${STRESS_PIDDIR}/cpu.pid}"

# 工作负载脚本 / 运行态文件
CFG_WORKER_PY="${CFG_SCRIPT_DIR}/cpu_burn.py"
CFG_CTL_SCRIPT="${CFG_SCRIPT_DIR}/cpu_stress_ctl.sh"
CFG_CTL_BASENAME="cpu_stress_ctl.sh"
CFG_LOG_CTL="${STRESS_LOGDIR}/cpu_ctl.log"
CFG_LOG_SCHEDULE="${STRESS_LOGDIR}/cpu_schedule.out"
CFG_SCHEDULE_PID_FILE="${STRESS_PIDDIR}/cpu.schedule.pid"
CFG_TARGET_FILE="${STRESS_DATADIR}/cpu.target"
CFG_SOFT_FILE="${STRESS_DATADIR}/cpu.soft"
CFG_WORKER_OUT="${STRESS_DATADIR}/cpu_burn.out"

# usage 中 start 参数说明（命令集统一，参数含义各工具定制）
CFG_USAGE_START_ARG="N = worker 个数（正整数），可省略；省略=按时段自动算（营业/非营业目标%）"

# 供 safety_policy 写诊断文件（进 data）
SAFETY_STATE_DIR="${SAFETY_STATE_DIR:-${STRESS_DATADIR}}"

# =============================================================================
# [2] 公共库 COMMON
# =============================================================================
# shellcheck source=common.sh
. "${CFG_SCRIPT_DIR}/common.sh"

# =============================================================================
# [3] 策略库 SAFETY（CPU/MEM 需要；disk 不需要）
# =============================================================================
STRESS_NEED_SAFETY=1
# shellcheck source=safety_policy.sh
. "${CFG_SCRIPT_DIR}/safety_policy.sh"

# =============================================================================
# [4] 业务函数区 BIZ
# =============================================================================

# 将 worker 数限制在 [0, 硬顶]
_biz_clamp_workers() {
  local n="$1"
  local hard hard_pct np
  hard_pct="$(safety_eff_hard_pct)"
  np="$(safety_nproc)"
  hard="$(awk -v np="$np" -v p="$hard_pct" 'BEGIN{n=int(np*p/100.0); if(n<1)n=1; print n}')"
  echo "$n" | grep -Eq '^[0-9]+$' || n=0
  [ "$n" -lt 0 ] && n=0
  [ "$n" -gt "$hard" ] && n=$hard
  echo "$n"
}

# 清理 PID 文件中非法/非本工具进程；stdout=合法存活数
_biz_alive_from_pidfile() {
  local c=0 line tmp
  tmp="${STRESS_PID_FILE}.tmp.$$"
  : >"$tmp"
  if [ -f "${STRESS_PID_FILE}" ]; then
    while read -r line || [ -n "$line" ]; do
      line="$(echo "$line" | tr -d ' \t\r')"
      [ -z "$line" ] && continue
      echo "$line" | grep -Eq '^[0-9]+$' || continue
      if _common_is_our_worker "$line"; then
        echo "$line" >>"$tmp"
        c=$((c + 1))
      else
        if _common_is_alive "$line"; then
          _common_log "drop pid=$line from pidfile (not our worker)"
        fi
      fi
    done <"${STRESS_PID_FILE}"
  fi
  mv -f "$tmp" "${STRESS_PID_FILE}" 2>/dev/null || cat "$tmp" >"${STRESS_PID_FILE}"
  rm -f "$tmp" 2>/dev/null || true
  chmod 600 "${STRESS_PID_FILE}" 2>/dev/null || true
  echo "$c"
}

# 用 stdin 一行一个 pid 覆盖写入 pidfile（空行跳过）；原子写临时文件再 mv；权限 600
_biz_write_pidfile_from_list() {
  local tmp
  tmp="${STRESS_PID_FILE}.tmp.$$"
  : >"$tmp"
  while read -r line || [ -n "$line" ]; do
    line="$(echo "$line" | tr -d ' \t\r')"
    [ -z "$line" ] && continue
    echo "$line" >>"$tmp"
  done
  mv -f "$tmp" "${STRESS_PID_FILE}"
  rm -f "$tmp" 2>/dev/null || true
  chmod 600 "${STRESS_PID_FILE}" 2>/dev/null || true
}

# 只扫 pidfile：筛出仍存活且为本工具 worker 的 pid；stdout=每行一个 pid（不改写 pidfile）
_biz_collect_alive_pids() {
  if [ -f "${STRESS_PID_FILE}" ]; then
    while read -r line || [ -n "$line" ]; do
      line="$(echo "$line" | tr -d ' \t\r')"
      [ -z "$line" ] && continue
      _common_is_our_worker "$line" && echo "$line"
    done <"${STRESS_PID_FILE}"
  fi
}

# 合并「pidfile 存活」+「系统上真实本工具 worker」(safety_list_ours)，去重；stdout=每行一个 pid
_biz_collect_all_our_workers() {
  local tmp seen pid
  tmp="${STRESS_DATADIR}/.cpu_pids_merge.$$"
  : >"$tmp"
  _biz_collect_alive_pids >>"$tmp"
  safety_list_ours "${CFG_WORKER_PY}" >>"$tmp" 2>/dev/null || true
  seen="${STRESS_DATADIR}/.cpu_pids_seen.$$"
  : >"$seen"
  while read -r pid || [ -n "$pid" ]; do
    pid="$(echo "$pid" | tr -d ' \t\r')"
    [ -z "$pid" ] && continue
    echo "$pid" | grep -Eq '^[0-9]+$' || continue
    grep -qx "$pid" "$seen" 2>/dev/null && continue
    echo "$pid" >>"$seen"
    echo "$pid"
  done <"$tmp"
  rm -f "$tmp" "$seen" 2>/dev/null || true
}

# 本机实际本工具 worker 个数（pgrep，不依赖 pidfile）
_biz_real_worker_count() {
  local c
  c="$(safety_list_ours "${CFG_WORKER_PY}" 2>/dev/null | wc -l | tr -d ' ')"
  echo "${c:-0}"
}

# 拉起一个 cpu_burn；$1=soft 秒
_biz_spawn_one() {
  local soft="$1"
  local pid
  if [ -n "$soft" ] && [ "$soft" != "0" ]; then
    nohup "${CFG_PYTHON}" "${CFG_WORKER_PY}" "$soft" >>"${CFG_WORKER_OUT}" 2>&1 &
  else
    nohup "${CFG_PYTHON}" "${CFG_WORKER_PY}" >>"${CFG_WORKER_OUT}" 2>&1 &
  fi
  pid=$!
  sleep 1
  if _common_is_alive "$pid"; then
    echo "$pid"
  else
    echo ""
  fi
}

# 将存活 worker 调到 want；$1=个数 $2=soft
# 以系统真实进程为准合并孤儿，结束后杀掉未保留的本工具 cpu_burn
_biz_scale_to() {
  local want soft
  want="$(_biz_clamp_workers "$1")"
  soft="${2:-0}"
  local pids_file keep_file have need i pid
  pids_file="${STRESS_DATADIR}/.cpu_pids_live.$$"
  keep_file="${STRESS_DATADIR}/.cpu_pids_keep.$$"

  _biz_collect_all_our_workers >"$pids_file"
  have="$(wc -l <"$pids_file" | tr -d ' ')"
  [ -z "$have" ] && have=0

  if [ "$have" -gt "$want" ]; then
    local kill_n=$((have - want))
    tail -n "$kill_n" "$pids_file" | while read -r pid; do
      if _common_safe_kill_worker "$pid"; then
        _common_log "trim kill pid=$pid"
      fi
    done
    sleep 1
    head -n "$want" "$pids_file" >"$keep_file"
  elif [ "$have" -lt "$want" ]; then
    need=$((want - have))
    cp "$pids_file" "$keep_file"
    i=0
    while [ "$i" -lt "$need" ]; do
      pid="$(_biz_spawn_one "$soft")"
      if [ -n "$pid" ]; then
        echo "$pid" >>"$keep_file"
        _common_log "spawn pid=$pid soft=$soft"
      else
        _common_log "WARN: spawn failed"
      fi
      i=$((i + 1))
    done
  else
    cp "$pids_file" "$keep_file"
  fi

  # 只保留 keep 列表；杀掉竞态/孤儿多出来的本工具进程
  safety_kill_ours_except "${CFG_WORKER_PY}" "$keep_file"
  sleep 1
  # 再核对存活，写回 pidfile
  : >"$pids_file"
  while read -r pid || [ -n "$pid" ]; do
    pid="$(echo "$pid" | tr -d ' \t\r')"
    [ -z "$pid" ] && continue
    _common_is_our_worker "$pid" && echo "$pid" >>"$pids_file"
  done <"$keep_file"
  # 若 kill 误伤后不足 want，一般不在此二次狂补（防再竞态）；下轮 schedule 会补
  _biz_write_pidfile_from_list <"$pids_file"
  rm -f "$pids_file" "$keep_file" 2>/dev/null || true
  echo "$want" >"${CFG_TARGET_FILE}"
  echo "$soft" >"${CFG_SOFT_FILE}"
  _common_log "scale_to n=$want soft=$soft alive=$(_biz_alive_from_pidfile) real=$(_biz_real_worker_count) pidfile=${STRESS_PID_FILE}"
}

# 按策略启动；$1 可选强制 worker 数（必须是正整数）
_biz_start() {
  local profile mode n soft hard np final
  _common_ensure_env
  profile="$(safety_cpu_profile)"
  mode="$(echo "$profile" | cut -d'|' -f1)"
  n="$(echo "$profile" | cut -d'|' -f2)"
  soft="$(echo "$profile" | cut -d'|' -f3)"
  hard="$(echo "$profile" | cut -d'|' -f4)"
  np="$(echo "$profile" | cut -d'|' -f5)"

  if [ -n "${1:-}" ]; then
    if ! echo "$1" | grep -Eq '^[0-9]+$'; then
      _common_die "start 的可选参数 N 必须是正整数（worker 个数），例如: $0 start 2
你写的是: '$1'
若要看策略请用: $0 safety
若要看参数请用: $0 params"
    fi
    n="$(_biz_clamp_workers "$1")"
    mode="${mode}-forced"
  fi

  final="$(safety_cpu_apply_backoff "$n" "$(_biz_alive_from_pidfile)")"
  _common_log "start mode=$mode hour=$(date '+%H:%M') plan_n=$n final_n=$final soft=$soft hard=$hard nproc=$np"
  _common_log "safety: $(_safety_get_diag)"
  _biz_scale_to "$final" "$soft"
}

# 只停 worker，不停调度器
_biz_stop_workers_only() {
  local line
  if [ -f "${STRESS_PID_FILE}" ]; then
    while read -r line || [ -n "$line" ]; do
      line="$(echo "$line" | tr -d ' \t\r')"
      [ -z "$line" ] && continue
      _common_safe_kill_worker "$line" && _common_log "kill worker pid=$line" || true
    done <"${STRESS_PID_FILE}"
  fi
  : >"${STRESS_PID_FILE}"
  chmod 600 "${STRESS_PID_FILE}" 2>/dev/null || true
  safety_sweep_ours "${CFG_WORKER_PY}"
}

# 停 worker + 调度器
_biz_stop_all() {
  local wpid
  mkdir -p "${STRESS_PIDDIR}" 2>/dev/null || true
  _biz_stop_workers_only
  if [ -f "${CFG_SCHEDULE_PID_FILE}" ]; then
    wpid="$(cat "${CFG_SCHEDULE_PID_FILE}")"
    if _common_safe_kill_schedule "$wpid"; then
      _common_log "kill schedule pid=$wpid"
    else
      _common_log "skip schedule pid=$wpid (verify failed)"
    fi
    rm -f "${CFG_SCHEDULE_PID_FILE}"
  fi
  rm -f "${CFG_TARGET_FILE}" "${CFG_SOFT_FILE}"
  _common_log "stopped; pidfile=${STRESS_PID_FILE}"
}

# 前台调度循环
_biz_schedule_loop() {
  local profile mode n soft hard np final last_soft="" last_final="" alive diag
  _common_ensure_env
  _common_log "========== schedule START =========="
  _common_log "interval=${STRESS_SCHEDULE_INTERVAL}s pidfile=${STRESS_PID_FILE} datadir=${STRESS_DATADIR}"
  _common_log "biz_window=${BIZ_START_H}:00-${BIZ_END_H}:00 eff_hard=$(safety_eff_hard_pct)% min_idle=$(safety_eff_min_idle_pct)%"
  # 后台调度器：后续每拍心跳只写 ctl.log，不 echo 到 stdout，
  # schedule.out 保持干净（只留上面的启动留痕与异常）
  STRESS_LOG_QUIET=1
  while true; do
    profile="$(safety_cpu_profile)"
    mode="$(echo "$profile" | cut -d'|' -f1)"
    n="$(echo "$profile" | cut -d'|' -f2)"
    soft="$(echo "$profile" | cut -d'|' -f3)"
    hard="$(echo "$profile" | cut -d'|' -f4)"
    np="$(echo "$profile" | cut -d'|' -f5)"
    alive="$(_biz_alive_from_pidfile)"
    final="$(safety_cpu_apply_backoff "$n" "$alive")"
    diag="$(_safety_get_diag)"

    _common_rotate_file "${CFG_LOG_SCHEDULE}"
    _common_log "---- schedule tick ----"
    _common_log "time=$(date '+%F %T') mode=$mode nproc=$np plan_n=$n final_n=$final soft=$soft hard_n=$hard alive=$alive"
    _common_log "safety_diag: $diag"
    if [ -n "$last_final" ] && [ "$last_final" != "$final" ]; then
      _common_log "ACTION: worker target ${last_final} -> ${final}"
    fi
    if [ -n "$last_soft" ] && [ "$last_soft" != "$soft" ]; then
      _common_log "ACTION: soft $last_soft -> $soft, recycle workers"
      _biz_stop_workers_only
    fi
    _biz_scale_to "$final" "$soft"
    _common_log "after_scale alive=$(_biz_alive_from_pidfile)"
    last_soft="$soft"
    last_final="$final"
    sleep "${STRESS_SCHEDULE_INTERVAL}"
  done
}

# 后台调度：把调度器放到后台 nohup，本函数（前台）随即返回。
# 调度器 = `while true` 循环，每 STRESS_SCHEDULE_INTERVAL 秒跑一轮，
#          每一轮称作一「拍」：算目标 → 加减 worker → 写 pidfile。
# 本函数后半段会轮询等待「首拍」（调度器启动后的第 1 轮）执行完，
# 再读 pidfile 确认 worker 真实数量，避免「启动即查」拿到空/未更新而误报失败。
_biz_schedule_bg() {
  local wpid i real_n sched_ok=0
  local log_sz0=0 log_sz1=0 alive
  _common_ensure_env
  if [ -f "${CFG_SCHEDULE_PID_FILE}" ]; then
    wpid="$(cat "${CFG_SCHEDULE_PID_FILE}")"
    if _common_is_alive "$wpid"; then
      _common_log "schedule already running pid=$wpid"
      echo "已在跑 调度pid=${wpid}  查状态: $0 status"
      return 0
    fi
    rm -f "${CFG_SCHEDULE_PID_FILE}"
  fi
  if [ ! -f "${CFG_CTL_SCRIPT}" ]; then
    echo "找不到脚本: ${CFG_CTL_SCRIPT}"
    return 1
  fi
  if [ -f "${CFG_LOG_CTL}" ]; then
    log_sz0="$(wc -c <"${CFG_LOG_CTL}" | tr -d ' ')"
  fi
  # 禁止 nohup "$0"：相对路径/PATH/Text file busy 会导致后台秒退
  # 固定: bash + 绝对路径；stdout/err 进 schedule.out
  : >>"${CFG_LOG_SCHEDULE}" 2>/dev/null || true
  nohup /bin/bash "${CFG_CTL_SCRIPT}" schedule >>"${CFG_LOG_SCHEDULE}" 2>&1 &
  wpid=$!
  echo "$wpid" >"${CFG_SCHEDULE_PID_FILE}"
  chmod 600 "${CFG_SCHEDULE_PID_FILE}" 2>/dev/null || true
  _common_log "schedule-bg pid=${wpid} cmd=/bin/bash ${CFG_CTL_SCRIPT} schedule out=${CFG_LOG_SCHEDULE}"

  # 先确认没秒退（nohup/$0 失败时常见）
  sleep 1
  if ! _common_is_alive "$wpid"; then
    echo "调度启动失败（进程已退出） pid=${wpid}"
    echo "启动命令: /bin/bash ${CFG_CTL_SCRIPT} schedule"
    echo "---- ${CFG_LOG_SCHEDULE} (last 30) ----"
    if [ -f "${CFG_LOG_SCHEDULE}" ]; then
      tail -n 30 "${CFG_LOG_SCHEDULE}"
    else
      echo "(无日志文件)"
    fi
    rm -f "${CFG_SCHEDULE_PID_FILE}"
    return 1
  fi

  # 轮询最多约 8 秒等首拍；等待期间勿调 _biz_alive_from_pidfile（会改写 cpu.pid，与 scale 竞态）
  i=0
  while [ "$i" -lt 8 ]; do
    sleep 1
    if ! _common_is_alive "$wpid"; then
      echo "调度中途退出 pid=${wpid}"
      echo "---- ${CFG_LOG_SCHEDULE} (last 30) ----"
      tail -n 30 "${CFG_LOG_SCHEDULE}" 2>/dev/null || true
      return 1
    fi
    real_n="$(_biz_real_worker_count 2>/dev/null || echo 0)"
    if [ "${real_n:-0}" -gt 0 ] 2>/dev/null; then
      sched_ok=1
      break
    fi
    if [ -f "${CFG_LOG_CTL}" ]; then
      log_sz1="$(wc -c <"${CFG_LOG_CTL}" | tr -d ' ')"
      if [ "${log_sz1:-0}" -gt "${log_sz0:-0}" ] 2>/dev/null && \
         tail -c $((log_sz1 - log_sz0 + 1)) "${CFG_LOG_CTL}" 2>/dev/null | grep -q "after_scale"; then
        sched_ok=1
        break
      fi
    fi
    i=$((i + 1))
  done

  # 等待后台调度器首拍完成（上面的轮询已尽量等到 after_scale 出现）。
  # 这里再 sleep 1 并重读 pidfile：此刻首拍已把 scale 写回 pidfile，
  # 读到的 worker 数才是真实生效值，用于向用户反馈。
  sleep 1
  real_n="$(_biz_real_worker_count 2>/dev/null || echo 0)"
  alive="$(_biz_alive_from_pidfile 2>/dev/null || echo 0)"
  if [ "$sched_ok" = "1" ]; then
    echo "已启动 调度pid=${wpid}  worker=${real_n}  查状态: $0 status"
  else
    echo "已启动 调度pid=${wpid}  首拍未就绪  查状态: $0 status"
  fi
  # 勿再调 _biz_start：会与 schedule 首拍竞态各开 1 个 → 4 核约 50%
  return 0
}

# =============================================================================
# [5] 运维差异 OPS — status / params / safety（本工具定制输出）
# =============================================================================

# 脱敏版状态：SAFETY_REDACT=1 时调用。
# 只显示最简运行态（worker/调度器在不在 + 整机 busy%），
# 不暴露 PID、绝对路径、worker 数量、目标%等内部信息。
_ops_status_redacted() {
  local have sched_pid sched worker idle busy
  have="$(_biz_alive_from_pidfile 2>/dev/null || echo 0)"
  sched_pid=""
  if [ -f "${CFG_SCHEDULE_PID_FILE}" ]; then
    sched_pid="$(tr -d ' \t\r\n' <"${CFG_SCHEDULE_PID_FILE}" | head -c 32)"
  fi
  if [ -n "$sched_pid" ] && _common_is_alive "$sched_pid"; then sched="在跑"; else sched="未运行"; fi
  if [ "${have:-0}" -gt 0 ] 2>/dev/null; then worker="在跑（${have}个）"; else worker="未运行"; fi
  idle="$(safety_cpu_idle_pct 2>/dev/null || echo 50)"
  busy=$((100 - idle))
  cat <<EOF
---- CPU 状态 $(date '+%H:%M') ----
运行： worker ${worker}  |  调度器 ${sched}
整机： busy≈${busy}%  idle≈${idle}%
$(_ops_redact_note)
--------------------------------
EOF
}

# 完整状态：展示运行态、生效目标/带宽、闭环建议、硬顶、PID、告警。
# SAFETY_REDACT=1 时改走 _ops_status_redacted。
_ops_status() {
  local profile mode n soft hard np have
  local period_cn biz_n off_n
  local run_worker run_sched sched_pid pids_line
  local target band hard_pct idle busy lo hi suggest diag action
  local tip_line gran_line max_one_pct
  local cfg_target ach_pct metric_line
  local real_n warn_line
  _common_ensure_env
  if [ "${SAFETY_REDACT}" = "1" ]; then
    _ops_status_redacted
    return 0
  fi
  profile="$(safety_cpu_profile)"
  mode="$(echo "$profile" | cut -d'|' -f1)"
  n="$(echo "$profile" | cut -d'|' -f2)"
  soft="$(echo "$profile" | cut -d'|' -f3)"
  hard="$(echo "$profile" | cut -d'|' -f4)"
  np="$(echo "$profile" | cut -d'|' -f5)"
  have="$(_biz_alive_from_pidfile)"
  real_n="$(_biz_real_worker_count)"
  biz_n="$(safety_cpu_n_for_pct "$(safety_eff_biz_pct)")"
  off_n="$(safety_cpu_n_for_pct "$(safety_eff_off_pct)")"
  [ "$biz_n" -gt "$hard" ] 2>/dev/null && biz_n=$hard
  [ "$off_n" -gt "$hard" ] 2>/dev/null && off_n=$hard
  case "$mode" in
    biz|biz-small) period_cn="营业" ;;
    *)             period_cn="非营业" ;;
  esac

  if [ "${have:-0}" -gt 0 ] 2>/dev/null; then
    run_worker="在跑（pidfile=${have}个）"
  else
    run_worker="未运行"
  fi

  sched_pid=""
  if [ -f "${CFG_SCHEDULE_PID_FILE}" ]; then
    sched_pid="$(tr -d ' \t\r\n' <"${CFG_SCHEDULE_PID_FILE}" | head -c 32)"
  fi
  if [ -n "$sched_pid" ] && _common_is_alive "$sched_pid" && \
     { safety_is_our_pid "$sched_pid" "${CFG_CTL_SCRIPT}" || safety_is_our_pid "$sched_pid" "${CFG_CTL_BASENAME}"; }; then
    run_sched="在跑（pid=${sched_pid}）"
  elif [ -n "$sched_pid" ]; then
    run_sched="未运行（残留pid=${sched_pid}）"
  else
    run_sched="未运行"
  fi

  pids_line="(无)"
  if [ -f "${STRESS_PID_FILE}" ]; then
    pids_line="$(tr '\n' ' ' <"${STRESS_PID_FILE}" | sed 's/[[:space:]]*$//')"
    [ -z "$pids_line" ] && pids_line="(空)"
  fi

  # 采样整机 busy（含在 backoff 内约 1s）；仅展示建议，不改 worker 数
  cfg_target="$(safety_eff_cfg_target_pct)"
  target="$(safety_eff_target_pct)"
  ach_pct="$(safety_cpu_achievable_pct)"
  band="${CPU_TARGET_BAND_PCT}"
  echo "$band" | grep -Eq '^[0-9]+$' || band=1
  hard_pct="$(safety_eff_hard_pct)"
  lo=$((target - band))
  hi=$((target + band))
  [ "$lo" -lt 3 ] && lo=3
  [ "$hi" -gt "$hard_pct" ] && hi=$hard_pct
  suggest="$(safety_cpu_apply_backoff "$n" "$have")"
  diag="$(_safety_get_diag)"
  idle="$(echo "$diag" | sed -n 's/.*idle=\([0-9][0-9]*\)%.*/\1/p')"
  busy="$(echo "$diag" | sed -n 's/.*busy=\([0-9][0-9]*\)%.*/\1/p')"
  action="$(echo "$diag" | sed -n 's/.*action=\([^ ]*\).*/\1/p')"
  [ -z "$idle" ] && idle="?"
  [ -z "$busy" ] && busy="?"
  [ -z "$action" ] && action="(无)"
  [ -z "$suggest" ] && suggest="?"

  if [ "$cfg_target" -gt "$target" ] 2>/dev/null; then
    metric_line="配置${cfg_target}% → 生效${target}% ±${band}%（约${lo}~${hi}）  当前busy≈${busy}%  idle≈${idle}%  硬顶${hard_pct}%"
  else
    metric_line="目标${target}% ±${band}%（约${lo}~${hi}）  当前busy≈${busy}%  idle≈${idle}%  硬顶${hard_pct}%"
  fi

  tip_line="长期分时用 schedule-bg（只有一套 worker，不是两档相加）；只 start 则调度器未运行；停用 stop"
  gran_line=""
  warn_line=""
  if [ "${real_n:-0}" -gt "${hard:-0}" ] 2>/dev/null; then
    warn_line="警告：实际进程${real_n}个 > 硬顶${hard}个（疑似双启/孤儿，约可到 nproc 的 ${real_n}×${ach_pct:-?}%）；请 stop 后 schedule-bg"
  elif [ "${real_n:-0}" -ne "${have:-0}" ] 2>/dev/null; then
    warn_line="警告：pidfile=${have} 与实际进程=${real_n} 不一致；下轮 schedule 会收敛，或先 stop 再 schedule-bg"
  fi
  if [ "$cfg_target" -gt "$target" ] 2>/dev/null; then
    gran_line="提示： 硬顶可达成≤${ach_pct}%（nproc=${np} 最多${hard}个），已动态折算生效目标；精确配置%请到大核验收"
  elif [ "${np:-0}" -gt 0 ] 2>/dev/null && [ "${hard:-0}" -le 1 ] 2>/dev/null; then
    max_one_pct="$(awk -v np="$np" 'BEGIN{printf "%d", 100/np}')"
    gran_line="提示： nproc=${np} 硬顶仅${hard}个，满烧约${max_one_pct}%；精确%请到大核验收"
  fi

  cat <<EOF
---- CPU 状态 $(date '+%H:%M') ----
运行： worker ${run_worker}  |  实际进程(pgrep)=${real_n}个  |  调度器 ${run_sched}
时段： ${period_cn}  ${BIZ_START_H}-${BIZ_END_H}点  本档计划 ${n}个 soft=${soft}s
指标： ${metric_line}
闭环： action=${action}  建议worker=${suggest}  存活(pidfile)=${have}  soft=${soft}s
配置： 营业$(safety_eff_biz_pct)%≈${biz_n}个 | 非营业$(safety_eff_off_pct)%≈${off_n}个 | 硬顶最多${hard}个(nproc=${np})（对照，非同时开）
路径： ${STRESS_PID_FILE}
PID ： ${pids_line}
提示： ${tip_line}
EOF
  if [ -n "$warn_line" ]; then
    echo "${warn_line}"
  fi
  if [ -n "$gran_line" ]; then
    echo "${gran_line}"
  fi
  echo "--------------------------------"
}

_ops_params() {
  _common_ensure_env
  if [ "${SAFETY_REDACT}" = "1" ]; then
    cat <<EOF
============================================================
 可调参数一览（脱敏模式）
============================================================
 可用变量名（值已脱敏）：
   CPU: CPU_AIM_PCT  CPU_TARGET_PCT_BIZ/OFF  CPU_HARD_CAP_PCT
        CPU_TARGET_BAND_PCT  CPU_MIN_WORKERS  CPU_IDLE_HEADROOM_PCT
   MEM: MEM_TARGET_PCT_BIZ/OFF  MEM_HARD_CAP_PCT  MEM_ABORT_USED_PCT
   RUN: STRESS_SCHEDULE_INTERVAL  BIZ_START_H  BIZ_END_H
 改法: export 变量名=值  然后  $0 restart
 $(_ops_redact_note)
============================================================
EOF
    return 0
  fi
  cat <<EOF
============================================================
 可调参数一览 · CPU（当前值已展开）
 改法: export 变量名=值   然后  $0 restart
 详表: 同目录 docs/GUIDE.md
============================================================

【怎么用】
  export CPU_AIM_PCT=30
  $0 restart
  # 或只对一条命令生效:
  # CPU_AIM_PCT=30 $0 schedule-bg

【路径 / 运行（STRESS_*）】
  STRESS_PYTHON            = ${STRESS_PYTHON:-"(auto:${CFG_PYTHON})"}
  STRESS_PIDDIR            = ${STRESS_PIDDIR}          # 仅放 *.pid
  STRESS_DATADIR           = ${STRESS_DATADIR}         # 日志/target 等
  STRESS_LOGDIR            = ${STRESS_LOGDIR}
  STRESS_PID_FILE          = ${STRESS_PID_FILE}
  STRESS_SCHEDULE_INTERVAL = ${STRESS_SCHEDULE_INTERVAL}  # 调度周期秒（默认15，防掉0%）

【分时窗口】
  BIZ_START_H = ${BIZ_START_H}     # 营业开始小时（含）
  BIZ_END_H   = ${BIZ_END_H}       # 到点起算非营业；默认 8~19

【CPU 主旋钮（最常用）】
  CPU_AIM_PCT          = ${CPU_AIM_PCT}     # 一键瞄准%；非营业默认跟它走
  CPU_TARGET_PCT_BIZ   = ${CPU_TARGET_PCT_BIZ}  # 营业目标%（默认 AIM+4≈34，偏高）
  CPU_TARGET_PCT_OFF   = ${CPU_TARGET_PCT_OFF}  # 非营业目标%（默认 AIM-1≈29 → 约28%~30%）
  CPU_HARD_CAP_PCT     = ${CPU_HARD_CAP_PCT}    # 硬顶%=压测 worker 上限；绝对≤${SAFETY_ABS_CPU_HARD_MAX}%
  CPU_TARGET_BAND_PCT  = ${CPU_TARGET_BAND_PCT} # 闭环±%；默认1
  CPU_MIN_WORKERS      = ${CPU_MIN_WORKERS}     # worker 下限；0=不抬；仅偏低时才抬

【闭环 / 紧急再减】
  CPU_IDLE_HEADROOM_PCT = ${CPU_IDLE_HEADROOM_PCT}  # 紧急空闲下限≈100-硬顶-本值
  CPU_MIN_IDLE_PCT      = ${CPU_MIN_IDLE_PCT}       # >0 则直接用该空闲下限
  CPU_LOAD_RATIO_MAX    = ${CPU_LOAD_RATIO_MAX}     # load1/nproc 超此减 worker
  CPU_BACKOFF_STEP      = ${CPU_BACKOFF_STEP}       # 每次最少加减几个 worker

【soft（传给 cpu_burn 的 sleep 秒；过大到不了目标%）】
  BIZ_SOFT = ${BIZ_SOFT}     # 营业
  OFF_SOFT = ${OFF_SOFT}     # 非营业；0=全力烧

【小核机（真实 nproc < ${SMALL_NPROC_THRESHOLD}）】
  SMALL_BIZ_SOFT           = ${SMALL_BIZ_SOFT}
  SMALL_OFF_SOFT           = ${SMALL_OFF_SOFT}
  SMALL_CPU_HARD_CAP_PCT   = ${SMALL_CPU_HARD_CAP_PCT}    # 0=不单独降硬顶
  SMALL_CPU_TARGET_PCT_BIZ = ${SMALL_CPU_TARGET_PCT_BIZ}  # 0=不覆盖
  SMALL_CPU_TARGET_PCT_OFF = ${SMALL_CPU_TARGET_PCT_OFF}
  CPU_DISABLE_SMALL_DERATE = ${CPU_DISABLE_SMALL_DERATE}  # 1=不当小核

【调试 / 护栏（一般别动）】
  CPU_NPROC_OVERRIDE     = ${CPU_NPROC_OVERRIDE}      # 假核数；需 ALLOW_NPROC_OVERRIDE=1
  ALLOW_NPROC_OVERRIDE   = ${ALLOW_NPROC_OVERRIDE}
  SAFETY_ABS_CPU_AIM_MAX = ${SAFETY_ABS_CPU_AIM_MAX}  # AIM 绝对上限
  SAFETY_ABS_CPU_HARD_MAX= ${SAFETY_ABS_CPU_HARD_MAX} # 硬顶绝对上限（默认35，防抬高拖机）

【当前生效速算】
  nproc=$(safety_nproc)  营业≈$(safety_eff_biz_pct)%/$(safety_cpu_n_for_pct "$(safety_eff_biz_pct)")worker
  非营业≈$(safety_eff_off_pct)%/$(safety_cpu_n_for_pct "$(safety_eff_off_pct)")worker
  硬顶≈$(safety_eff_hard_pct)%  闭环±${CPU_TARGET_BAND_PCT}%  紧急空闲<$(safety_eff_min_idle_pct)%
  防拖机: 绝对硬顶≤${SAFETY_ABS_CPU_HARD_MAX}%；须 schedule-bg 持续减载（不会打满拖死）

【场景速查】
  整机基准             export CPU_AIM_PCT=30
  营业≈34% / 非营业28~30% （默认已是 BIZ=34 OFF=29 BAND=1）
  营业/非营业对调      export CPU_TARGET_PCT_BIZ=22 CPU_TARGET_PCT_OFF=30
  钉得更紧/更松        export CPU_TARGET_BAND_PCT=1   # 或 2
  128核抬底            export CPU_MIN_WORKERS=30
  临时试非营业档       export BIZ_END_H=13 ; $0 restart

【命令行可选参数（不是 export）】
  start [N] / restart [N]
      N = worker 个数（正整数），可省略
      省略     → 按营业/非营业目标%自动算
      指定 N   → 强制按 N 启，但仍受硬顶限制（最多 nproc×硬顶%）
      例: $0 start 2
  logs [N]
      N = 打印最近多少行日志，默认 40
      例: $0 logs 80
  日常推荐: $0 schedule-bg   （不用手填 N，调度器会按时段自动调）

另见: $0 help   $0 safety   $0 status
============================================================
EOF
}

# safety 命令输出（策略速览，来自 safety_policy.sh）
_ops_safety() {
  _common_ensure_env
  safety_dump
}

# =============================================================================
# [6] 主入口 MAIN（统一分发在 common.sh）
# =============================================================================
_main "$@"
