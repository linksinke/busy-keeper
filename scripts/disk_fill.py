#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
disk_fill.py — 写大文件占用磁盘空间（模拟日志文本 / 二进制随机数据）。

版本   : 1.1.0
许可证 : MIT
兼容   : Python 2 / 3。由 disk_stress_ctl.sh 拉起，也可单独执行。

设计参考（最佳实践）:
  - 单个 part 文件 2~5GB 为宜：
      * 过小(<1GB)：文件数量多(如 65+)，IO 频繁、写盘慢；
      * 过大(>10GB)：Python 若用 readlines() 等读它，瞬时内存飙升。
  - part 大小默认按目标「动态规划」（类似 mem_hold 自适应分片）：
      * 小目标用小块、大目标用大块，单 part 默认封顶 5GB；
      * 目标 ≤2GB→256MB / ≤10GB→1GB / ≤50GB→2.5GB / ≤200GB→5GB / 更大→5GB。
  - 内容默认「模拟日志文本」：每行 = 时间戳 + UUID + 256 字节随机文本 + 换行。
    Python 字符串处理吃内存，便于精确控制；也可用二进制随机数据（写速更快）。

【动态闭环监管（v1.1 新增，默认开启）】
  像开车控制「距离+速度」一样控制写入，避免撞车：
    1. 每拍（DISK_WATCH_INTERVAL 秒）监控磁盘占用率 used%（df 口径）；
    2. 不足目标 → 继续写；逼近目标（DISK_TARGET_SLACK_PCT 前）→ 线性降速防冲过头；
    3. 达到目标占用率 → 停写驻留，不再增长；
    4. 【占用后释放】真实空间满足/超过目标时，必须腾出自己占的空间：
        持续删除自己写的 part 文件（每次删一个并复测），直到 used < 目标或删光；
        日志逐次体现每次 trim。已删光仍高于目标 → 剩余占用为业务/原有，工具管不了；
    5. CPU 联动：整机 busy 高时减半速/暂停写入，CPU 降下来再恢复（DISK_CPU_*）；
    6. 营业/非营业目标占用率与写速可分别设置（DISK_TARGET_PCT_BIZ/OFF、DISK_WRITE_MBPS_BIZ/OFF）。
  核心承诺：工具绝不一味占用——目标满足/超了会自动释放自己写的 part 腾空间，
              但只释放自己写的 part，不清业务/原有占用（那是其它方的事）。

用法:
  python2 disk_fill.py <目标MB>          # DISK_DYNAMIC=0：填到约目标大小（受保留空间限制）
  python2 disk_fill.py <目标MB>          # 默认动态：目标同时受 <目标MB> 与占用率% 双重约束
  python2 disk_fill.py 0                 # 动态模式：只按 DISK_TARGET_PCT 占用率目标

环境变量（可选）:
  DISK_DIR             输出目录（默认当前目录）
  DISK_PART_MB         单个 part 大小 MB；0=按目标自适应（默认）；>0=强制
  DISK_PART_MAX_MB     自适应分片上限 MB（默认 5120 = 5GB）
  DISK_CONTENT         text|binary（默认 text=模拟日志）
  DISK_RESERVE_PCT     保留磁盘空闲比例 %（默认 10，防填满）
  DISK_RESERVE_MB      绝对保留 MB（默认 5120 = 5GB）
  DISK_RESERVE_ABS_MB  绝对保留底线 MB（默认 1024 = 1GB；即使前两者被调 0 也强制保留）
  DISK_WRITE_MBPS      基础写速上限 MB/s（默认 512 限速；0=不限速）
  DISK_FSYNC           1=每个 part fsync（默认 0，写更快）
  DISK_PREFIX          文件名前缀（默认 disk_fill）

