"""PC 侧 BLE 推送工具：固件的验收脚本，也是 app 侧协议的参照实现。

    tools/.venv-ble/Scripts/python.exe tools/ble_push.py            # 只推词表
    tools/.venv-ble/Scripts/python.exe tools/ble_push.py --audio     # 再抓有道英式发音一起推

音频必须先按文件头魔数判容器：有道的 Content-Type 对 RIFF/WAVE 也报 audio/mpeg。
"""

import argparse
import asyncio
import json
import struct
import sys
import time
import urllib.parse
import urllib.request
import zlib

from bleak import BleakClient, BleakScanner

DEVICE_NAME = "WORDCARD"
BASE = "0000{0:04x}-0000-1000-8000-00805f9b34fb"
CH_CMD = BASE.format(0xFFE1)
CH_NTF = BASE.format(0xFFE2)
CH_DATA = BASE.format(0xFFE3)

YOUDAO_AUDIO = "https://dict.youdao.com/dictvoice?type=1&audio=%s"
FRAME_HEADER = 10
USER_AGENT = "Mozilla/5.0 (wordcard-sync)"


def load_words(path):
    rows = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            fields += [""] * (4 - len(fields))
            rows.append(fields[:4])
    return rows


def detect_format(body):
    if body[:4] == b"RIFF":
        return "wav"
    if body[:3] == b"ID3":
        return "mp3"
    if len(body) > 3 and body[0] == 0xFF and (body[1] & 0xE0) == 0xE0:
        return "mp3"
    return None


def fetch_audio(word):
    url = YOUDAO_AUDIO % urllib.parse.quote(word)
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=15) as response:
        body = response.read()
    fmt = detect_format(body)
    if fmt is None:
        raise ValueError("认不出容器格式")
    return fmt, body


class Pusher:
    def __init__(self, verbose=False):
        self.replies = []
        self.wb_done = asyncio.Event()
        self.verbose = verbose

    def on_notify(self, _, data):
        try:
            msg = json.loads(data.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            print("  设备回了不是 JSON 的东西:", data[:40])
            return
        self.replies.append(msg)
        if msg.get("t") == "wb_done":
            self.wb_done.set()
        if msg.get("t") == "error" or self.verbose:
            print("  <-", msg)

    async def push(self, words, audio, chunk):
        client = self.client

        async def cmd(payload):
            raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            if len(raw) > chunk:
                raise ValueError("命令超过单条写入上限 %d 字节: %s" % (chunk, payload.get("w")))
            await client.write_gatt_char(CH_CMD, raw, response=True)

        await cmd({"t": "wb_begin", "n": len(words), "v": time.strftime("%Y%m%d-%H%M%S")})
        started = time.monotonic()
        for word, phonetic, meaning, example in words:
            await cmd({"t": "wb_word", "w": word, "p": phonetic, "m": meaning, "s": example})
        await cmd({"t": "wb_end"})
        try:
            await asyncio.wait_for(self.wb_done.wait(), timeout=10)
        except asyncio.TimeoutError:
            raise SystemExit("设备没回 wb_done，看它屏幕上的错误")
        elapsed = time.monotonic() - started
        print("词表 %d 条用了 %.2fs（%.0f 条/秒）" % (len(words), elapsed, len(words) / elapsed))

        total_bytes = 0
        started = time.monotonic()
        for word, body in audio.items():
            fmt = body[0]
            data = body[1]
            await cmd({"t": "au_begin", "w": word, "fmt": fmt, "len": len(data),
                       "crc32": zlib.crc32(data) & 0xFFFFFFFF})
            for offset in range(0, len(data), chunk - FRAME_HEADER):
                payload = data[offset:offset + chunk - FRAME_HEADER]
                flags = (1 if offset == 0 else 0) | (
                    2 if offset + len(payload) >= len(data) else 0)
                frame = (b"\xa5\x5a\x01" + bytes([flags])
                         + struct.pack("<I", offset) + struct.pack("<H", len(payload))
                         + payload)
                await client.write_gatt_char(CH_DATA, frame, response=True)
            await cmd({"t": "au_end"})
            total_bytes += len(data)
            print("  发音 %-10s %s %6.1f KB" % (word, fmt, len(data) / 1024))
        elapsed = time.monotonic() - started
        if audio:
            print("音频 %d 个 / %.1f KB 用了 %.1fs（%.1f KB/s）"
                  % (len(audio), total_bytes / 1024, elapsed, total_bytes / 1024 / elapsed))

        await cmd({"t": "stat"})
        await asyncio.sleep(0.5)


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--words", default="data/words.tsv")
    parser.add_argument("--audio", action="store_true", help="从有道抓英式发音再推")
    parser.add_argument("--limit", type=int, default=0, help="只推前 N 个词的音频")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    rows = load_words(args.words)
    if not rows:
        raise SystemExit("词表是空的")

    audio = {}
    if args.audio:
        targets = rows[:args.limit] if args.limit else rows
        for row in targets:
            word = row[0]
            try:
                fmt, body = fetch_audio(word)
            except Exception as error:  # 某词失败不阻塞整批，和设备侧策略一致
                print("  抓不到 %s: %s" % (word, error))
                continue
            audio[word] = (fmt, body)
        print("抓到 %d/%d 个发音" % (len(audio), len(targets)))

    device = await BleakScanner.find_device_by_name(DEVICE_NAME, timeout=20)
    if device is None:
        raise SystemExit("扫不到 WORDCARD：确认设备已开机（单击 PWR）并在广播")

    pusher = Pusher(args.verbose)
    async with BleakClient(device) as client:
        # Windows 上 MTU 由系统协商，不像 app 能自己 requestMtu(512)，所以按实测值算。
        chunk = min(client.mtu_size - 3, 500)
        print("已连接 %s  MTU=%d  单条上限=%d" % (client.address, client.mtu_size, chunk))
        await client.start_notify(CH_NTF, pusher.on_notify)
        pusher.client = client
        await pusher.push(rows, audio, chunk)
        await client.stop_notify(CH_NTF)

    errors = [m for m in pusher.replies if m.get("t") == "error"]
    print("设备回了 %d 条错误" % len(errors))
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
