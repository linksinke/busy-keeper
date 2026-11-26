#!/usr/bin/env bash
# =============================================================================
# safety_policy.sh — 资源压测「安全策略」共享库
#
# 版本     : 1.0.0
# 许可证   : MIT
# 作者     : 压测工具维护组
# 功能     : 被 cpu_stress_ctl.sh / mem_stress_ctl.sh source 的「业务策略库」
#            （分时 / CPU 闭环 / 内存上限 / 策略速览）；公共能力见 common.sh
# 配置文档 : 同目录 README.md ；现场也可 ./cpu_stress_ctl.sh safety
# 注意     : 本文件非独立可执行，须由 ctl 脚本 source（勿直接运行）。
# =============================================================================
#
# 分区说明:
#   [1] 配置区 CONFIG     — 可 export 覆盖的默认值（分时/CPU/内存/护栏）
#   [2] 初始化 INIT       — clamp + 绝对上限生效
#   [3] 内部诊断 INTERNAL — diag 落盘（避免子 shell 丢变量）
#   [4] CPU 策略 BIZ      — nproc / 分时 / worker / 降载
#   [5] 内存策略 BIZ      — used% 目标与申请量
#   [6] 运维输出 OPS      — safety_dump 速览
# 公共能力（日志 / PID 安全校验 / 脱敏 / 日志轮转 / 运维框架）见 common.sh
#
# =============================================================================

# =============================================================================
# [1] 配置区 CONFIG
# =============================================================================

# -----------------------------------------------------------------------------
# [1.1] 分时窗口 — 营业 / 非营业（半开区间 [START, END)）
# 名义营业约 09:00–18:00；默认外扩 08:00–19:00，覆盖提前开业/收尾。
# -----------------------------------------------------------------------------
: "${BIZ_START_H:=8}"
: "${BIZ_END_H:=19}"

# -----------------------------------------------------------------------------
# [1.2] CPU — AIM 一键目标 → 推导营业/非营业/硬顶
# 默认：营业偏高、非营业略低（可 export 对调两档，实现「交互」）
#   营业   ≈ AIM+4（默认34%；配合 BAND=1 → 约 33%~35%，钉在偏高）
#   非营业 ≈ AIM-1（默认29%；配合 BAND=1 → 约 28%~30%）
#   硬顶   ≈ AIM+5（默认35%，盖住营业上沿）
# -----------------------------------------------------------------------------
: "${CPU_AIM_PCT:=30}"
_biz_def=$((CPU_AIM_PCT + 4))
[ "$_biz_def" -gt 34 ] && _biz_def=34
[ "$_biz_def" -lt 1 ] && _biz_def=1
_off_def=$((CPU_AIM_PCT - 1))
[ "$_off_def" -lt 12 ] && _off_def=12
_hard_def=$((CPU_AIM_PCT + 5))
[ "$_hard_def" -gt 35 ] && _hard_def=35
[ "$_hard_def" -lt "$_biz_def" ] && _hard_def=$_biz_def
: "${CPU_TARGET_PCT_BIZ:=$_biz_def}"    # 营业目标 %（默认34，偏高）
: "${CPU_TARGET_PCT_OFF:=$_off_def}"    # 非营业目标 %（默认29 → 闭环约28%~30%）
: "${CPU_HARD_CAP_PCT:=$_hard_def}"      # 硬顶 %（须 ≥ 较高那一档目标）
unset _biz_def _off_def _hard_def

# -----------------------------------------------------------------------------
# [1.3] CPU — 闭环钉目标 / 紧急再减 / worker 下限
# 整机 busy%≈100−idle；落在 [目标−BAND, 目标+BAND] 内则保持
# 默认 BAND=1：营业34%→约33%~35%；非营业29%→约28%~30%
# -----------------------------------------------------------------------------
: "${CPU_TARGET_BAND_PCT:=1}"     # 目标带宽 ±%
: "${CPU_IDLE_HEADROOM_PCT:=20}"  # 紧急：空闲 < 100−硬顶−本值 时强制再减
: "${CPU_MIN_IDLE_PCT:=0}"        # >0 则覆盖紧急空闲下限公式
: "${CPU_LOAD_RATIO_MAX:=0.90}"   # load1/nproc 超此则减 worker
: "${CPU_BACKOFF_STEP:=2}"        # 每次加减的最少 worker 数
: "${CPU_MIN_WORKERS:=0}"         # worker 下限；0=不抬。海光128核可设30
: "${CPU_NPROC_OVERRIDE:=0}"      # 调试假核数；0=真实 nproc（默认禁用，见 [1.6]）

# -----------------------------------------------------------------------------
# [1.4] CPU — soft（传给 cpu_burn.py 的每轮 sleep 秒）
# -----------------------------------------------------------------------------
: "${BIZ_SOFT:=0}"                 # 营业（偏高档）默认全力烧
: "${OFF_SOFT:=0.001}"             # 非营业略留 soft；过大到不了目标

# -----------------------------------------------------------------------------
# [1.5] 小核机（真实 nproc < SMALL_NPROC_THRESHOLD）
# 默认：目标%与大机相同，仅 soft 略大；SMALL_CPU_*=0 表示不单独覆盖百分比
# -----------------------------------------------------------------------------
: "${SMALL_NPROC_THRESHOLD:=16}"
: "${SMALL_BIZ_SOFT:=0}"              # 与大机营业一致：全力烧，避免 4 核掉到 ~10%
: "${SMALL_OFF_SOFT:=0.001}"          # 与 OFF_SOFT 对齐
: "${SMALL_CPU_HARD_CAP_PCT:=0}"
: "${SMALL_CPU_TARGET_PCT_BIZ:=0}"
: "${SMALL_CPU_TARGET_PCT_OFF:=0}"
: "${CPU_DISABLE_SMALL_DERATE:=0}" # 1=强制不当小核处理