【动态监管参数（v1.1）】
  DISK_DYNAMIC         1=动态闭环监管（默认）；0=一次性写入（旧行为）
  DISK_TARGET_PCT      目标磁盘占用率 %（默认 50；动态模式的核心目标）
  DISK_TARGET_PCT_BIZ  营业目标占用率 %（默认空=同 DISK_TARGET_PCT）
  DISK_TARGET_PCT_OFF  非营业目标占用率 %（默认空=同 DISK_TARGET_PCT）
  DISK_TARGET_SLACK_PCT 超调预留 %（默认 2）：写入目标=用户目标−预留，
                        补偿「检查后写一个 part」的粒度超调，使实际占用稳在目标附近。
                        例：目标 50%、预留 2 → 写到 48% 停，实际 ≈50%。0=不预留。
  DISK_SLOW_RATIO      0.85：占用达目标的该比例开始线性降速（0~1）
  DISK_TRIM_OVER       1=used% 超目标时删除已写 part 回落（默认）；0=只停不删
  DISK_WATCH_INTERVAL  监控间隔秒（默认 5）
  DISK_CPU_MAX_BUSY    CPU busy% ≥ 此值暂停写入（默认 80）
  DISK_CPU_SLOW_BUSY   CPU busy% ≥ 此值写速减半（默认 60）
  DISK_MIN_MBPS        降速最低写速 MB/s（默认 50，防完全停顿）
  DISK_WRITE_MBPS_BIZ  营业写速上限 MB/s（默认空=同 DISK_WRITE_MBPS）
  DISK_WRITE_MBPS_OFF  非营业写速上限 MB/s（默认空=同 DISK_WRITE_MBPS）
  BIZ_START_H / BIZ_END_H  营业窗口（默认 8 / 19，左闭右开）

停止: kill <pid> 即可；part 文件默认保留（占用空间），
      由 disk_stress_ctl.sh stop 统一 kill + 删除。
