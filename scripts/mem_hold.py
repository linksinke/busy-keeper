#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
mem_hold.py — 申请并触摸内存页，抬高 RSS（真实占内存）。

版本   : 1.0.0
许可证 : MIT
兼容   : Python 2 / 3。由 mem_stress_ctl.sh 按安全策略传入目标 MB。

用法:
  python2 mem_hold.py <MB>
  python2 mem_hold.py 8192

环境变量（可选）:
  MEM_CHUNK_MB      强制分片大小（MB）；0/空=按目标自适应规划
  MEM_ALLOC_MBPS    申请速率上限 MB/s；默认 512 限速；0=不限速（尽快分块）
  MEM_CHUNK_MAX_MB  自适应分片上限，默认 1024（防单块过大申请失败）

实现要点:
  - 按目标规划分片（小目标细、大目标粗，默认封顶 1GB/块），避免固定 64MB 导致万级对象；
  - 每隔 4096 字节写 1，强制提交物理页；
  - 可选限速 + 打印 ETA；达量后 sleep 驻留，stop/退出由 OS 回收。
"""

from __future__ import print_function

import os
import sys
import time


def _env_int(name, default):
    raw = os.environ.get(name, "")
    if raw is None or str(raw).strip() == "":
        return default
    try:
        return int(raw)
    except Exception:
        return default


def plan_chunk_mb(target_mb, override_mb, max_mb):
    """按目标规划分片：约控制在数十块量级，单块不超过 max_mb。"""
    target_mb = int(target_mb)
    max_mb = int(max_mb)
    if max_mb < 16:
        max_mb = 16
    if override_mb and override_mb > 0:
        n = override_mb
        if n > max_mb:
            n = max_mb
        if n > target_mb:
            n = target_mb
        if n < 1:
            n = 1
        return n
    if target_mb <= 0:
        return 64
    # 目标分片数约 32～64：块太小→对象多/慢；太大→单次申请易失败、降载粒度粗
    if target_mb <= 128:
        n = min(32, target_mb)
    elif target_mb <= 1024:
        n = 128
    elif target_mb <= 4096:
        n = 256
    elif target_mb <= 16384:
        n = 512
    else:
        n = 1024
    if n > max_mb:
        n = max_mb
    if n > target_mb:
        n = target_mb
    if n < 1:
        n = 1
    return n


def hold_mb(target_mb):
    target_mb = int(target_mb)
    override = _env_int("MEM_CHUNK_MB", 0)
    max_chunk = _env_int("MEM_CHUNK_MAX_MB", 1024)
    alloc_mbps = _env_int("MEM_ALLOC_MBPS", 0)
    chunk_mb = plan_chunk_mb(target_mb, override, max_chunk)

    chunks = []
    held = 0
    page = 4096
    t0 = time.time()

    if target_mb <= 0:
        while True:
            time.sleep(3600)

    n_est = (target_mb + chunk_mb - 1) // chunk_mb
    sys.stderr.write(
        "plan target_mb=%d chunk_mb=%d chunks≈%d alloc_mbps=%d max_chunk=%d\n"
        % (target_mb, chunk_mb, n_est, alloc_mbps, max_chunk)
    )
    sys.stderr.flush()

    while held < target_mb:
        step_t0 = time.time()
        n = chunk_mb
        if target_mb - held < chunk_mb:
            n = target_mb - held
        buf = bytearray(n * 1024 * 1024)
        i = 0
        length = len(buf)
        while i < length:
            buf[i] = 1
            i += page
        chunks.append(buf)
        held += n

        elapsed = time.time() - t0
        if elapsed <= 0:
            elapsed = 0.001
        rate = held / elapsed
        remain = target_mb - held
        if rate > 0:
            eta = remain / rate
        else:
            eta = -1
        sys.stderr.write(
            "held_mb=%d/%d chunk=%d rate_mb_s=%.1f eta_s=%.0f\n"
            % (held, target_mb, n, rate, eta)
        )
        sys.stderr.flush()

        # 限速：本块耗时不足则补 sleep（不在 touch 环里插，保证页已提交）
        if alloc_mbps > 0 and n > 0:
            need = float(n) / float(alloc_mbps)
            used = time.time() - step_t0
            if need > used:
                time.sleep(need - used)

    sys.stderr.write(
        "hold_done target_mb=%d chunks=%d elapsed_s=%.1f\n"
        % (target_mb, len(chunks), time.time() - t0)
    )
    sys.stderr.flush()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    mb = 1024
    if len(sys.argv) > 1:
        try:
            mb = int(sys.argv[1])
        except Exception:
            mb = 1024
    hold_mb(mb)