# -----------------------------------------------------------------------------
# [1.6] 绝对护栏 — 业务 export 也不能突破（可 SAFETY_ABS_* 调低）
# -----------------------------------------------------------------------------
: "${SAFETY_ABS_CPU_HARD_MAX:=35}" # CPU 硬顶绝对值上限 %（与默认硬顶对齐，防 export 抬高拖机）
: "${SAFETY_ABS_CPU_AIM_MAX:=35}"  # AIM 上限 %
: "${SAFETY_ABS_MEM_HARD_MAX:=62}" # 内存硬顶上限 %（≥硬顶+中止线，留缓冲）
: "${SAFETY_ABS_MEM_TARGET_MAX:=58}" # 内存目标上限 %
: "${ALLOW_NPROC_OVERRIDE:=0}"     # 1 才允许 CPU_NPROC_OVERRIDE

# -----------------------------------------------------------------------------
# [1.7] 内存 — used% ≈ (MemTotal − MemAvailable) / MemTotal
# -----------------------------------------------------------------------------
: "${MEM_TARGET_PCT_BIZ:=50}"     # 营业内存目标 %（默认 50）
: "${MEM_TARGET_PCT_OFF:=50}"     # 非营业内存目标 %（默认 50）
: "${MEM_HARD_CAP_PCT:=60}"       # 硬顶 %（默认 60，营业可到 55、硬顶兜底 60）
: "${MEM_ABORT_USED_PCT:=62}"     # used%≥此值：暂停占用（释放 hold），回落自动恢复
: "${MEM_TARGET_BAND_PCT:=5}"     # 带内闭环带宽 %（对称 fallback）：used 在 [目标±带宽] 内保持
: "${MEM_BAND_LO_PCT:=49}"        # 带内闭环下沿 %（全局 fallback）：used 低于此 → 补占 hold
: "${MEM_BAND_HI_PCT:=55}"        # 带内闭环上沿 %（全局 fallback）：used 高于此 → 释放 hold 回落
: "${MEM_BAND_LO_PCT_BIZ:=50}"    # 营业档下沿 %（默认 50）：营业带 = 50~55
: "${MEM_BAND_HI_PCT_BIZ:=55}"    # 营业档上沿 %（默认 55）
: "${MEM_BAND_LO_PCT_OFF:=49}"    # 非营业档下沿 %（默认 49）：非营业带 = 49~51
: "${MEM_BAND_HI_PCT_OFF:=51}"    # 非营业档上沿 %（默认 51，波动更小）
: "${MEM_RESERVE_PCT:=25}"         # Available 至少占总内存的比例
: "${MEM_RESERVE_MIN_MB:=4096}"    # Available 绝对底线 MB（小机会自动下调）
: "${MEM_TAKE_OF_FREE_PCT:=60}"    # 单次最多吃掉当前闲置的比例
: "${MEM_CHUNK_MB:=0}"             # hold 分片 MB；0=按目标自适应（见 mem_hold.py）
: "${MEM_CHUNK_MAX_MB:=1024}"      # 自适应分片上限 MB（防单块过大）
: "${MEM_ALLOC_MBPS:=512}"           # 申请速率上限 MB/s；默认 512=限速防瞬间冲高；0=不限速

# -----------------------------------------------------------------------------
# [1.8] 运行态（一般不必 export；ctl 会设 SAFETY_STATE_DIR→data/）
# -----------------------------------------------------------------------------
: "${SAFETY_LAST_DIAG:=}"
: "${SAFETY_MEM_NEED_MB:=0}"
: "${SAFETY_STATE_DIR:=${SCRIPT_DIR:-.}}"

# [1.9] 输出脱敏 / 日志轮转（一般不必 export）
# -----------------------------------------------------------------------------
: "${SAFETY_REDACT:=0}"        # 1=脱敏模式：help/params/safety/status/logs 不显示路径/PID/精确参数
: "${LOG_MAX_BYTES:=10485760}" # 日志轮转阈值（字节，默认 10MB；超过则 mv 为 .1）
: "${LOG_KEEP_DAYS:=30}"       # 轮转副本(.1)保留天数；超过则删除（默认 30 天≈每月清理一次）；0=不按天清理

# =============================================================================
# [2] 初始化 INIT — 数值夹取与绝对上限生效
# =============================================================================

# 把整数夹到 [lo, hi]
safety_clamp_int() {
  local v="$1" lo="$2" hi="$3"
  echo "$v" | grep -Eq '^-?[0-9]+$' || v="$lo"
  [ "$v" -lt "$lo" ] && v="$lo"
  [ "$v" -gt "$hi" ] && v="$hi"
  echo "$v"
}