"""

from __future__ import print_function

import os
import struct
import sys
import time
import uuid

PART_MB_AUTO = 0            # 0=按目标自适应
PART_MAX_MB_DEFAULT = 5120  # 自适应分片上限 5GB
RESERVE_PCT_DEFAULT = 10    # 保留磁盘空闲比例 %
RESERVE_MB_DEFAULT = 5120   # 绝对保留 5GB
RESERVE_ABS_MB_DEFAULT = 1024  # 绝对保留底线 1GB（防写爆存储）
WRITE_MBPS_DEFAULT = 512    # 默认写速限速 512MB/s（防疯狂写）
BUF_BYTES = 1024 * 1024     # 每批写入 1MB

# 动态监管默认值
DYNAMIC_DEFAULT = 1
TARGET_PCT_DEFAULT = 50     # 目标磁盘占用率 %
SLACK_PCT_DEFAULT = 2.0     # 超调预留 %（写入目标=用户目标−预留）
SLOW_RATIO_DEFAULT = 0.85   # 占用达目标的该比例开始降速
TRIM_OVER_DEFAULT = 1       # 超目标删除 part 回落
WATCH_INTERVAL_DEFAULT = 5  # 监控间隔秒
CPU_MAX_BUSY_DEFAULT = 80   # CPU busy ≥ 此暂停写
CPU_SLOW_BUSY_DEFAULT = 60  # CPU busy ≥ 此减半速
MIN_MBPS_DEFAULT = 50       # 降速最低写速


def _env_int(name, default):
    raw = os.environ.get(name, "")
    if str(raw).strip() == "":
        return default
    try:
        return int(raw)
    except Exception:
        return default


def _env_float(name, default):
    raw = os.environ.get(name, "")
    if str(raw).strip() == "":
        return default
    try:
        return float(raw)
    except Exception:
        return default


def _rand_hex(n):
    b = os.urandom(n)
    try:
        return b.hex()          # Python 3
    except AttributeError:
        return b.encode("hex")  # Python 2


def fs_stat(path):
    """返回 (总量字节, 可用字节)"""
    st = os.statvfs(path)
    total = st.f_blocks * st.f_frsize
    avail = st.f_bavail * st.f_frsize
    return total, avail


def disk_used_pct(path):
    """磁盘已用百分比 0~100（df 口径）。失败返回 0。"""
    try:
        total, avail = fs_stat(path)
        if total <= 0:
            return 0.0
        used = total - avail
        return used * 100.0 / total
    except Exception:
        return 0.0


def cpu_busy_pct():
    """采样整机 CPU busy%（读 /proc/stat，间隔 0.3s）。失败返回 0。"""
    def _read():
        with open("/proc/stat") as f:
            parts = f.readline().split()
        vals = [int(x) for x in parts[1:8]]
        idle = vals[3] + vals[4]          # idle + iowait
        total = sum(vals)
        return idle, total
    try:
        i1, t1 = _read()
        time.sleep(0.3)
        i2, t2 = _read()
        di = i2 - i1
        dt = t2 - t1
        if dt <= 0:
            return 0.0
        return (1.0 - float(di) / float(dt)) * 100.0
    except Exception:
        return 0.0


def is_biz_hour():
    """营业窗口 [BIZ_START_H, BIZ_END_H)，默认 8~19。"""
    start = _env_int("BIZ_START_H", 8)
    end = _env_int("BIZ_END_H", 19)
    try:
        h = int(time.strftime("%H"))
    except Exception:
        h = 0
    return start <= h < end


def plan_part_mb(target_mb, override_mb, max_mb):
    """按目标动态规划 part 大小（磁盘场景，自适应分片）。

    小目标用小块、大目标用大块，单 part 不超过 max_mb（默认 5GB，
    符合「2~5GB 为宜」；避免过碎 IO 频繁，也避免 >10GB 读取易爆内存）。
    显式指定 DISK_PART_MB>0 时强制使用该值（仍受 max_mb / target 封顶）。

    分段:
      目标 ≤2GB    → 256MB
      目标 ≤10GB   → 1GB
      目标 ≤50GB   → 2.5GB
      目标 ≤200GB  → 5GB
      目标更大     → 5GB（DISK_PART_MAX_MB 封顶）
    """
    target_mb = int(target_mb or 0)
    max_mb = int(max_mb or PART_MAX_MB_DEFAULT)
    if max_mb < 16:
        max_mb = 16
    n = 0
    if override_mb and override_mb > 0:
        n = int(override_mb)
    elif target_mb <= 2048:      # ≤2GB   → 256MB
        n = 256
    elif target_mb <= 10240:     # ≤10GB  → 1GB
        n = 1024
    elif target_mb <= 51200:     # ≤50GB  → 2.5GB
        n = 2560
    elif target_mb <= 204800:    # ≤200GB → 5GB
        n = 5120
    else:                        # 更大   → 5GB（封顶）
        n = PART_MAX_MB_DEFAULT
    if n > max_mb:
        n = max_mb
    if target_mb > 0 and n > target_mb:
        n = target_mb
    if n < 1:
        n = 1
    return n


def _text_line():
    """模拟日志行：时间戳 + UUID + 256 字节随机文本 + 换行。"""
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    uid = str(uuid.uuid4())
    txt = _rand_hex(256)
    return "%s %s %s\n" % (ts, uid, txt)


def _make_text_buffer(size):
    """预组装约 size 字节的日志文本缓冲（重复行），返回 bytes。"""
    line = _text_line()
    n = max(1, int(size / max(1, len(line))))
    buf = "".join([line] * n).encode("utf-8")
    return buf[:size]


def _make_binary_buffer(size):
    """二进制块：4B 序号 + 4B 校验 + 1024B urandom，拼到 size 字节。"""
    parts = []
    used = 0
    seq = 0
    while used < size:
        body = os.urandom(1024)
        hdr = struct.pack(">II", seq, sum(bytearray(body)) & 0xFFFFFFFF)
        blk = hdr + body
        if used + len(blk) > size:
            blk = blk[: size - used]
        parts.append(blk)
        used += len(blk)
        seq += 1
    return b"".join(parts)


def _write_one_part(fpath, mb, content, fsync):
    """写单个 part 文件，返回实际写入 MB。"""
    written = 0.0
    with open(fpath, "wb") as f:
        remaining = int(mb * 1024 * 1024)
        while remaining > 0:
            sz = min(BUF_BYTES, remaining)
            if content == "binary":
                buf = _make_binary_buffer(sz)
            else:
                buf = _make_text_buffer(sz)
            f.write(buf)
            remaining -= sz
            written += sz / (1024.0 * 1024.0)
        if fsync:
            f.flush()
            os.fsync(f.fileno())
    return written


def _trim_parts(path_prefix, parts, how_many=1):
    """删除 parts 列表中最后 how_many 个文件（回落），返回删除的 MB。"""
    freed = 0.0
    for _ in range(how_many):
        if not parts:
            break
        fp = parts.pop()
        try:
            if os.path.exists(fp):
                freed += os.path.getsize(fp) / (1024.0 * 1024.0)
                os.remove(fp)
        except Exception:
            pass
    return freed


def write_target(path_prefix, want_mb, part_mb, content, write_mbps, fsync):
    """一次性写入 want_mb（旧模式 DISK_DYNAMIC=0 用），返回已写 MB。"""
    written = 0.0
    t0 = time.time()
    part = 0
    while written < want_mb:
        this_mb = min(part_mb, want_mb - written)
        part += 1
        fpath = "%s.part%03d" % (path_prefix, part)
        step_t0 = time.time()
        written += _write_one_part(fpath, this_mb, content, fsync)
        elapsed = time.time() - t0
        if elapsed <= 0:
            elapsed = 0.001
        rate = written / elapsed
        remain = want_mb - written
        eta = remain / rate if rate > 0 else -1
        sys.stderr.write(
            "part%d mb=%d written_mb=%d/%d rate_mb_s=%.1f eta_s=%.0f file=%s\n"
            % (part, this_mb, int(written), int(want_mb), rate, eta, fpath)
        )
        sys.stderr.flush()
        # 限速（按单 part 限速）
        if write_mbps > 0:
            need = float(this_mb) / float(write_mbps)
            used = time.time() - step_t0
            if need > used:
                time.sleep(need - used)
    return written


def dynamic_fill(path_prefix, want_mb, part_mb, content, base_mbps, fsync,
                 target_pct, slow_ratio, trim_over, watch_interval,
                 cpu_max_busy, cpu_slow_busy, min_mbps,
                 biz_target_pct, off_target_pct,
                 biz_mbps, off_mbps, out_dir, slack_pct=0.0):
    """动态闭环监管写入（v1.1 默认模式）。

    每拍监控磁盘占用率，逼近目标降速、达到目标停写驻留；
    超目标可删除已写 part 回落；CPU busy 高时减半/暂停。
    返回最终占用 part 列表（供驻留期 trim）。

    slack_pct：超调预留 %。写入目标 = 用户目标 − slack，
    以补偿「检查后写一个 part」的粒度超调，使实际占用稳定在用户目标附近。
    例：DISK_TARGET_PCT=50、slack=2 → 写到 48% 停，超调后实际 ≈50%。
    """
    parts = []
    part_no = 0
    t0 = time.time()

    def _log(msg):
        sys.stderr.write(msg + "\n")
        sys.stderr.flush()

    while True:
        used = disk_used_pct(out_dir)
        if is_biz_hour():
            tgt = biz_target_pct if biz_target_pct > 0 else target_pct
            cur_mbps = biz_mbps if biz_mbps > 0 else base_mbps
            period = "营业"
        else:
            tgt = off_target_pct if off_target_pct > 0 else target_pct
            cur_mbps = off_mbps if off_mbps > 0 else base_mbps
            period = "非营业"
        # 降速起点 = 用户目标 − 超调预留（提前收油门，避免冲过头；默认 48% 起降速）
        slow_start = tgt - slack_pct
        if slow_start < 1.0:
            slow_start = 1.0

        # ── ① 达到/超过用户目标：持续删 part 回落，直到 used < 目标 ──
        # 每拍删一个自己写的 part 并复测；若持续高于目标则继续删，
        # 直到低于目标（或删光自己所有 part）。日志逐次体现每次删除。
        while used >= tgt:
            if not (trim_over and parts):
                # 已删光自己所有 part 仍高于目标 → 剩余占用是业务/原有，工具管不了
                _log(
                    "trim_no_more used=%.1f%%>=target=%.1f%% 已删光自己所有part "
                    "(剩余占用为业务/原有，工具无法清理)" % (used, tgt))
                break
            freed = _trim_parts(path_prefix, parts, 1)
            used = disk_used_pct(out_dir)
            _log(
                "trim used=%.1f%%>=target=%.1f%% 删除1个part(%.0fMB)回落 "
                "remain_parts=%d used_after=%.1f%%" % (
                    used + 0.0, tgt, freed, len(parts), used))
            if not parts:
                _log(
                    "trim_all_removed used_after=%.1f%% 工具已删光全部part "
                    "(此后占用为业务/原有，工具不再参与)" % used)
        if used >= tgt:
            _log(
                "reach_target period=%s used=%.1f%% target=%.1f%% "
                "已删光自己part仍高于目标，停写（剩余为业务占用）"
                % (period, used, tgt))
            break
        # 已回落到位：停写驻留（used < target）
        _log(
            "reach_target period=%s used=%.1f%% target=%.1f%% "
            "写入到位，停写驻留 (不足目标会继续写，达到即停)"
            % (period, used, tgt))
        break

        # ── ② 逼近目标（slow_start 起）：线性降速（越近越慢）──────
        rate = cur_mbps
        slow_pct = slow_start * slow_ratio
        if slow_pct > 0 and used >= slow_pct:
            ratio = (tgt - used) / (tgt - slow_pct)
            if ratio < 0:
                ratio = 0.0
            if ratio > 1.0:
                ratio = 1.0
            rate = cur_mbps * ratio
            if rate < min_mbps:
                rate = min_mbps
            _log(
                "approach used=%.1f%% slow_from=%.1f%% ratio=%.2f rate=%dMB/s"
                % (used, slow_pct, ratio, int(rate)))

        # ── ③ CPU 联动：高则暂停/减半，降下来恢复 ───────────────
        busy = cpu_busy_pct()
        if busy >= cpu_max_busy:
            _log("cpu_busy=%.0f%%>=max=%d%% 暂停写入 %ds" % (busy, cpu_max_busy, watch_interval))
            time.sleep(watch_interval)
            continue
        if busy >= cpu_slow_busy:
            half = max(rate / 2.0, min_mbps)
            _log("cpu_busy=%.0f%%>=slow=%d%% 写速减半 %d->%dMB/s" % (busy, cpu_slow_busy, int(rate), int(half)))
            rate = half

        # ── ④ 估算本 part 大小：min(part_mb, 到目标的缺口, 保留线) ──
        _total, avail = fs_stat(out_dir)
        total_mb = _total / (1024.0 * 1024.0)
        avail_mb = avail / (1024.0 * 1024.0)
        used_mb = total_mb - avail_mb
        target_mb = total_mb * tgt / 100.0
        this_mb = target_mb - used_mb            # 到用户目标的缺口
        if this_mb <= 0:
            this_mb = 0.0
        if this_mb > part_mb:
            this_mb = part_mb
        # 目标 MB 显式约束（start <MB> 时 want_mb>0）
        if want_mb > 0:
            # 已写总量（parts 大小之和）+ 本 part ≤ want_mb
            written_now = sum(
                os.path.getsize(p) for p in parts if os.path.exists(p)) / (1024.0 * 1024.0)
            left_want = want_mb - written_now
            if left_want <= 0:
                _log("reach_mb want_mb=%d 已写满 停写驻留" % want_mb)
                break
            if this_mb > left_want:
                this_mb = left_want
        if this_mb <= 0:
            _log("no_gap used=%.1f%% target=%.1f%% 停写驻留" % (used, tgt))
            break

        # ── ⑤ 写一个 part ───────────────────────────────────────
        part_no += 1
        fpath = "%s.part%03d" % (path_prefix, part_no)
        step_t0 = time.time()
        wmb = _write_one_part(fpath, this_mb, content, fsync)
        parts.append(fpath)
        elapsed = time.time() - t0
        if elapsed <= 0:
            elapsed = 0.001
        rate_now = (sum(os.path.getsize(p) for p in parts) / (1024.0 * 1024.0)) / elapsed
        # ETA 预估：剩余缺口(到目标) / 当前实测速率（秒；写速为 0 时给 -1）
        gap_now_mb = target_mb - (total_mb - avail_mb)
        if gap_now_mb <= 0:
            gap_now_mb = 0.0
        eta_s = gap_now_mb / rate_now if rate_now > 0 else -1
        _log(
            "part%d mb=%d used=%.1f%% target=%.1f%% rate_mb_s=%.1f eta_s=%.0f "
            "file=%s" % (part_no, int(this_mb), disk_used_pct(out_dir), tgt,
                         rate_now, eta_s, fpath))
        # 限速（本 part 按 rate 限速）
        if rate > 0:
            need = float(this_mb) / float(rate)
            used_t = time.time() - step_t0
            if need > used_t:
                time.sleep(need - used_t)

        # ── ⑥ 每拍结束 sleep（监控间隔） ────────────────────────
        time.sleep(watch_interval)

    return parts


def main():
    want_mb = 0
    if len(sys.argv) > 1:
        try:
            want_mb = int(sys.argv[1])
        except Exception:
            want_mb = 0

    out_dir = os.environ.get("DISK_DIR", ".")
    part_mb_override = _env_int("DISK_PART_MB", PART_MB_AUTO)
    part_max_mb = _env_int("DISK_PART_MAX_MB", PART_MAX_MB_DEFAULT)
    content = os.environ.get("DISK_CONTENT", "text").strip().lower()
    reserve_pct = _env_int("DISK_RESERVE_PCT", RESERVE_PCT_DEFAULT)
    reserve_mb = _env_int("DISK_RESERVE_MB", RESERVE_MB_DEFAULT)
    reserve_abs_mb = _env_int("DISK_RESERVE_ABS_MB", RESERVE_ABS_MB_DEFAULT)
    write_mbps = _env_int("DISK_WRITE_MBPS", WRITE_MBPS_DEFAULT)
    fsync = _env_int("DISK_FSYNC", 0) == 1
    prefix = os.environ.get("DISK_PREFIX", "disk_fill")
    dynamic = _env_int("DISK_DYNAMIC", DYNAMIC_DEFAULT) == 1
    target_pct = _env_float("DISK_TARGET_PCT", TARGET_PCT_DEFAULT)
    slack_pct = _env_float("DISK_TARGET_SLACK_PCT", SLACK_PCT_DEFAULT)
    slow_ratio = _env_float("DISK_SLOW_RATIO", SLOW_RATIO_DEFAULT)
    trim_over = _env_int("DISK_TRIM_OVER", TRIM_OVER_DEFAULT) == 1
    watch_interval = _env_int("DISK_WATCH_INTERVAL", WATCH_INTERVAL_DEFAULT)
    cpu_max_busy = _env_int("DISK_CPU_MAX_BUSY", CPU_MAX_BUSY_DEFAULT)
    cpu_slow_busy = _env_int("DISK_CPU_SLOW_BUSY", CPU_SLOW_BUSY_DEFAULT)
    min_mbps = _env_int("DISK_MIN_MBPS", MIN_MBPS_DEFAULT)
    biz_target_pct = _env_float("DISK_TARGET_PCT_BIZ", 0)
    off_target_pct = _env_float("DISK_TARGET_PCT_OFF", 0)
    biz_mbps = _env_int("DISK_WRITE_MBPS_BIZ", 0)
    off_mbps = _env_int("DISK_WRITE_MBPS_OFF", 0)

    if content not in ("text", "binary"):
        content = "text"
    if reserve_pct < 0 or reserve_pct > 90:
        reserve_pct = RESERVE_PCT_DEFAULT
    if target_pct < 1 or target_pct > 99:
        target_pct = TARGET_PCT_DEFAULT
    # 分时目标占用率同样 clamp（防 export 99 逼近写满，绝对上限 99 但受三重保留兜底）
    if biz_target_pct < 1 or biz_target_pct > 99:
        biz_target_pct = 0
    if off_target_pct < 1 or off_target_pct > 99:
        off_target_pct = 0
    if slack_pct < 0 or slack_pct > 20:
        slack_pct = SLACK_PCT_DEFAULT
    if watch_interval < 1:
        watch_interval = WATCH_INTERVAL_DEFAULT
    if slow_ratio < 0.2 or slow_ratio > 1.0:
        slow_ratio = SLOW_RATIO_DEFAULT

    if not os.path.isdir(out_dir):
        sys.stderr.write("ERR 输出目录不存在: %s\n" % out_dir)
        sys.exit(1)

    # ── 删除/写入保护：DISK_DIR 命中 DISK_PROTECT_DIRS 保护目录则拒绝启动 ──
    # 防止有人把 DISK_DIR 设成 /、/data、/home 等业务目录后被误写/误删
    protect_raw = os.environ.get("DISK_PROTECT_DIRS", "").strip()
    if protect_raw:
        try:
            real_out = os.path.realpath(out_dir)
        except Exception:
            real_out = out_dir
        for p in protect_raw.split(","):
            p = p.strip()
            if not p:
                continue
            p = os.path.realpath(p.rstrip("/") or "/")
            if real_out == p or real_out.startswith(p + os.sep):
                sys.stderr.write(
                    "REFUSE start: DISK_DIR=%s 命中 DISK_PROTECT_DIRS 保护目录 %s\n"
                    "请把 DISK_DIR 指到专门用于压测的目录（如 /data/disk_test），"
                    "或确认后清空 DISK_PROTECT_DIRS 再执行\n" % (out_dir, p))
                sys.exit(1)

    _total, avail = fs_stat(out_dir)
    # 三重保留：比例 / 指定 MB / 绝对底线（即使前两者被调 0，也至少留 1GB，防写爆存储）
    reserve = max(int(avail * reserve_pct / 100.0),
                  reserve_mb * 1024 * 1024,
                  reserve_abs_mb * 1024 * 1024)
    max_mb = int((avail - reserve) / (1024.0 * 1024.0))
    if want_mb <= 0:
        want_mb = 0
    elif want_mb > max_mb:
        want_mb = max_mb

    if not dynamic:
        # ── 旧模式：一次性写入 ──────────────────────────────
        if want_mb <= 0:
            want_mb = max_mb
        if want_mb <= 0:
            sys.stderr.write(
                "已无可写空间（保留 %d%%/%dMB/绝对%dMB 后），跳过\n"
                % (reserve_pct, reserve_mb, reserve_abs_mb))
            sys.exit(0)
        part_mb = plan_part_mb(want_mb, part_mb_override, part_max_mb)
        sys.stderr.write(
            "plan mode=static want_mb=%d part_mb=%d content=%s write_mbps=%d dir=%s\n"
            % (want_mb, part_mb, content, write_mbps, out_dir))
        sys.stderr.flush()
        path_prefix = os.path.join(out_dir, prefix)
        write_target(path_prefix, want_mb, part_mb, content, write_mbps, fsync)
        sys.stderr.write("fill_done mb=%d\n" % int(want_mb))
        sys.stderr.flush()
        while True:
            time.sleep(3600)

    # ── 动态模式：动态规划 part + 闭环监管写入 ────────────────
    # part 规划基于「到目标占用率的缺口」估算目标 MB
    _total, avail = fs_stat(out_dir)
    total_mb = _total / (1024.0 * 1024.0)
    avail_mb = avail / (1024.0 * 1024.0)
    used_mb = total_mb - avail_mb
    est_target_mb = total_mb * target_pct / 100.0 - used_mb
    if want_mb > 0 and est_target_mb > want_mb:
        est_target_mb = want_mb
    est_target_mb = max(est_target_mb, 1)
    part_mb = plan_part_mb(est_target_mb, part_mb_override, part_max_mb)

    # 预估时长：缺口 MB / 目标写速 MB/s（写速 0=不限速则无法估算）
    est_seconds = -1
    if write_mbps > 0:
        est_seconds = est_target_mb / float(write_mbps)

    sys.stderr.write(
        "plan mode=dynamic want_mb=%d target_pct=%.1f%% slack=%.1f%% "
        "slow_start=%.1f%% est_gap=%dMB part_mb=%d "
        "content=%s write_mbps=%d slow_ratio=%.2f trim=%d watch=%ds "
        "cpu_max=%d cpu_slow=%d min_mbps=%d dir=%s\n"
        % (want_mb, target_pct, slack_pct, target_pct - slack_pct,
           int(est_target_mb), part_mb, content, write_mbps,
           slow_ratio, 1 if trim_over else 0, watch_interval,
           cpu_max_busy, cpu_slow_busy, min_mbps, out_dir))
    if est_seconds >= 0:
        est_min = est_seconds / 60.0
        sys.stderr.write(
            "eta_estimate est_gap=%dMB write_mbps=%d → 约 %d 秒（%.1f 分钟）"
            "（按目标写速粗算，实际随限速/CPU联动浮动）\n"
            % (int(est_target_mb), write_mbps, int(est_seconds), est_min))
    else:
        sys.stderr.write(
            "eta_estimate 写速不限速(DISK_WRITE_MBPS=0)，无法粗算；"
            "写盘中见 part 日志 eta_s=…\n")
    sys.stderr.flush()

    path_prefix = os.path.join(out_dir, prefix)
    parts = dynamic_fill(
        path_prefix, want_mb, part_mb, content, write_mbps, fsync,
        target_pct, slow_ratio, trim_over, watch_interval,
        cpu_max_busy, cpu_slow_busy, min_mbps,
        biz_target_pct, off_target_pct, biz_mbps, off_mbps, out_dir,
        slack_pct)

    sys.stderr.write(
        "fill_done parts=%d target_pct=%.1f%% used_now=%.1f%%\n"
        % (len(parts), target_pct, disk_used_pct(out_dir)))
    sys.stderr.flush()

    # ── 驻留：保持占用；持续监控，业务冲高 used% 时持续删 part 回落 ──
    # 高于目标 → 每拍删一个自己写的 part 并复测，直到低于目标或删光。
    while True:
        time.sleep(watch_interval)
        used = disk_used_pct(out_dir)
        while trim_over and parts and used >= target_pct:
            freed = _trim_parts(path_prefix, parts, 1)
            used = disk_used_pct(out_dir)
            sys.stderr.write(
                "dwell_trim used>=target(%.1f%%) 删除1part(%.0fMB)回落 "
                "remain_parts=%d used_after=%.1f%%\n"
                % (target_pct, freed, len(parts), used))
            if not parts:
                sys.stderr.write(
                    "dwell_trim_all_removed used_after=%.1f%% "
                    "已删光工具全部part（剩余为业务/原有占用）\n" % used)
            sys.stderr.flush()


if __name__ == "__main__":
    main()
