#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["av", "numpy", "scipy"]
# ///
"""Linux から AirPods の非公開プロトコル (AAP, L2CAP PSM 0x1001) を叩く実験ツール。

要件 L3 / L4 を確かめるためのもの(docs/requirements.md)。
⚠️ 実機では未検証。プロトコルのバイト列は以下の公開実装から取った:
   - マイク (opcode 0x58): superninjv/airpods-helper aap/src/mic.rs(元は LibrePods PR #655、AirPods Pro 3 で確認)
   - SensorDataWX (opcode 0x17): starman-tech/mousepods airpods_mouse_controller.py
   - ソケット設定 (BT_SECURITY, 受信 MTU 2582): mousepods l2cap.py

サブコマンド:
  hello      ハンドシェイクして、届いたパケットの opcode を一覧する
  mic        0x58 マイクを開始し、生の AU をタイムスタンプ付きで保存する(--payload で START を変えられる)
  decode     mic の保存ファイルを AAC-ELD としてデコードし WAV にする(既定 64 kHz)
  probe      プローブ WAV を A2DP で再生しながら mic を録り、そのまま decode する(L4)
  sensor     SensorDataWX の任意サービスを購読し、生パケットを保存する(L3: --service 17 = SPL0)
  fuzz-mode  START のモードバイト (既定 0x82) を順に変えて mic を録る(L4: マイク構成の切り替え探索)

前提: BlueZ でペアリング・接続済み。sudo か `setcap cap_net_raw,cap_net_admin+eip $(readlink -f $(which python3))`。
デコードには PyAV(FFmpeg の AAC-ELD デコーダ)を使う。
"""
from __future__ import annotations

import argparse
import json
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

PSM_AAP = 0x1001
SOL_BLUETOOTH, BT_SECURITY, BT_SECURITY_MEDIUM = 274, 4, 2
SOL_L2CAP, L2CAP_OPTIONS = 6, 1
IOS_MTU = 2582

H = bytes.fromhex
HANDSHAKE = H("00000400010002000000000000000000")
FEATURES = H("040004004d00ff00000000000000")
NOTIFICATIONS = H("040004000f00ffffffff")
HDR = H("04000400")

MIC_OP = 0x58
MIC_START_PAYLOAD = H("000182000000049600")   # 0x82 = Apple の "AAC-ELD-Stereo48K-10ms" と同じ値(偶然かもしれない)
MIC_STOP = H("040004005800000002000301")
ELD_ASC = H("F8E63000")                       # AOT39, 48k index, mono, 480 frame, no LD-SBR(実際は 64 kHz で届く)
AUDIO_HDR_LEN = 22

WX_PREFIX = H("04000400170000001000")
SVC = {"activity": 0x0E, "devmotion6": 0x10, "spl0": 0x11, "heartrate": 0x13}


def control(cmd: int, *vals: int) -> bytes:
    """制御コマンド (opcode 0x09)。例: control(0x0D, 1) = ListeningMode Off。"""
    v = list(vals) + [0] * (4 - len(vals))
    return HDR + bytes([0x09, 0x00, cmd]) + bytes(v[:4])


def open_aap(addr: str, timeout: float = 5.0) -> socket.socket:
    s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
    try:
        s.setsockopt(SOL_BLUETOOTH, BT_SECURITY, struct.pack("BB", BT_SECURITY_MEDIUM, 0))
        opts = bytearray(s.getsockopt(SOL_L2CAP, L2CAP_OPTIONS, 12))
        struct.pack_into("<H", opts, 2, IOS_MTU)   # imtu: 既定 672 だとセンサが announce されない
        s.setsockopt(SOL_L2CAP, L2CAP_OPTIONS, bytes(opts))
    except OSError as e:
        print(f"[warn] socket option: {e}", file=sys.stderr)
    s.settimeout(timeout)
    s.connect((addr, PSM_AAP))
    for p in (HANDSHAKE, FEATURES, NOTIFICATIONS):
        s.send(p)
        time.sleep(0.2)
    return s


def recv_for(s: socket.socket, seconds: float, on_packet) -> None:
    s.settimeout(0.2)
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            pkt = s.recv(4096)       # SEQPACKET は溢れた分を黙って捨てるので大きめに取る
        except socket.timeout:
            continue
        if pkt:
            on_packet(time.monotonic(), pkt)


def opcode(pkt: bytes) -> int | None:
    return pkt[4] if len(pkt) > 5 and pkt[:4] == HDR else None


# ---------------------------------------------------------------- hello

def cmd_hello(a):
    s = open_aap(a.addr)
    stats: dict[str, list[int]] = {}

    def on(t, p):
        k = f"0x{opcode(p):02X}" if opcode(p) is not None else f"raw:{p[:2].hex()}"
        stats.setdefault(k, []).append(len(p))
    recv_for(s, a.seconds, on)
    s.close()
    for k, v in sorted(stats.items()):
        print(f"{k}: {len(v)} packets, {sum(v)} bytes, lengths {sorted(set(v))[:8]}")