# 对已 export 的危险参数做绝对封顶（source 时立即生效）
safety_apply_absolute_caps() {
  CPU_AIM_PCT="$(safety_clamp_int "${CPU_AIM_PCT}" 1 "${SAFETY_ABS_CPU_AIM_MAX}")"
  CPU_HARD_CAP_PCT="$(safety_clamp_int "${CPU_HARD_CAP_PCT}" 1 "${SAFETY_ABS_CPU_HARD_MAX}")"
  CPU_TARGET_PCT_OFF="$(safety_clamp_int "${CPU_TARGET_PCT_OFF}" 1 "${SAFETY_ABS_CPU_HARD_MAX}")"
  CPU_TARGET_PCT_BIZ="$(safety_clamp_int "${CPU_TARGET_PCT_BIZ}" 1 "${SAFETY_ABS_CPU_HARD_MAX}")"
  [ "${CPU_HARD_CAP_PCT}" -lt "${CPU_TARGET_PCT_OFF}" ] && CPU_HARD_CAP_PCT="${CPU_TARGET_PCT_OFF}"
  [ "${CPU_HARD_CAP_PCT}" -lt "${CPU_TARGET_PCT_BIZ}" ] && CPU_HARD_CAP_PCT="${CPU_TARGET_PCT_BIZ}"
  [ "${CPU_HARD_CAP_PCT}" -gt "${SAFETY_ABS_CPU_HARD_MAX}" ] && CPU_HARD_CAP_PCT="${SAFETY_ABS_CPU_HARD_MAX}"

  MEM_HARD_CAP_PCT="$(safety_clamp_int "${MEM_HARD_CAP_PCT}" 1 "${SAFETY_ABS_MEM_HARD_MAX}")"
  MEM_TARGET_PCT_OFF="$(safety_clamp_int "${MEM_TARGET_PCT_OFF}" 1 "${SAFETY_ABS_MEM_TARGET_MAX}")"
  MEM_TARGET_PCT_BIZ="$(safety_clamp_int "${MEM_TARGET_PCT_BIZ}" 1 "${SAFETY_ABS_MEM_TARGET_MAX}")"
  MEM_ABORT_USED_PCT="$(safety_clamp_int "${MEM_ABORT_USED_PCT}" 1 "${SAFETY_ABS_MEM_HARD_MAX}")"
  # abort 线不低于硬顶，避免「还没到硬顶就永久停」过早；若硬顶>abort 则抬 abort
  [ "${MEM_ABORT_USED_PCT}" -lt "${MEM_HARD_CAP_PCT}" ] && MEM_ABORT_USED_PCT="${MEM_HARD_CAP_PCT}"
  MEM_RESERVE_PCT="$(safety_clamp_int "${MEM_RESERVE_PCT}" 5 80)"
  MEM_TAKE_OF_FREE_PCT="$(safety_clamp_int "${MEM_TAKE_OF_FREE_PCT}" 1 80)"
  MEM_CHUNK_MB="$(safety_clamp_int "${MEM_CHUNK_MB}" 0 4096)"
  MEM_CHUNK_MAX_MB="$(safety_clamp_int "${MEM_CHUNK_MAX_MB}" 16 4096)"
  MEM_ALLOC_MBPS="$(safety_clamp_int "${MEM_ALLOC_MBPS}" 0 1048576)"
  CPU_TARGET_BAND_PCT="$(safety_clamp_int "${CPU_TARGET_BAND_PCT}" 1 15)"
  CPU_BACKOFF_STEP="$(safety_clamp_int "${CPU_BACKOFF_STEP}" 1 64)"

  if [ "${SMALL_CPU_HARD_CAP_PCT}" != "0" ]; then
    SMALL_CPU_HARD_CAP_PCT="$(safety_clamp_int "${SMALL_CPU_HARD_CAP_PCT}" 1 "${SAFETY_ABS_CPU_HARD_MAX}")"
  fi
  if [ "${ALLOW_NPROC_OVERRIDE}" != "1" ]; then
    CPU_NPROC_OVERRIDE=0
  fi
}

safety_apply_absolute_caps

#=============================================================================
# [3] 内部诊断 INTERNAL — 避免 $(fn) 子 shell 丢变量，故落盘
# =============================================================================

# 诊断文件路径
_safety_diag_file() {
  echo "${SAFETY_STATE_DIR}/.safety_last_diag"
}

# 写入最近一次安全计算说明（供 logs/status 读取）
# $1 = 诊断字符串
_safety_set_diag() {
  SAFETY_LAST_DIAG="$1"
  mkdir -p "$SAFETY_STATE_DIR" 2>/dev/null || true
  echo "$1" >"$(_safety_diag_file)" 2>/dev/null || true
}

# 读取最近诊断；优先文件，其次内存变量
_safety_get_diag() {
  if [ -f "$(_safety_diag_file)" ]; then
    cat "$(_safety_diag_file)"
  else
    echo "$SAFETY_LAST_DIAG"
  fi
}

# =============================================================================
# [4] CPU 策略 BIZ — 探测 / 生效参数 / worker / 降载
# =============================================================================

# 返回用于算配额的逻辑核数（可被 CPU_NPROC_OVERRIDE 覆盖）
safety_nproc() {
  if [ -n "${CPU_NPROC_OVERRIDE}" ] && [ "${CPU_NPROC_OVERRIDE}" != "0" ]; then
    echo "$CPU_NPROC_OVERRIDE"
    return
  fi
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif [ -f /proc/cpuinfo ]; then
    grep -c ^processor /proc/cpuinfo
  else
    echo 1
  fi
}

# 是否小核机：用「真实 nproc」判断，不受 OVERRIDE 影响
# return 0=是小核；1=否
safety_is_small_host() {
  local real
  if [ "${CPU_DISABLE_SMALL_DERATE}" = "1" ]; then
    return 1
  fi
  if command -v nproc >/dev/null 2>&1; then
    real="$(nproc)"
  else
    real="$(safety_nproc)"
  fi
  [ "$real" -lt "$SMALL_NPROC_THRESHOLD" ]
}

# 生效硬顶 %（小核仅当 SMALL_CPU_HARD_CAP_PCT>0 才覆盖）
safety_eff_hard_pct() {
  if safety_is_small_host && [ "${SMALL_CPU_HARD_CAP_PCT}" != "0" ]; then
    echo "$SMALL_CPU_HARD_CAP_PCT"
  else
    echo "$CPU_HARD_CAP_PCT"
  fi
}

# 生效营业目标 %
safety_eff_biz_pct() {
  if safety_is_small_host && [ "${SMALL_CPU_TARGET_PCT_BIZ}" != "0" ]; then
    echo "$SMALL_CPU_TARGET_PCT_BIZ"
  else
    echo "$CPU_TARGET_PCT_BIZ"
  fi
}

# 生效非营业目标 %
safety_eff_off_pct() {
  if safety_is_small_host && [ "${SMALL_CPU_TARGET_PCT_OFF}" != "0" ]; then
    echo "$SMALL_CPU_TARGET_PCT_OFF"
  else
    echo "$CPU_TARGET_PCT_OFF"
  fi
}

# 生效营业 soft（秒）
safety_eff_biz_soft() {
  if safety_is_small_host; then echo "$SMALL_BIZ_SOFT"; else echo "$BIZ_SOFT"; fi
}

# 生效非营业 soft（秒）
safety_eff_off_soft() {
  if safety_is_small_host; then echo "$SMALL_OFF_SOFT"; else echo "$OFF_SOFT"; fi
}

