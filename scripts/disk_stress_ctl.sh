#!/usr/bin/env bash
# =============================================================================
# disk_stress_ctl.sh — 磁盘空间压测控制脚本
#
# 版本     : 1.0.0
# 许可证   : MIT
# 作者     : 压测工具维护组
# 依赖组件 : common.sh（必需）、disk_fill.py（必需）
#            （不需要 safety_policy.sh；磁盘压测无分时策略）
# 运行环境 : bash（3.2+）+ python2 / python3（自动探测）
# 功能     : 写大文件占磁盘空间（part 2~5GB / 模拟日志或二进制内容）
#
# 分区说明:
#   [1] 配置区 CONFIG  — 环境变量与路径，可 export 覆盖
#   [2] 公共库 COMMON  — source common.sh（logo/日志/PID 安全/运维框架）
#   [3] 策略区 SAFETY  — 本工具无独立策略库；磁盘策略（保留/限速/分片/裁剪）
#                        内建在负载脚本 disk_fill.py 里（防护能力等同 CPU/MEM）
#   [4] 业务函数区 BIZ — 本工具业务实现（启停；磁盘一次性写入，无需分时调度）
#   [5] 运维差异 OPS   — status / params / safety（本工具定制输出）
#   [6] 主入口 MAIN    — _main "$@"（统一分发在 common.sh）
#
# 说明: 磁盘占用写的是磁盘空间 + 可回收 page cache，
#       不计入本项目内存 used% 口径（内存占用请用 mem_stress_ctl.sh）。
# =============================================================================

set -u

STRESS_TOOL_NAME="磁盘压测工具"
TOOL_VERSION="1.0.0"

# =============================================================================
# [1] 配置区 CONFIG
# =============================================================================

# --- 角色标识（本脚本固定为 disk）---
STRESS_ROLE="disk"

# --- 路径与解释器（仅 STRESS_*）---
CFG_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# PID 目录（默认：脚本目录）— 仅放 *.pid
: "${STRESS_PIDDIR:=${CFG_SCRIPT_DIR}}"

# 数据目录（默认：脚本目录/data）— 日志、target 等
: "${STRESS_DATADIR:=${CFG_SCRIPT_DIR}/data}"

# 日志目录（默认：同 DATADIR；可单独覆盖）
: "${STRESS_LOGDIR:=${STRESS_DATADIR}}"

# Python 环境（python2/python3；空则启动时自动探测）
: "${STRESS_PYTHON:=}"

# PID 文件（默认：${STRESS_PIDDIR}/disk.pid）
: "${STRESS_PID_FILE:=${STRESS_PIDDIR}/disk.pid}"

# part 文件输出目录（默认：${STRESS_DATADIR}/parts，与日志/pid 隔离）
# 可 export DISK_DIR=/data/disk_test 指到专门的大分区/挂载点
: "${DISK_DIR:=${STRESS_DATADIR}/parts}"

# 工作负载脚本 / 运行态文件
CFG_WORKER_PY="${CFG_SCRIPT_DIR}/disk_fill.py"
CFG_CTL_SCRIPT="${CFG_SCRIPT_DIR}/disk_stress_ctl.sh"
CFG_CTL_BASENAME="disk_stress_ctl.sh"
CFG_LOG_CTL="${STRESS_LOGDIR}/disk_ctl.log"
CFG_LOG_SCHEDULE="${STRESS_LOGDIR}/disk_schedule.out"
CFG_SCHEDULE_PID_FILE="${STRESS_PIDDIR}/disk.schedule.pid"
CFG_TARGET_FILE="${STRESS_DATADIR}/disk.target_mb"
CFG_WORKER_OUT="${STRESS_DATADIR}/disk_fill.out"

# 保护目录白名单（逗号分隔的绝对路径）：DISK_DIR 命中则 stop/trim 拒绝删除，防误删业务目录
# 例: export DISK_PROTECT_DIRS="/,/data,/home,/opt,/var"
: "${DISK_PROTECT_DIRS:=}"