# ---------------------------------------------------------------- mic

def mic_capture(s: socket.socket, payload: bytes, seconds: float, out: Path, settle: float = 0.5) -> dict:
    """START を送り、0x58 音声パケットを [t_host, raw] で保存する。STOP は送らない(片耳化の不具合を避ける)。"""
    start = HDR + bytes([MIC_OP, 0, 0, 0]) + struct.pack("<H", len(payload)) + payload
    s.send(start)
    t0 = time.monotonic()
    n_audio = n_ctrl = 0
    frames = []

    def on(t, p):
        nonlocal n_audio, n_ctrl
        if opcode(p) != MIC_OP:
            return
        sub = struct.unpack_from("<H", p, 6)[0] if len(p) >= 8 else -1
        if sub == 0x0001:
            n_audio += 1
            frames.append((t - t0, p))
        else:
            n_ctrl += 1
            print(f"  ctrl 0x58: {p.hex()}")
    recv_for(s, seconds + settle, on)
    with out.open("wb") as f:
        for t, p in frames:
            f.write(struct.pack("<dI", t, len(p)) + p)
    return {"start": start.hex(), "audio_sdus": n_audio, "ctrl": n_ctrl, "seconds": seconds,
            "sdu_rate": n_audio / max(seconds, 1e-9)}


def iter_aus(path: Path):
    """保存ファイルから (t_host, au_timestamp, au_bytes) を取り出す。"""
    data = path.read_bytes()
    i = 0
    while i + 12 <= len(data):
        t, n = struct.unpack_from("<dI", data, i)
        p = data[i + 12:i + 12 + n]
        i += 12 + n
        j = AUDIO_HDR_LEN
        while j + 5 <= len(p):
            ts, ln = struct.unpack_from("<IB", p, j)
            j += 5
            if ln == 0 or j + ln > len(p):
                break
            yield t, ts, p[j:j + ln]
            j += ln


def cmd_mic(a):
    s = open_aap(a.addr)
    if a.anc_off:
        s.send(control(0x0D, 1))   # ListeningMode Off
    s.send(control(0x28, 2))       # 会話感知 Off(声で再生が絞られるのを防ぐ)
    if a.mic_side:
        s.send(control(0x01, {"auto": 0, "right": 1, "left": 2}[a.mic_side]))
    info = mic_capture(s, H(a.payload) if a.payload else MIC_START_PAYLOAD, a.seconds, Path(a.out))
    s.close()
    print(json.dumps(info, indent=2))


def decode(path: Path, fs: int, out: Path) -> dict:
    import av
    import numpy as np
    from scipy.io import wavfile
    codec = av.CodecContext.create("aac", "r")
    codec.extradata = ELD_ASC
    pcm, ts_list, errors = [], [], 0
    for _, ts, au in iter_aus(path):
        ts_list.append(ts)
        try:
            for fr in codec.decode(av.Packet(au)):
                pcm.append(fr.to_ndarray().reshape(-1).astype(np.float32))
        except av.error.FFmpegError:
            errors += 1
    x = np.concatenate(pcm) if pcm else np.zeros(0, np.float32)
    wavfile.write(out, fs, x)
    d = np.diff(ts_list) if len(ts_list) > 1 else []
    return {"aus": len(ts_list), "samples": int(len(x)), "decode_errors": errors, "fs_assumed": fs,
            "au_ts_step_median": float(np.median(d)) if len(d) else None,
            "au_ts_gaps": int((np.array(d) > 2 * np.median(d)).sum()) if len(d) else 0}


def cmd_decode(a):
    print(json.dumps(decode(Path(a.inp), a.fs, Path(a.out)), indent=2))


def cmd_probe(a):
    """A2DP シンクにプローブを流しながら mic を録る。再生は pw-play / paplay に任せる。"""
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    s = open_aap(a.addr)
    if a.anc_off:
        s.send(control(0x0D, 1))
    s.send(control(0x28, 2))
    player = None
    for cmd in (["pw-play", a.wav], ["paplay", a.wav]):
        try:
            player = subprocess.Popen(cmd)
            break
        except FileNotFoundError:
            continue
    if player is None:
        sys.exit("pw-play / paplay が見つからない")
    info = mic_capture(s, H(a.payload) if a.payload else MIC_START_PAYLOAD, a.seconds, out / "mic.bin")
    player.wait()
    s.close()
    info["decode"] = decode(out / "mic.bin", a.fs, out / "mic.wav")
    (out / "info.json").write_text(json.dumps(info, indent=2))
    print(json.dumps(info, indent=2))
    print(f"\n次: uv run --script analysis/probe.py analyze --rec {out/'mic.wav'} --out {out/'probe'}")


