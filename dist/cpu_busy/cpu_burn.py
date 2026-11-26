#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
cpu_burn.py — 单进程忙等，约占用 1 个逻辑 CPU。

版本   : 1.0.0
许可证 : MIT
兼容   : Python 2 / 3。由 cpu_stress_ctl.sh 拉起多个实例以达到整机目标利用率。

用法:
  python2 cpu_burn.py           # soft=0，全力烧
  python2 cpu_burn.py 0.01      # 每轮忙等后 sleep 0.01 秒，降低单核占空比

参数:
  argv[1]  soft (float, 秒)  — 每轮循环末尾 sleep；0 或不传表示不 sleep。
                               soft 过大（如 0.08+）会导致整机很难到 30%。

说明:
  内层 xrange(200000) 做整数运算制造 CPU 负载；勿在本脚本里申请大内存
  （内存占用由 mem_hold.py 单独负责，避免 OOM 连带拖垮 CPU 压测）。
"""

import sys
import time

try:
    _range = xrange
except NameError:  # Python 3
    _range = range


def main():
    soft = 0.0
    if len(sys.argv) > 1:
        try:
            soft = float(sys.argv[1])
        except Exception:
            soft = 0.0
    while True:
        x = 0
        for i in _range(200000):
            x += i * i
        if soft > 0:
            time.sleep(soft)


if __name__ == "__main__":
    main()