# 降载用的「最低空闲 %」
# CPU_MIN_IDLE_PCT>0 用显式值；否则 = clamp(100-硬顶-余量, 30..90)
safety_eff_min_idle_pct() {
  local hard head min_idle
  if [ -n "${CPU_MIN_IDLE_PCT}" ] && [ "${CPU_MIN_IDLE_PCT}" != "0" ]; then
    echo "$CPU_MIN_IDLE_PCT"
    return
  fi
  hard="$(safety_eff_hard_pct)"
  head="$CPU_IDLE_HEADROOM_PCT"
  min_idle=$((100 - hard - head))
  [ "$min_idle" -lt 30 ] && min_idle=30
  [ "$min_idle" -gt 90 ] && min_idle=90
  echo "$min_idle"
}

# 当前是否营业时段 [BIZ_START_H, BIZ_END_H)（默认 8–19，名义 9–18 外扩）
# return 0=营业；1=非营业
safety_is_biz_hour() {
  local h
  h="$(date '+%H' | sed 's/^0//')"
  [ -z "$h" ] && h=0
  [ "$h" -ge "$BIZ_START_H" ] && [ "$h" -lt "$BIZ_END_H" ]
}

# 按目标百分比换算 worker 数，并施加 MIN_WORKERS 与硬顶
# $1 = 目标占逻辑核百分比
# stdout = worker 个数（≥1，且 ≤ hard）；MIN_WORKERS 也不能突破硬顶
safety_cpu_n_for_pct() {
  local pct="$1"
  local np hard n floor hard_pct
  np="$(safety_nproc)"
  hard_pct="$(safety_eff_hard_pct)"
  hard_pct="$(safety_clamp_int "$hard_pct" 1 "${SAFETY_ABS_CPU_HARD_MAX}")"
  hard="$(awk -v np="$np" -v p="$hard_pct" 'BEGIN{n=int(np*p/100.0); if(n<1)n=1; print n}')"
  n="$(awk -v np="$np" -v p="$pct" 'BEGIN{n=int(np*p/100.0+0.5); if(n<1)n=1; print n}')"
  floor="$CPU_MIN_WORKERS"
  if [ -n "$floor" ] && [ "$floor" != "0" ]; then
    echo "$floor" | grep -Eq '^[0-9]+$' || floor=0
    [ "$floor" -gt 0 ] && [ "$n" -lt "$floor" ] && n=$floor
  fi
  [ "$n" -gt "$hard" ] && n=$hard
  echo "$n"
}

# 当前时段的 CPU 计划配置
# stdout: mode|plan_n|soft|hard_n|nproc
#   mode = biz|off|biz-small|off-small
safety_cpu_profile() {
  local np mode n soft hard hard_pct biz_pct off_pct
  np="$(safety_nproc)"
  hard_pct="$(safety_eff_hard_pct)"
  hard="$(awk -v np="$np" -v p="$hard_pct" 'BEGIN{n=int(np*p/100.0); if(n<1)n=1; print n}')"
  biz_pct="$(safety_eff_biz_pct)"
  off_pct="$(safety_eff_off_pct)"
  if safety_is_biz_hour; then
    mode="biz"
    n="$(safety_cpu_n_for_pct "$biz_pct")"
    soft="$(safety_eff_biz_soft)"
  else
    mode="off"
    n="$(safety_cpu_n_for_pct "$off_pct")"
    soft="$(safety_eff_off_soft)"
  fi
  [ "$n" -gt "$hard" ] && n=$hard
  if safety_is_small_host; then
    mode="${mode}-small"
  fi
  echo "${mode}|${n}|${soft}|${hard}|${np}"
}

# 采样整机空闲百分比（/proc/stat 两次，间隔 1s）
# stdout = 0..100 的整数
safety_cpu_idle_pct() {
  local a1 a2 a3 idle1 a5 a6 a7 a8 a9 a10
  local b1 b2 b3 idle2 b5 b6 b7 b8 b9 b10
  local tot1 tot2
  read -r _ a1 a2 a3 idle1 a5 a6 a7 a8 a9 a10 _ </proc/stat 2>/dev/null || { echo 50; return; }
  tot1=$((a1+a2+a3+idle1+a5+a6+a7+a8+a9+a10))
  sleep 1
  read -r _ b1 b2 b3 idle2 b5 b6 b7 b8 b9 b10 _ </proc/stat 2>/dev/null || { echo 50; return; }
  tot2=$((b1+b2+b3+idle2+b5+b6+b7+b8+b9+b10))
  awk -v i1="$idle1" -v i2="$idle2" -v t1="$tot1" -v t2="$tot2" \
    'BEGIN{
      di=i2-i1; dt=t2-t1;
      if(dt<=0){print 50; exit}
      printf "%d", di*100/dt;
    }'
}

# 1 分钟 loadavg
safety_load1() {
  awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0
}

# 硬顶对应的最大 worker 个数
safety_cpu_hard_n() {
  local np hard_pct
  np="$(safety_nproc)"
  hard_pct="$(safety_eff_hard_pct)"
  hard_pct="$(safety_clamp_int "$hard_pct" 1 "${SAFETY_ABS_CPU_HARD_MAX}")"
  awk -v np="$np" -v p="$hard_pct" 'BEGIN{n=int(np*p/100.0); if(n<1)n=1; print n}'
}

# 硬顶可达成的整机 busy% 上限（满烧 hard_n 个 worker、soft=0）
# 例：nproc=4 hard_n=1 → 25
safety_cpu_achievable_pct() {
  local np hard_n
  np="$(safety_nproc)"
  hard_n="$(safety_cpu_hard_n)"
  echo "$np" | grep -Eq '^[0-9]+$' || np=1
  [ "$np" -lt 1 ] && np=1
  awk -v w="$hard_n" -v n="$np" 'BEGIN{p=int(w*100/n); if(p<1)p=1; print p}'
}

# 当前时段「配置」目标 %（未做粒度折算）
safety_eff_cfg_target_pct() {
  if safety_is_biz_hour; then
    safety_eff_biz_pct
  else
    safety_eff_off_pct
  fi
}