# ---------------------------------------------------------------- sensor

def wx_packet(seq: int, svc: int, interval_us: int) -> bytes:
    body = bytes([0x08, seq & 0x7F, 0x42, 0x0B, 0x08, svc, 0x10, 0x02, 0x1A, 0x05, 0x01]) + struct.pack("<I", interval_us)
    return WX_PREFIX + struct.pack("<H", len(body)) + body


def cmd_sensor(a):
    s = open_aap(a.addr)
    svc = SVC.get(a.service, None) if not a.service.isdigit() else int(a.service)
    if svc is None:
        sys.exit(f"unknown service {a.service}")
    s.send(wx_packet(1, SVC["activity"], 40000))
    time.sleep(0.25)
    s.send(wx_packet(2, svc, a.interval_us))
    pkts = []
    recv_for(s, a.seconds, lambda t, p: pkts.append((t, p)) if p[:10] == WX_PREFIX else None)
    s.send(wx_packet(3, svc, 0))
    s.close()
    out = Path(a.out)
    out.write_text("\n".join(f"{t:.6f} {p.hex()}" for t, p in pkts) + "\n")
    lens = sorted({len(p) for _, p in pkts})
    span = (pkts[-1][0] - pkts[0][0]) if len(pkts) > 1 else 0
    print(json.dumps({"service": svc, "packets": len(pkts), "rate_hz": len(pkts) / span if span else None,
                      "lengths": lens[:12], "saved": str(out)}, indent=2))
    print("SPL0 の解釈: 耳を手で塞ぐ・ハミングする・外来音を流すなどで値が変わるバイトを探す。")


# ---------------------------------------------------------------- fuzz-mode

def cmd_fuzz(a):
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    lo, hi = (int(v, 0) for v in a.range.split("-"))
    results = []
    for mode in range(lo, hi + 1):
        payload = bytearray(MIC_START_PAYLOAD)
        payload[2] = mode
        print(f"== mode 0x{mode:02X}")
        try:
            s = open_aap(a.addr)
            info = mic_capture(s, bytes(payload), a.seconds, out / f"mode_{mode:02X}.bin")
            s.close()
            if info["audio_sdus"]:
                info["decode"] = decode(out / f"mode_{mode:02X}.bin", a.fs, out / f"mode_{mode:02X}.wav")
        except OSError as e:
            info = {"error": str(e)}
        info["mode"] = mode
        results.append(info)
        time.sleep(a.pause)
    (out / "fuzz.json").write_text(json.dumps(results, indent=2))
    for r in results:
        print(f"0x{r['mode']:02X}: sdus={r.get('audio_sdus')} err={r.get('error', '')}")
    print("音が出たモードの WAV を、E3 と同じ手順(ANC 切替・ハミング)で比べると、マイク構成の違いが分かる。")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--addr", required=True, help="AirPods の BD アドレス (bluetoothctl devices)")
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("hello"); p.add_argument("--seconds", type=float, default=5)
    p = sp.add_parser("mic")
    p.add_argument("--seconds", type=float, default=10)
    p.add_argument("--out", default="mic.bin")
    p.add_argument("--payload", help="START ペイロード (hex)。既定 000182000000049600")
    p.add_argument("--anc-off", action="store_true")
    p.add_argument("--mic-side", choices=["auto", "left", "right"])
    p = sp.add_parser("decode"); p.add_argument("inp"); p.add_argument("--out", default="mic.wav"); p.add_argument("--fs", type=int, default=64000)
    p = sp.add_parser("probe")
    p.add_argument("--wav", required=True, help="analysis/probe.py gen で作った WAV")
    p.add_argument("--seconds", type=float, default=11)
    p.add_argument("--out", default="probe_run")
    p.add_argument("--payload")
    p.add_argument("--fs", type=int, default=64000)
    p.add_argument("--anc-off", action="store_true")
    p = sp.add_parser("sensor")
    p.add_argument("--service", default="spl0", help="spl0 / devmotion6 / heartrate / 数値")
    p.add_argument("--interval-us", type=int, default=40000)
    p.add_argument("--seconds", type=float, default=10)
    p.add_argument("--out", default="sensor.txt")
    p = sp.add_parser("fuzz-mode")
    p.add_argument("--range", default="0x80-0x8F")
    p.add_argument("--seconds", type=float, default=4)
    p.add_argument("--pause", type=float, default=2)
    p.add_argument("--fs", type=int, default=64000)
    p.add_argument("--out", default="fuzz")
    a = ap.parse_args()
    {"hello": cmd_hello, "mic": cmd_mic, "decode": cmd_decode, "probe": cmd_probe,
     "sensor": cmd_sensor, "fuzz-mode": cmd_fuzz}[a.cmd](a)


if __name__ == "__main__":
    main()