# 判定 DISK_DIR 是否命中保护目录（精确或子路径前缀匹配），命中返回 0
_disk_in_protect_dir() {
  local dir="$1" p
  [ -n "$dir" ] || return 1
  [ -n "${DISK_PROTECT_DIRS}" ] || return 1
  dir="$(cd "$dir" 2>/dev/null && pwd || echo "$dir")"
  for p in $(echo "${DISK_PROTECT_DIRS}" | tr ',' ' '); do
    [ -n "$p" ] || continue
    p="$(echo "$p" | sed 's|[/[:space:]]*$||')"
    [ -n "$p" ] || p="/"
    case "$dir" in
      "$p"|"$p"/*) return 0 ;;
    esac
  done
  return 1
}

# usage 中 start 参数说明（命令集统一，参数含义各工具定制）
CFG_USAGE_START_ARG="MB = 兆字节（正整数），可省略；省略=填到「可用−保留空间」"

# =============================================================================
# [2] 公共库 COMMON
# =============================================================================
# shellcheck source=common.sh
. "${CFG_SCRIPT_DIR}/common.sh"

# =============================================================================
# [4] 业务函数区 BIZ
# =============================================================================

# 启动 disk_fill 写文件占磁盘；$1 可选目标 MB（0=自动填到保留线）
_biz_start() {
  local mb="${1:-}"
  local pid allow_mb
  _common_ensure_env

  # 已启动则拒绝
  if [ -f "${STRESS_PID_FILE}" ]; then
    pid="$(head -n1 "${STRESS_PID_FILE}" | tr -d ' \t\r')"
    if _common_is_our_worker "$pid"; then
      _common_log "已在运行 pid=$pid；如需重启请先 stop"
      echo "已在运行 pid=${pid}；如需重启请先 stop"
      return 0
    fi
    rm -f "${STRESS_PID_FILE}"
  fi

  # 参数校验
  if [ -n "$mb" ] && ! echo "$mb" | grep -Eq '^[0-9]+$'; then
    _common_die "start 参数必须是正整数 MB，例如: $0 start 10240"
  fi

  # 自动创建 part 输出目录（默认 data/parts）
  mkdir -p "${DISK_DIR:-${STRESS_DATADIR}/parts}" 2>/dev/null \
    || _common_die "无法创建 part 输出目录 ${DISK_DIR:-${STRESS_DATADIR}/parts}"

  _common_log "start mb=${mb:-auto} dir=${DISK_DIR:-${STRESS_DATADIR}/parts} target_pct=${DISK_TARGET_PCT:-50} part=${DISK_PART_MB:-0}(0=auto) content=${DISK_CONTENT:-text}"
  nohup "${CFG_PYTHON}" "${CFG_WORKER_PY}" "${mb:-0}" >>"${CFG_WORKER_OUT}" 2>&1 &
  pid=$!
  echo "$pid" >"${STRESS_PID_FILE}"
  chmod 600 "${STRESS_PID_FILE}" 2>/dev/null || true
  sleep 1
  if _common_is_alive "$pid"; then
    echo "$mb" >"${CFG_TARGET_FILE}" 2>/dev/null || true
    _common_log "started pid=$pid mb=${mb:-auto}"
    echo "已启动 pid=${pid}  查看进度: tail -f ${CFG_WORKER_OUT}  停止: $0 stop"
  else
    rm -f "${STRESS_PID_FILE}"
    _common_die "disk_fill 启动失败，见 ${CFG_WORKER_OUT}"
  fi
}

# 停 worker + 删除 part 文件（DISK_KEEP_FILES=1 可保留）
_biz_stop_all() {
  local pid part_count
  local keep="${DISK_KEEP_FILES:-0}"
  if [ -f "${STRESS_PID_FILE}" ]; then
    pid="$(head -n1 "${STRESS_PID_FILE}" | tr -d ' \t\r')"
    if [ -n "$pid" ] && _common_is_our_worker "$pid"; then
      kill -TERM "$pid" 2>/dev/null
      _common_log "kill worker pid=$pid"
    fi
    rm -f "${STRESS_PID_FILE}"
  fi
  # 兜底：按 cmdline 清理（仅本工具）
  safety_sweep_ours "${CFG_WORKER_PY}"
  if [ "$keep" = "1" ]; then
    _common_log "DISK_KEEP_FILES=1，保留 part 文件（仍占磁盘）"
    echo "已停止，part 文件保留（DISK_KEEP_FILES=1）。如需释放: rm -f ${DISK_DIR:-.}/${DISK_PREFIX:-disk_fill}.part*"
    return 0
  fi
  # ── 删除保护：DISK_DIR 命中保护目录白名单则拒绝删除（防误删业务目录）──
  if _disk_in_protect_dir "${DISK_DIR:-.}"; then
    _common_log "stop REFUSE remove: DISK_DIR=${DISK_DIR:-.} 命中 DISK_PROTECT_DIRS 保护目录"
    echo "已停止，但【拒绝删除 part 文件】：DISK_DIR 命中保护目录 ${DISK_PROTECT_DIRS}"
    echo "如需强制删除: 确认无误后 export DISK_PROTECT_DIRS= 再执行 stop，或手动清理 ${DISK_DIR:-.}/${DISK_PREFIX:-disk_fill}.part*"
    return 0
  fi
  # 仅删除「DISK_PREFIX.part*」前缀匹配且位于 DISK_DIR 下的文件（不扫子目录、不删其它前缀）
  part_count="$(ls -1 "${DISK_DIR:-.}"/${DISK_PREFIX:-disk_fill}.part* 2>/dev/null | wc -l | tr -d ' ')"
  rm -f "${DISK_DIR:-.}"/${DISK_PREFIX:-disk_fill}.part* 2>/dev/null
  _common_log "stop done; removed ${part_count} part files (prefix=${DISK_PREFIX:-disk_fill}, dir=${DISK_DIR:-.})"
  echo "已停止，并删除 ${part_count} 个 part 文件（仅 ${DISK_PREFIX:-disk_fill}.part* 前缀），磁盘空间已释放"
}

# 磁盘占用为一次性写入，无需分时调度（没有营业/非营业之分）。
# 仅为对齐 cpu/mem 的统一命令接口而存在，调用时给出提示而非真正循环。
# （真正占用由 _biz_start 拉起 disk_fill 后驻留，直到 stop 为止。）
_biz_schedule_loop() {
  _common_log "磁盘占用无需分时调度（写入后保持到 stop）"
  echo "磁盘占用为一次性写入，无需分时调度。"
  echo "请用: $0 start [MB]   查看: $0 status   停止: $0 stop"
}

# 磁盘的后台「调度」即等价于前台提示：磁盘一次性写入，无需后台循环。
# 这里直接转发到 _biz_schedule_loop，由它提示用户改用 start/stop。
_biz_schedule_bg() {
  _biz_schedule_loop
}

# =============================================================================
# [5] 运维差异 OPS — status / params / safety（本工具定制输出）
# =============================================================================

# 脱敏版状态：SAFETY_REDACT=1 时调用。
# 只显示最简运行态（worker 在不在 + 目标目录磁盘概况），
# 不暴露 PID、绝对路径、part 数量等内部信息。
_ops_status_redacted() {
  local pid run total used
  pid=""
  if [ -f "${STRESS_PID_FILE}" ]; then
    pid="$(head -n1 "${STRESS_PID_FILE}" | tr -d ' \t\r')"
  fi
  if [ -n "$pid" ] && _common_is_our_worker "$pid"; then
    run="在跑"
  else
    run="未运行"
  fi
  total="$(df -k "${DISK_DIR:-.}" 2>/dev/null | awk 'NR==2{printf "%.1f", $2/1024/1024}')"
  used="$(df -k "${DISK_DIR:-.}" 2>/dev/null | awk 'NR==2{printf "%.1f", ($2-$4)/1024/1024}')"
  cat <<EOF
---- 磁盘状态 $(date '+%H:%M') ----
运行： ${run}
磁盘： 目标目录 ${DISK_DIR:-.}  总量≈${total:-?}G  已用≈${used:-?}G
$(_ops_redact_note)
--------------------------------
EOF
}

# 完整状态：展示运行态、目标目录磁盘概况、已生成 part 数量。
# SAFETY_REDACT=1 时改走 _ops_status_redacted。
_ops_status() {
  local pid run total used
  _common_ensure_env
  if [ "${SAFETY_REDACT}" = "1" ]; then
    _ops_status_redacted
    return 0
  fi
  pid=""
  if [ -f "${STRESS_PID_FILE}" ]; then
    pid="$(head -n1 "${STRESS_PID_FILE}" | tr -d ' \t\r')"
  fi
  if [ -n "$pid" ] && _common_is_our_worker "$pid"; then
    run="在跑（pid=${pid}）"
  elif [ -n "$pid" ]; then
    run="未运行（残留pid=${pid}）"
  else
    run="未运行"
  fi
  total="$(df -k "${DISK_DIR:-${STRESS_DATADIR}/parts}" 2>/dev/null | awk 'NR==2{printf "%.1f", $2/1024/1024}')"
  used="$(df -k "${DISK_DIR:-${STRESS_DATADIR}/parts}" 2>/dev/null | awk 'NR==2{printf "%.1f", ($2-$4)/1024/1024}')"
  part_count="$(ls -1 "${DISK_DIR:-${STRESS_DATADIR}/parts}"/${DISK_PREFIX:-disk_fill}.part* 2>/dev/null | wc -l | tr -d ' ')"
  cat <<EOF
---- 磁盘状态 $(date '+%H:%M') ----
运行： ${run}
磁盘： 目标目录 ${DISK_DIR:-${STRESS_DATADIR}/parts}  总量≈${total:-?}G  已用≈${used:-?}G
文件： 已生成 ${part_count} 个 part（前缀 ${DISK_PREFIX:-disk_fill}.part*，目标目录 ${DISK_DIR:-${STRESS_DATADIR}/parts}）
提示： 占用的是磁盘空间 + page cache，不计入内存 used% 口径（内存请用 mem_stress_ctl.sh）
--------------------------------
EOF
}

_ops_params() {
  _common_ensure_env
  if [ "${SAFETY_REDACT}" = "1" ]; then
    cat <<EOF
============================================================
 可调参数一览（脱敏模式）
============================================================
 可用变量名（值已脱敏）：
   DISK: DISK_PART_MB  DISK_PART_MAX_MB  DISK_CONTENT  DISK_RESERVE_PCT  DISK_RESERVE_MB
         DISK_RESERVE_ABS_MB  DISK_WRITE_MBPS  DISK_FSYNC  DISK_DIR  DISK_PREFIX
   RUN: DISK_KEEP_FILES
 改法: export 变量名=值  然后  $0 restart
 $(_ops_redact_note)
============================================================
EOF
    return 0
  fi
  cat <<EOF
============================================================
 可调参数一览 · 磁盘（当前值已展开）
 改法: export 变量名=值   然后  $0 restart
============================================================

【怎么用】
  export DISK_PART_MB=2560
  $0 restart 10240

【路径 / 运行（STRESS_*）】
  STRESS_PYTHON = ${STRESS_PYTHON:-"(auto:${CFG_PYTHON})"}
  STRESS_PIDDIR = ${STRESS_PIDDIR}
  STRESS_DATADIR= ${STRESS_DATADIR}
  STRESS_PID_FILE = ${STRESS_PID_FILE}

【磁盘主旋钮（传给 disk_fill.py）】
  DISK_DIR         = ${DISK_DIR:-.}           # part 文件输出目录
  DISK_PART_MB     = ${DISK_PART_MB:-0}       # 单个 part 大小 MB；0=按目标自适应（默认）
  DISK_PART_MAX_MB = ${DISK_PART_MAX_MB:-5120} # 自适应分片上限 MB（默认 5GB）
  DISK_CONTENT     = ${DISK_CONTENT:-text}    # text=模拟日志；binary=二进制随机
  DISK_RESERVE_PCT = ${DISK_RESERVE_PCT:-10}    # 保留磁盘空闲比例 %（防填满）
  DISK_RESERVE_MB  = ${DISK_RESERVE_MB:-5120}   # 绝对保留 MB
  DISK_RESERVE_ABS_MB = ${DISK_RESERVE_ABS_MB:-1024}  # 绝对保留底线 MB（即使前两者调 0 也强制保留，防写爆存储）
  # 三重保留取较大: 比例 / 指定 MB / 绝对底线；目标永远到不了「可用−保留」
  # 自适应分段: ≤2GB→256MB | ≤10GB→1GB | ≤50GB→2.5GB | ≤200GB→5GB | 更大→5GB(封顶)

【写入行为】
  DISK_WRITE_MBPS  = ${DISK_WRITE_MBPS:-512}  # 基础写速上限 MB/s（默认512限速防疯狂写）；0=不限速
  DISK_WRITE_MBPS_BIZ = ${DISK_WRITE_MBPS_BIZ:-0}  # 营业写速 MB/s（0=用基础值）
  DISK_WRITE_MBPS_OFF = ${DISK_WRITE_MBPS_OFF:-0}  # 非营业写速 MB/s（0=用基础值）
  DISK_FSYNC       = ${DISK_FSYNC:-0}         # 1=每 part fsync（慢但更落盘）
  DISK_PREFIX      = ${DISK_PREFIX:-disk_fill} # 文件名前缀，生成 .part001…

【动态闭环监管（v1.1，默认开启）】
  DISK_DYNAMIC       = ${DISK_DYNAMIC:-1}      # 1=动态监管（默认）；0=一次性写入（旧行为）
  DISK_TARGET_PCT    = ${DISK_TARGET_PCT:-50}  # 目标磁盘占用率 %（核心目标；到点停写）
  DISK_TARGET_PCT_BIZ= ${DISK_TARGET_PCT_BIZ:-0} # 营业目标占用率 %（0=用 DISK_TARGET_PCT）
  DISK_TARGET_PCT_OFF= ${DISK_TARGET_PCT_OFF:-0} # 非营业目标占用率 %（0=用 DISK_TARGET_PCT）
  DISK_TARGET_SLACK_PCT = ${DISK_TARGET_SLACK_PCT:-2}  # 降速预留 %：目标−预留 起提前降速（避免冲过头；达到目标才停）
  DISK_SLOW_RATIO    = ${DISK_SLOW_RATIO:-0.85}  # 占用达目标的该比例开始线性降速
  DISK_TRIM_OVER     = ${DISK_TRIM_OVER:-1}     # 1=占用超目标删已写 part 回落；0=只停不删
  DISK_WATCH_INTERVAL= ${DISK_WATCH_INTERVAL:-5} # 监管/监控间隔秒
  DISK_CPU_MAX_BUSY  = ${DISK_CPU_MAX_BUSY:-80} # CPU busy%≥此值暂停写入
  DISK_CPU_SLOW_BUSY = ${DISK_CPU_SLOW_BUSY:-60} # CPU busy%≥此值写速减半
  DISK_MIN_MBPS      = ${DISK_MIN_MBPS:-50}     # 降速最低写速 MB/s
  # 行为：每拍看 used% → 逼近目标降速 → 达到目标停写驻留
  #      业务把 used% 冲超目标 → 自动删 part 回落；CPU 高 → 减半/暂停，降下恢复

【删除/写入保护】
  DISK_PROTECT_DIRS  = ${DISK_PROTECT_DIRS:-"(空)"}  # 保护目录白名单（逗号分隔绝对路径）
  # DISK_DIR 命中保护目录 → start 拒绝写入、stop/trim 拒绝删除，防误删业务目录
  # 例: export DISK_PROTECT_DIRS="/,/data,/home,/opt,/var"
  # 删除只匹配 ${DISK_PREFIX:-disk_fill}.part* 前缀，且仅限 DISK_DIR 目录下（不扫子目录）

【命令行可选参数（不是 export）】
  start [MB] / restart [MB]
      MB = 目标兆字节（正整数），可省略
      省略 → 只按 DISK_TARGET_PCT 占用率目标写；指定 → 双约束（MB 与占用率取先到者）
      例: $0 start 10240
  stop（删除 part 文件释放空间；export DISK_KEEP_FILES=1 可保留）

另见: $0 help   $0 safety   $0 status
============================================================
EOF
}

# safety 命令输出（本工具无策略库，显示 DISK 参数与目标目录磁盘概况）
_ops_safety() {
  local total avail pct
  _common_ensure_env
  total="$(df -k "${DISK_DIR:-.}" 2>/dev/null | awk 'NR==2{print $2}')"
  avail="$(df -k "${DISK_DIR:-.}" 2>/dev/null | awk 'NR==2{print $4}')"
  pct="$(awk -v a="${avail:-0}" -v t="${total:-1}" 'BEGIN{if(t+0<=0){print 0;exit} printf "%.0f", a/t*100}')"
  cat <<EOF
============================================================
 磁盘策略速览
============================================================
 目标目录 : ${DISK_DIR:-.}
 磁盘总量 : ${total:-?}kB   剩余 ${avail:-?}kB（约${pct}%）
 part 大小: ${DISK_PART_MB:-0}(0=自适应) 上限 ${DISK_PART_MAX_MB:-5120}MB  内容: ${DISK_CONTENT:-text}
 保留空间 : 至少 ${DISK_RESERVE_PCT:-10}% / ${DISK_RESERVE_MB:-5120}MB / 绝对底线${DISK_RESERVE_ABS_MB:-1024}MB（取较大）
 写速限速 : ${DISK_WRITE_MBPS:-512}MB/s（默认限速防疯狂写；0=不限速）
 动态监管 : 目标占用率 ${DISK_TARGET_PCT:-50}%（不足继续写、达到即停）
            降速起点=${DISK_TARGET_PCT:-50}−预留${DISK_TARGET_SLACK_PCT:-2}%（提前收油门防冲过头）
            营业=${DISK_TARGET_PCT_BIZ:-同目标}% 非营业=${DISK_TARGET_PCT_OFF:-同目标}%
            逼近降速(slow_from=${DISK_SLOW_RATIO:-0.85}×目标) 超目标回落(trim=${DISK_TRIM_OVER:-1})
            CPU联动(pause≥${DISK_CPU_MAX_BUSY:-80}% slow≥${DISK_CPU_SLOW_BUSY:-60}%)
 默认 start: 写到位目标占用率${DISK_TARGET_PCT:-50}%（不足就写、到即停）；也可 start <MB> 指定（双约束取先到者）
 注意     : 磁盘占用不计入内存 used% 口径（内存请用 mem_stress_ctl.sh）
============================================================
EOF
}

# =============================================================================
# [6] 主入口 MAIN（统一分发在 common.sh）
# =============================================================================
_main "$@"