# 当前时段「生效」目标 % = min(配置, 硬顶可达成)
# 小核常见：配置34% → 生效25%，闭环钉可达成值，避免空加 worker
safety_eff_target_pct() {
  local cfg ach
  cfg="$(safety_eff_cfg_target_pct)"
  ach="$(safety_cpu_achievable_pct)"
  echo "$cfg" | grep -Eq '^[0-9]+$' || cfg=30
  echo "$ach" | grep -Eq '^[0-9]+$' || ach=100
  if [ "$cfg" -gt "$ach" ]; then
    echo "$ach"
  else
    echo "$cfg"
  fi
}

# 闭环调节 worker：把整机占用大致钉在目标±BAND
# $1 = 计划上限 plan_n（nproc×目标%）
# $2 = 当前存活 worker 数（可空；空则按「当前 busy 相对目标的缺口」冷启动估算）
# stdout = 建议 worker 数（0..hard）
# 副作用：_safety_set_diag（diag 里 action=本次闭环建议动作，可多个叠加，+ 连接）
#
# action 取值速查（status 的「闭环：action=…」显示）：
#   hold                   初始化占位（后续会被覆盖）
#   cold_skip(busy>=target) 冷启动且 busy 已达标：不动
#   cold_gap               冷启动按缺口补 worker（gap = 目标−当前 busy）
#   cut(busy>hi)           busy 超过上沿：减 worker
#   add(busy<lo)           busy 低于下沿：加 worker
#   in_band                落在目标±BAND 内：保持
#   +load                  load1/nproc 超阈值：再减（防负载过高）
#   +emerg_idle            空闲低于紧急下限：再减（防卡死拖慢）
#   +over_hard             超过硬顶：减到硬顶
#   +keep_min1             保留最后 1 个 worker（防掉 0%，未超硬顶且非紧急时兜底）
#   +derate_granularity    小核动态折算：生效目标被硬顶可达成%压过（如配置34%→生效25%）
safety_cpu_apply_backoff() {
  local want="$1"
  local alive="${2:-}"
  local np hard idle busy load ratio step hard_pct
  local target cfg_target band hi lo gap delta safe emerg_idle action hard_n derate

  np="$(safety_nproc)"
  hard_pct="$(safety_eff_hard_pct)"
  hard="$(safety_cpu_hard_n)"
  echo "$want" | grep -Eq '^[0-9]+$' || want=$hard
  [ "$want" -gt "$hard" ] && want=$hard

  cfg_target="$(safety_eff_cfg_target_pct)"
  target="$(safety_eff_target_pct)"
  derate=0
  if [ "$cfg_target" -gt "$target" ] 2>/dev/null; then
    derate=1
  fi
  band="${CPU_TARGET_BAND_PCT}"
  echo "$band" | grep -Eq '^[0-9]+$' || band=5
  hi=$((target + band))
  lo=$((target - band))
  [ "$lo" -lt 3 ] && lo=3
  [ "$hi" -gt 95 ] && hi=95
  [ "$hi" -gt "$hard_pct" ] && hi=$hard_pct

  idle="$(safety_cpu_idle_pct)"
  echo "$idle" | grep -Eq '^[0-9]+$' || idle=50
  busy=$((100 - idle))
  [ "$busy" -lt 0 ] && busy=0
  [ "$busy" -gt 100 ] && busy=100

  load="$(safety_load1)"
  ratio="$(awk -v l="$load" -v np="$np" 'BEGIN{if(np<1)np=1; printf "%.2f", l/np}')"
  step="${CPU_BACKOFF_STEP}"
  echo "$step" | grep -Eq '^[0-9]+$' || step=2
  [ "$step" -lt 1 ] && step=1
  emerg_idle="$(safety_eff_min_idle_pct)"
  action="hold"

  if [ -z "$alive" ] || ! echo "$alive" | grep -Eq '^[0-9]+$'; then
    # 冷启动：只补「目标 − 当前整机占用」的缺口，避免业务已忙时再叠满 plan_n
    gap=$((target - busy))
    if [ "$gap" -le 0 ]; then
      safe=0
      action="cold_skip(busy>=target)"
    else
      safe="$(awk -v np="$np" -v g="$gap" 'BEGIN{n=int(np*g/100.0+0.5); if(n<1)n=1; print n}')"
      action="cold_gap"
    fi
  else
    safe="$alive"
    if [ "$busy" -gt "$hi" ]; then
      delta="$(awk -v np="$np" -v b="$busy" -v t="$target" 'BEGIN{n=int(np*(b-t)/100.0+0.5); if(n<1)n=1; print n}')"
      [ "$delta" -lt "$step" ] && delta=$step
      safe=$((alive - delta))
      action="cut(busy>hi)"
    elif [ "$busy" -lt "$lo" ]; then
      delta="$(awk -v np="$np" -v t="$target" -v b="$busy" 'BEGIN{n=int(np*(t-b)/100.0+0.5); if(n<1)n=1; print n}')"
      [ "$delta" -lt "$step" ] && delta=$step
      safe=$((alive + delta))
      [ "$safe" -gt "$want" ] && safe=$want
      action="add(busy<lo)"
    else
      action="in_band"
    fi
  fi

  # load 过高再减一档
  awk -v r="$ratio" -v m="$CPU_LOAD_RATIO_MAX" 'BEGIN{exit !(r+0 > m+0)}'
  if [ $? -eq 0 ]; then
    safe=$((safe - step))
    action="${action}+load"
  fi

  # 紧急：空闲过低（相对硬顶）强制再减，防卡死
  if [ "$idle" -lt "$emerg_idle" ]; then
    safe=$((safe - step))
    action="${action}+emerg_idle"
  fi

  # 超过硬顶占用：压到硬顶对应个数以下
  if [ "$busy" -gt "$hard_pct" ]; then
    hard_n="$(awk -v np="$np" -v p="$hard_pct" 'BEGIN{n=int(np*p/100.0); if(n<0)n=0; print n}')"
    [ "$safe" -gt "$hard_n" ] && safe=$hard_n
    safe=$((safe - step))
    action="${action}+over_hard"
  fi

  [ "$safe" -lt 0 ] && safe=0
  [ "$safe" -gt "$hard" ] && safe=$hard
  [ "$safe" -gt "$want" ] && safe=$want

  # MIN_WORKERS：仅当整机仍明显低于目标下沿时才抬底，避免「业务已忙还硬开」
  if [ -n "${CPU_MIN_WORKERS}" ] && [ "${CPU_MIN_WORKERS}" != "0" ] && \
     echo "${CPU_MIN_WORKERS}" | grep -Eq '^[0-9]+$' && [ "$busy" -lt "$lo" ]; then
    [ "$safe" -lt "$CPU_MIN_WORKERS" ] && safe=$CPU_MIN_WORKERS
    [ "$safe" -gt "$hard" ] && safe=$hard
  fi

  # 未超硬顶且非紧急空闲：不要砍光最后 1 个（小核 cut step 易把 1→0 闪断到 0%）
  # 仅 busy>硬顶% 或 idle<紧急线 时允许 safe=0
  if [ "$want" -ge 1 ] 2>/dev/null && [ "$safe" -lt 1 ] 2>/dev/null; then
    if [ "$busy" -le "$hard_pct" ] 2>/dev/null && [ "$idle" -ge "$emerg_idle" ] 2>/dev/null; then
      safe=1
      [ "$safe" -gt "$hard" ] && safe=$hard
      [ "$safe" -gt "$want" ] && safe=$want
      action="${action}+keep_min1"
    fi
  fi

  if [ "$derate" = "1" ]; then
    action="${action}+derate_granularity"
  fi

  _safety_set_diag "cfg=${cfg_target}% target=${target}% band=±${band}% busy=${busy}% idle=${idle}% lo=${lo} hi=${hi} want=${want} alive=${alive:-na} safe=${safe} action=${action} hard=${hard} nproc=${np} load1=${load} ratio=${ratio} derate=${derate}"
  echo "$safe"
}

