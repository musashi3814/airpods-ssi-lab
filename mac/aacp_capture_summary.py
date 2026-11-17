#!/usr/bin/env python3
"""Bluetooth キャプチャ(PacketLogger の .pklg / iOS の btsnoop)を AACP の opcode ごとに集計する。

要件 L1(装着状態テスト中に内向きマイクの音声が流れるか)と L2(ライブ翻訳で別のマイク構成が使われるか)を判定する。
tshark と apple-wireshark の Lua プラグイン(https://github.com/pabloaul/apple-wireshark)が必要。

使い方:
  python3 aacp_capture_summary.py capture.pklg                      # opcode ごとの総量
  python3 aacp_capture_summary.py capture.pklg --window 10 25        # 10〜25 秒の区間(テスト実行中)だけ
  python3 aacp_capture_summary.py capture.pklg --dump 0x58           # 0x58 の制御パケット(START など)を表示

判定の目安:
  - 装着状態テスト中に、イヤホン→ホスト方向で数 kB/s 以上流れる opcode があれば、音声ストリームの可能性が高い(L1 = あり)。
    0x58 以外の opcode なら、未知の音声経路として要調査。
  - テスト中に数十バイトのパケットが数個だけなら、計算はイヤホン内で完結している(L1 = なし)。
  - ライブ翻訳中の 0x58 START ペイロード(`--dump 0x58`)が通話時の 000182000000049600 と違えば、L2 = あり。
"""
from __future__ import annotations

import argparse
import collections
import csv
import shutil
import subprocess
import sys

FIELDS = ["frame.time_relative", "frame.len", "aacp.message_type", "aacp.type",
          "packetlogger.type", "hci_h4.direction", "btl2cap.payload"]


def rows_from_tshark(path: str):
    if not shutil.which("tshark"):
        sys.exit("tshark が見つからない(brew install wireshark)")
    cmd = ["tshark", "-r", path, "-Y", "aacp", "-T", "fields", "-E", "separator=,", "-E", "occurrence=f"]
    for f in FIELDS:
        cmd += ["-e", f]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(out.stderr)
    for line in out.stdout.splitlines():
        v = line.split(",")
        yield dict(zip(FIELDS, v + [""] * (len(FIELDS) - len(v))))


def direction(r) -> str:
    # PacketLogger: 0x02 = ACL 送信 (ホスト→イヤホン), 0x03 = ACL 受信。btsnoop: hci_h4.direction 0x00 送信 / 0x01 受信
    t = r.get("packetlogger.type", "").lower()
    if t in ("0x02", "2"):
        return "host→bud"
    if t in ("0x03", "3"):
        return "bud→host"
    d = r.get("hci_h4.direction", "").lower()
    if d in ("0x00", "0"):
        return "host→bud"
    if d in ("0x01", "1"):
        return "bud→host"
    return "?"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", help=".pklg / .btsnoop / .pcapng、または tshark の CSV 出力")
    ap.add_argument("--window", nargs=2, type=float, metavar=("T0", "T1"))
    ap.add_argument("--dump", help="この opcode (例 0x58) のパケットを全部表示")
    a = ap.parse_args()
    rows = list(csv.DictReader(open(a.capture))) if a.capture.endswith(".csv") else list(rows_from_tshark(a.capture))
    if a.window:
        rows = [r for r in rows if a.window[0] <= float(r["frame.time_relative"] or 0) <= a.window[1]]
    if not rows:
        sys.exit("AACP パケットがない(プラグインが読み込まれているか確認)")
    t = [float(r["frame.time_relative"]) for r in rows]
    span = max(t) - min(t) or 1.0
    agg = collections.defaultdict(lambda: [0, 0])
    for r in rows:
        k = (r.get("aacp.message_type") or r.get("aacp.type") or "?", direction(r))
        agg[k][0] += 1
        agg[k][1] += int(r["frame.len"] or 0)
    print(f"区間 {min(t):.1f}–{max(t):.1f} s ({span:.1f} s), AACP {len(rows)} パケット\n")
    print(f"{'opcode':>10} {'direction':>10} {'packets':>8} {'bytes':>9} {'B/s':>8}")
    for (op, d), (n, b) in sorted(agg.items(), key=lambda kv: -kv[1][1]):
        flag = "  ← 音声ストリームの可能性" if d == "bud→host" and b / span > 2000 else ""
        print(f"{op:>10} {d:>10} {n:>8} {b:>9} {b / span:>8.0f}{flag}")
    if a.dump:
        want = int(a.dump, 16)
        print(f"\n--- opcode {a.dump} ---")
        for r in rows:
            mt = r.get("aacp.message_type") or ""
            if mt and int(mt, 16) == want:
                print(f"{float(r['frame.time_relative']):9.3f} {direction(r):>9} len={r['frame.len']:>5} {r.get('btl2cap.payload', '')[:120]}")


if __name__ == "__main__":
    main()
