#!/usr/bin/env python3
"""把 storage 分区的原始 dump 里那些定长放电记录扫出来，写成 CSV。

storage 分区挂的是 wear-levelling 的 FAT（flash-wordbook.ps1 用 wl_fatfsgen.py 生成镜像），
物理布局是按扇区重排过的，不是普通 FAT16 镜像，所以这里不解析文件系统：
main/app/batterylog.cc 每条记录都带 magic + seq + checksum，直接在字节流里认。
wear levelling 会在日志区留下同一逻辑扇区的旧副本，所以按 (boot, seq) 去重。

用法：
    python parse-battery-log.py build\\battery-dump.bin -o battery-log.csv
"""

import argparse
import re
import struct
import sys

RECORD = struct.Struct("<4sIIIHBB8sI")
MAGIC = b"WCB1"
FLAG_WARN = 1 << 0
FLAG_DEAD = 1 << 1


def scan(data: bytes):
    found = {}
    bad = 0
    for match in re.finditer(MAGIC, data):
        off = match.start()
        if off + RECORD.size > len(data):
            continue
        _magic, seq, boot, uptime, mv, pct, flags, _reserved, cks = RECORD.unpack_from(data, off)
        head = struct.unpack_from("<7I", data, off)
        if sum(head) & 0xFFFFFFFF != cks:
            bad += 1
            continue
        found.setdefault((boot, seq), (off, uptime, mv, pct, flags))
    return found, bad


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dump", help="esptool read_flash 0x800000 0x800000 出来的原始镜像")
    parser.add_argument("-o", "--out", default="battery-log.csv", help="输出的 CSV 路径")
    args = parser.parse_args()

    with open(args.dump, "rb") as handle:
        data = handle.read()

    found, bad = scan(data)
    if not found:
        print("没找到任何记录。设备跑过至少一分钟、且 storage 分区挂载成功才会有。", file=sys.stderr)
        return 1

    # 按 boot 分段：一次开机是一段连续 seq。换过词表（重烧 storage 分区）会把文件清空、
    # seq 从 0 重新开始，那时靠 boot 随机数区分两段。
    segments = {}
    for (boot, seq), value in found.items():
        segments.setdefault(boot, []).append((seq, value))

    ordered = sorted(segments.items(), key=lambda item: min(v[0] for _, v in item[1]))

    rows = []
    for boot, records in ordered:
        for seq, (_off, uptime, mv, pct, flags) in sorted(records):
            rows.append((boot, seq, uptime, mv, pct, bool(flags & FLAG_WARN), bool(flags & FLAG_DEAD)))

    with open(args.out, "w", encoding="utf-8", newline="") as handle:
        handle.write("boot_nonce,seq,uptime_s,millivolts,percent,warn,dead\n")
        for row in rows:
            handle.write("{},{},{},{},{},{},{}\n".format(*row))

    volts = [row[3] for row in rows]
    print(f"记录 {len(rows)} 条，boot 段 {len(ordered)} 个，校验不通过的候选 {bad} 个")
    print(f"电压范围 {min(volts)} ~ {max(volts)} mV  ->  {args.out}")
    print("把这份 CSV 和万用表同时刻的实测电压一起给我，就能反推分压比和 ADC 的增益误差。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