# =============================================================================
# [5] 内存策略 BIZ — used% 目标与安全申请量
# =============================================================================

# 读 /proc/meminfo 某字段（KB）
# $1 = 字段名，如 MemTotal / MemAvailable
safety_mem_kb() {
  awk "/^$1:/{print \$2}" /proc/meminfo 2>/dev/null
}

# 当前时段内存目标 used %
safety_mem_target_pct() {
  if safety_is_biz_hour; then
    echo "$MEM_TARGET_PCT_BIZ"
  else
    echo "$MEM_TARGET_PCT_OFF"
  fi
}

# 整机 used% 整数 ≈ (Total−Available)/Total
safety_mem_used_pct() {
  local total avail
  total="$(safety_mem_kb MemTotal)"
  avail="$(safety_mem_kb MemAvailable)"
  if [ -z "$total" ] || [ "$total" -le 0 ] 2>/dev/null; then
    echo 0
    return
  fi
  [ -z "$avail" ] && avail=0
  awk -v t="$total" -v a="$avail" 'BEGIN{printf "%d", (t-a)*100/t}'
}

# 生效的 Available 绝对下限（KB）：min(配置MIN, 总内存15%)
# 避免小内存机被 4GB 底线卡死导致 need 恒为 0
safety_effective_reserve_min_kb() {
  local total min_kb cap_kb
  total="$(safety_mem_kb MemTotal)"
  [ -z "$total" ] && total=0
  min_kb=$((MEM_RESERVE_MIN_MB * 1024))
  cap_kb="$(awk -v t="$total" 'BEGIN{printf "%d", t*15/100}')"
  if [ "$total" -gt 0 ] && [ "$min_kb" -gt "$cap_kb" ]; then
    echo "$cap_kb"
  else
    echo "$min_kb"
  fi
}

# 计算「再申请多少 MB」才安全地靠近目标 used%
# $1 可选：目标 used%（默认按时段）
# stdout = MB（可能为 0）
# 取 min(目标缺口, 保留底线后可占, 闲置可吃比例)
safety_mem_need_mb() {
  local pct="${1:-}"
  local total avail reserve_kb reserve_min_kb max_by_reserve max_by_free target_used cur_used need_kb hard_used mb
  [ -n "$pct" ] || pct="$(safety_mem_target_pct)"
  awk -v p="$pct" -v h="$MEM_HARD_CAP_PCT" 'BEGIN{exit !(p+0 > h+0)}'
  if [ $? -eq 0 ]; then
    pct="$MEM_HARD_CAP_PCT"
  fi

  total="$(safety_mem_kb MemTotal)"
  avail="$(safety_mem_kb MemAvailable)"
  if [ -z "$total" ] || [ -z "$avail" ]; then
    _safety_set_diag "meminfo_unreadable"
    SAFETY_MEM_NEED_MB=0
    echo 0
    return
  fi

  reserve_min_kb="$(safety_effective_reserve_min_kb)"
  reserve_kb="$(awk -v t="$total" -v p="$MEM_RESERVE_PCT" -v m="$reserve_min_kb" \
    'BEGIN{r=int(t*p/100.0); if(r<m)r=m; print r}')"

  max_by_reserve=$((avail - reserve_kb))
  [ "$max_by_reserve" -lt 0 ] && max_by_reserve=0

  max_by_free="$(awk -v a="$avail" -v p="$MEM_TAKE_OF_FREE_PCT" -v r="$reserve_kb" \
    'BEGIN{
      take=int(a*p/100.0);
      if (a - take < r) take = a - r;
      if (take < 0) take = 0;
      print take;
    }')"

  target_used="$(awk -v t="$total" -v p="$pct" 'BEGIN{printf "%d", t*p/100.0}')"
  cur_used=$((total - avail))
  need_kb=$((target_used - cur_used))
  [ "$need_kb" -lt 0 ] && need_kb=0

  hard_used="$need_kb"
  [ "$hard_used" -gt "$max_by_reserve" ] && hard_used=$max_by_reserve
  [ "$hard_used" -gt "$max_by_free" ] && hard_used=$max_by_free

  mb="$(awk -v n="$hard_used" 'BEGIN{printf "%d", n/1024}')"
  SAFETY_MEM_NEED_MB="$mb"
  _safety_set_diag "pct=${pct} total_kB=${total} avail_kB=${avail} reserve_kB=${reserve_kb} reserve_min_kB=${reserve_min_kb} need_kB=${need_kb} allow_kB=${hard_used} allow_MB=${mb}"
  echo "$mb"
}

# =============================================================================
# [6] 运维输出 OPS — safety_dump 速览（供 `*_ctl.sh safety`）
# =============================================================================

# 打印当前安全策略计算结果
# 现场易混点已写明：AIM≠营业必30%；早降载≠目标；top进程%CPU≠整机；小核粒度
safety_dump() {
  if [ "${SAFETY_REDACT}" = "1" ]; then
    cat <<EOF
============================================================
 安全策略预览（脱敏模式）
============================================================
 时间/档位 : $(date "+%H:%M" 2>/dev/null || echo now)  →  当前$(safety_is_biz_hour && echo 营业 || echo 非营业)档
 运行状态  : 请用 $0 status 查看（本输出已脱敏）
 $(_ops_redact_note)
============================================================
EOF
    return 0
  fi
  local p mode plan_n soft hard_n np
  local real_np min_idle mem_mb
  local now_h period_label
  local biz_n off_n hard_pct biz_pct off_pct
  local total_kb avail_kb used_pct total_gb avail_gb
  local small_label override_note
  local biz_machine_pct off_machine_pct cur_machine_pct
  local max_one_core_pct note_granularity
  local ach_pct cfg_target eff_target derate_note

  real_np="$(nproc 2>/dev/null || echo '?')"
  p="$(safety_cpu_profile)"
  mode="$(echo "$p" | cut -d'|' -f1)"
  plan_n="$(echo "$p" | cut -d'|' -f2)"
  soft="$(echo "$p" | cut -d'|' -f3)"
  hard_n="$(echo "$p" | cut -d'|' -f4)"
  np="$(echo "$p" | cut -d'|' -f5)"
  mem_mb="$(safety_mem_need_mb)"
  min_idle="$(safety_eff_min_idle_pct)"
  biz_pct="$(safety_eff_biz_pct)"
  off_pct="$(safety_eff_off_pct)"
  hard_pct="$(safety_eff_hard_pct)"
  ach_pct="$(safety_cpu_achievable_pct)"
  cfg_target="$(safety_eff_cfg_target_pct)"
  eff_target="$(safety_eff_target_pct)"
  biz_n="$(safety_cpu_n_for_pct "$biz_pct")"
  off_n="$(safety_cpu_n_for_pct "$off_pct")"
  [ "$biz_n" -gt "$hard_n" ] 2>/dev/null && biz_n=$hard_n
  [ "$off_n" -gt "$hard_n" ] 2>/dev/null && off_n=$hard_n

  derate_note="否（配置=生效=${eff_target}%）"
  if [ "$cfg_target" -gt "$eff_target" ] 2>/dev/null; then
    derate_note="是：配置${cfg_target}% → 生效${eff_target}%（硬顶可达成≤${ach_pct}%）"
  fi

  now_h="$(date '+%H:%M' 2>/dev/null || echo '?')"
  case "$mode" in
    biz|biz-small) period_label="营业档" ;;
    *)             period_label="非营业档" ;;
  esac

  if safety_is_small_host; then
    small_label="是（真实核数 < ${SMALL_NPROC_THRESHOLD}）"
  else
    small_label="否"
  fi

  if [ "${CPU_NPROC_OVERRIDE}" != "0" ] && [ -n "${CPU_NPROC_OVERRIDE}" ]; then
    if [ "${ALLOW_NPROC_OVERRIDE}" = "1" ]; then
      override_note="已启用假核数=${CPU_NPROC_OVERRIDE}（仅调试）"
    else
      override_note="已设 OVERRIDE=${CPU_NPROC_OVERRIDE} 但未允许，忽略"
    fi
  else
    override_note="否"
  fi

  total_kb="$(safety_mem_kb MemTotal)"
  avail_kb="$(safety_mem_kb MemAvailable)"
  if [ -n "$total_kb" ] && [ "$total_kb" -gt 0 ] 2>/dev/null; then
    used_pct="$(awk -v t="$total_kb" -v a="$avail_kb" 'BEGIN{printf "%.1f", (t-a)*100.0/t}')"
    total_gb="$(awk -v t="$total_kb" 'BEGIN{printf "%.1f", t/1024/1024}')"
    avail_gb="$(awk -v a="$avail_kb" 'BEGIN{printf "%.1f", a/1024/1024}')"
  else
    used_pct="?"
    total_gb="?"
    avail_gb="?"
  fi

  # 粗算：满烧时 整机% ≈ worker数 / nproc × 100（有 soft 会更低）
  if echo "$np" | grep -Eq '^[0-9]+$' && [ "$np" -gt 0 ]; then
    biz_machine_pct="$(awk -v w="$biz_n" -v n="$np" 'BEGIN{printf "%.0f", w*100.0/n}')"
    off_machine_pct="$(awk -v w="$off_n" -v n="$np" 'BEGIN{printf "%.0f", w*100.0/n}')"
    cur_machine_pct="$(awk -v w="$plan_n" -v n="$np" 'BEGIN{printf "%.0f", w*100.0/n}')"
    max_one_core_pct="$(awk -v n="$np" 'BEGIN{printf "%.0f", 100.0/n}')"
  else
    biz_machine_pct="?"
    off_machine_pct="?"
    cur_machine_pct="?"
    max_one_core_pct="?"
  fi

  note_granularity=""
  if [ "$biz_n" = "$off_n" ] && [ "$off_n" = "$hard_n" ]; then
    note_granularity="注意: 本机核少，营业/非营业/硬顶都是 ${hard_n} 个 worker；闭环已按硬顶可达成%折算生效目标（${derate_note}）。精确 ${CPU_AIM_PCT}% 请到大核验收。"
  fi

  cat <<EOF
============================================================
 安全策略预览  $(date '+%F %T' 2>/dev/null || echo now)
============================================================

■ 当前结论
  档位          : ${now_h} → ${period_label}（mode=${mode}）；窗口 ${BIZ_START_H}:00–${BIZ_END_H}:00 为营业
  本档会拉      : ${plan_n} 个 CPU worker，soft=${soft}s（soft>0 则单核占空比更低）
  生效目标      : 配置${cfg_target}% → 生效${eff_target}%（硬顶可达成≤${ach_pct}%）${derate_note:+｜${derate_note}}
  内存本轮可再占: 约 ${mem_mb} MB

■ 口径要点（别和 top 搞混）
  1) 看整机看 top 顶上 %Cpu(s)；进程行 %CPU 是单核口径（非营业默认 29%≈28~30，营业 34%）
  2) 闭环：busy 落在生效目标±BAND 内保持，出带加减 worker；长期用 schedule-bg
  3) 硬顶=worker 个数上限（≤nproc×硬顶%），不是整机锁死；绝对天花板≤${SAFETY_ABS_CPU_HARD_MAX}%
  4) 防拖死：硬顶+业务尖峰自动减 worker，不会打满拖死；动态折算：生效=min(配置,硬顶可达成)
  5) 4核常见配置34%→生效25%（精确34%请到大核验收）

■ 本机
  真实逻辑核    : ${real_np}   计算用核数: ${np}（假核覆盖: ${override_note}）
  小核机        : ${small_label}   1个worker满烧: 整机约 ${max_one_core_pct}%（核越少越难凑精确 ${CPU_AIM_PCT}%）

■ CPU 两档对比（目标% → worker → 满烧粗算整机%）
  ---------------------------------------------------------
  档位        目标%        worker      粗算整机%     soft
  营业        ${biz_pct}%          ${biz_n}          ${biz_machine_pct}%        $(safety_eff_biz_soft)s
  非营业      ${off_pct}%          ${off_n}          ${off_machine_pct}%        $(safety_eff_off_soft)s
  硬顶上限    ${hard_pct}%         最多${hard_n}个   —            —
  ---------------------------------------------------------
  配置来源: AIM=${CPU_AIM_PCT}  BIZ=${CPU_TARGET_PCT_BIZ}  OFF=${CPU_TARGET_PCT_OFF}  HARD=${CPU_HARD_CAP_PCT}
  闭环带宽: 生效目标±${CPU_TARGET_BAND_PCT}%（出带加减 worker）  紧急再减: 空闲<${min_idle}% 或 busy>硬顶
  抬底    : CPU_MIN_WORKERS=${CPU_MIN_WORKERS}（仅 busy 仍低于下沿时才抬）
  两档可对调: export CPU_TARGET_PCT_BIZ / OFF 即互换高低

■ 内存（used% = (Total−Available)/Total）
  现状          : 总 ${total_gb}G / 可用 ${avail_gb}G / 约已用 ${used_pct}%
  营业/非营业/硬顶: ${MEM_TARGET_PCT_BIZ}% / ${MEM_TARGET_PCT_OFF}% / ${MEM_HARD_CAP_PCT}%（绝对≤${SAFETY_ABS_MEM_HARD_MAX}%）
  带内闭环      : 营业带[${MEM_BAND_LO_PCT_BIZ:-${MEM_BAND_LO_PCT:-49}},${MEM_BAND_HI_PCT_BIZ:-${MEM_BAND_HI_PCT:-55}}]% / 非营业带[${MEM_BAND_LO_PCT_OFF:-${MEM_BAND_LO_PCT:-49}},${MEM_BAND_HI_PCT_OFF:-${MEM_BAND_HI_PCT:-55}}]%（lo 低于补占 / hi 高于释放）
  中止线 pause  : used≥${MEM_ABORT_USED_PCT}% → 暂停占用（释放 hold），回落自动恢复
  保留底线      : Available ≥ 总内存${MEM_RESERVE_PCT}% 且 ≥ ${MEM_RESERVE_MIN_MB}MB（小机自动下调）
  分片/速率    : CHUNK=${MEM_CHUNK_MB}(0=auto) MAX=${MEM_CHUNK_MAX_MB}MB ALLOC=${MEM_ALLOC_MBPS}MB/s
  本轮建议再占  : ${mem_mb} MB（need=min(目标缺口,保留,闲置60%)；应用涨则工具不涨）
  动态降载      : 每拍按 need_mb 重算；带内不动、出带加减；业务/泄漏冲高自动释放让路

■ 护栏（防拖机）
  CPU: AIM≤${SAFETY_ABS_CPU_AIM_MAX}%  硬顶绝对≤${SAFETY_ABS_CPU_HARD_MAX}%（export 再大也压回）
  MEM: 硬顶≤${SAFETY_ABS_MEM_HARD_MAX}%   ALLOW_NPROC_OVERRIDE=${ALLOW_NPROC_OVERRIDE}
  杀进程: 仅本人 + cmdline 含本工具标记   持续防拖: 必须 schedule-bg

■ 常用调整（改完需 restart / 重新 schedule-bg）
  营业↔非营业对调       export CPU_TARGET_PCT_BIZ=22 CPU_TARGET_PCT_OFF=30
  带宽更紧/更松         export CPU_TARGET_BAND_PCT=1   # 1=更紧；2=更松
  128核抬底             export CPU_MIN_WORKERS=30
============================================================
EOF

  if [ -n "$note_granularity" ]; then
    echo "【本机提示】${note_granularity}"
  elif safety_is_small_host; then
    echo "【本机提示】小核机 worker 只能整开；粗算整机% = worker/核数×100，有 soft 会低于目标%。"
    echo "            精确≈${CPU_AIM_PCT}% 请到大核（如海光128）验收；本机主要验分时/启停逻辑。"
  fi
}
