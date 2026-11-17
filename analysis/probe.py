# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "scipy", "matplotlib"]
# ///
"""AirPods マイク経路が「アクティブ音響センシングに使えるか」を判定するための probe。

ハードウェア実験 (README の Step 1) で使う。2 つのサブコマンドがある。

  gen     : 再生用 wav を作る (無音 → 対数スイープ → 無音 → 超音波チャープの繰り返し)
  analyze : AirPods マイクで同時録音した wav を解析し、以下を数値で出す
            (a) 帯域: 16/20/24/28 kHz 以上にプローブ由来のエネルギーが残っているか
            (b) エコー除去: 繰り返しチャープの整合フィルタ出力に明確なピークが立つか
            (c) チャネル応答の時間変動: フレームごとのインパルス応答 (無動作と口パクで比較する)

使い方:
  uv run --script probe.py gen --out out/probe.wav   # Linux 実験用(iOS アプリは自前で生成)
  # AirPods で out/probe.wav を再生しつつ、0x58 経路のマイクを 64 kHz で録音 → rec.wav
  uv run --script probe.py analyze --rec rec.wav --out out/still
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from scipy.io import wavfile
from scipy.signal import chirp, correlate, resample_poly, stft

PLAY_FS = 48_000
# 区間長 [s]。iOS アプリ (ProbeSignal.swift) の E2 と同じ構成:
# 無音 LEAD → 対数スイープ → 無音 GAP → チャープ列 → 無音 TAIL
LEAD_S, SWEEP_S, GAP_S, TAIL_S = 1.0, 1.5, 0.5, 1.0
SILENCE_S = GAP_S
CHIRP_N = 2048          # HEar-ID と同程度 (~42 ms @ 48 kHz)
CHIRP_F0, CHIRP_F1 = 17_500, 23_000
CHIRP_REPEAT_S = 6.0


def sweep_signal(fs: float, f_end: float | None = None) -> np.ndarray:
    f_end = f_end or 0.47 * fs
    t = np.arange(int(SWEEP_S * fs)) / fs
    return chirp(t, f0=100, t1=SWEEP_S, f1=f_end, method="logarithmic")


def chirp_frame(fs: int) -> np.ndarray:
    n = int(round(CHIRP_N * fs / PLAY_FS))
    t = np.arange(n) / fs
    x = chirp(t, f0=CHIRP_F0, t1=t[-1], f1=CHIRP_F1, method="linear")
    return x * np.hanning(n)


def cmd_gen(a: argparse.Namespace) -> None:
    amp = 10 ** (a.level_dbfs / 20)
    z = lambda s: np.zeros(int(s * PLAY_FS))
    reps = int(CHIRP_REPEAT_S * PLAY_FS / CHIRP_N)
    x = np.concatenate([z(LEAD_S), sweep_signal(PLAY_FS), z(GAP_S), np.tile(chirp_frame(PLAY_FS), reps), z(TAIL_S)]) * amp
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    wavfile.write(out, PLAY_FS, np.stack([x, x], 1).astype(np.float32))
    print(f"wrote {out}  ({len(x) / PLAY_FS:.1f} s, {a.level_dbfs} dBFS, stereo 48 kHz)")


def load_mono(path: str) -> tuple[int, np.ndarray]:
    fs, raw = wavfile.read(path)
    x = raw.astype(np.float64)
    if np.issubdtype(raw.dtype, np.integer):
        x /= np.iinfo(raw.dtype).max
    if x.ndim > 1:
        x = x.mean(1)
    return fs, x


def band_db(seg: np.ndarray, fs: int, lo: float, hi: float) -> float:
    f, _, Z = stft(seg, fs=fs, nperseg=2048)
    p = (np.abs(Z) ** 2).mean(1)
    m = (f >= lo) & (f < hi)
    return float(10 * np.log10(p[m].mean() + 1e-20)) if m.any() else float("nan")


def cmd_analyze(a: argparse.Namespace) -> None:
    fs, x = load_mono(a.rec)
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    rep: dict = {"rec_fs": fs, "duration_s": len(x) / fs}
    if fs < 46_000:
        rep["warning"] = f"録音 fs={fs} Hz では 17.5–23 kHz を表現できない (HFP 経路の可能性)"

    # スイープ開始位置を相関で特定(録音開始のずれ・経路遅延を吸収)。
    # 再生側 fs (--play-fs) のスイープのうち、録音 fs で表現できる部分だけをテンプレートにする
    f_end = 0.47 * max(a.play_fs, fs)
    sw = sweep_signal(fs, f_end)
    fc = min(0.4 * fs, f_end)
    tcut = SWEEP_S * np.log(fc / 100) / np.log(f_end / 100)
    c = np.abs(correlate(x, sw[: max(256, int(tcut * fs))], mode="valid", method="fft"))
    s0 = int(np.argmax(c))
    rep["sweep_start_s"] = s0 / fs
    noise = x[max(0, s0 - int(0.9 * fs)): max(1, s0 - int(0.1 * fs))]
    sweep = x[s0: s0 + len(sw)]

    # (a) 帯域: スイープ区間と直前無音のバンドエネルギー差
    edges = [(1e3, 8e3), (8e3, 16e3), (16e3, 20e3), (20e3, 24e3), (24e3, 28e3), (28e3, fs / 2)]
    rep["band_snr_db"] = {
        f"{int(lo / 1e3)}-{int(hi / 1e3)}k": round(band_db(sweep, fs, lo, hi) - band_db(noise, fs, lo, hi), 1)
        for lo, hi in edges if lo < fs / 2
    }

    # (b) 繰り返しチャープの整合フィルタ。フレーム周期で畳み込み、ピーク/中央値比を見る
    cf = chirp_frame(fs)
    period = len(cf)
    c0 = s0 + len(sw) + int(SILENCE_S * fs)
    body = x[c0: c0 + int(CHIRP_REPEAT_S * fs)]
    nfr = len(body) // period - 1
    mf = correlate(body, cf, mode="valid", method="fft")
    frames = np.stack([mf[i * period: (i + 1) * period] for i in range(nfr)])
    env = np.abs(frames)
    peak_ratio = float(np.median(env.max(1) / (np.median(env, 1) + 1e-20)))
    rep["chirp_matched_filter_peak_to_median"] = round(peak_ratio, 1)
    rep["chirp_band_snr_db"] = round(band_db(body, fs, CHIRP_F0, CHIRP_F1) - band_db(noise, fs, CHIRP_F0, CHIRP_F1), 1)

    # (c) チャネル応答の時間変動。直達ピークに揃え、その後 ~3 ms(耳道内反射の範囲)を切り出す
    lag = int(np.median(env.argmax(1)))
    win = int(0.003 * fs)
    cir = np.stack([frames[i, lag: lag + win] for i in range(nfr)]) if lag + win <= period else env[:, :win]
    cir = cir / (np.abs(cir[:, :1]) + 1e-20)
    diff = np.abs(np.diff(cir, axis=0)).mean(1)
    rep["cir_frame_diff_median"] = float(np.median(diff))
    rep["cir_frame_diff_p95"] = float(np.percentile(diff, 95))
    np.save(out.with_suffix(".cir.npy"), cir)

    rep["verdict_hint"] = {
        "bandwidth_ok": rep["band_snr_db"].get("20-24k", -99) > 10,
        "probe_not_cancelled": peak_ratio > 10 and rep["chirp_band_snr_db"] > 10,
    }
    out.with_suffix(".json").write_text(json.dumps(rep, ensure_ascii=False, indent=2))
    print(json.dumps(rep, ensure_ascii=False, indent=2))

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(2, 1, figsize=(8, 6))
        f, t, Z = stft(x, fs=fs, nperseg=1024)
        ax[0].pcolormesh(t, f / 1e3, 20 * np.log10(np.abs(Z) + 1e-9), shading="auto", vmin=-120)
        ax[0].set(ylabel="kHz", title="Recording spectrogram")
        ax[1].imshow(20 * np.log10(np.abs(cir).T + 1e-9), aspect="auto", origin="lower",
                     extent=[0, nfr * period / fs, 0, win / fs * 1e3])
        ax[1].set(xlabel="s", ylabel="delay [ms]", title="Echo profile per chirp frame")
        fig.tight_layout()
        fig.savefig(out.with_suffix(".png"), dpi=120)
    except Exception as e:  # 図は補助。失敗しても数値は出す
        print(f"plot skipped: {e}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = p.add_subparsers(dest="cmd", required=True)
    g = sp.add_parser("gen")
    g.add_argument("--out", default="out/probe.wav")
    g.add_argument("--level-dbfs", type=float, default=-30.0, help="安全のため低音量から始める")
    an = sp.add_parser("analyze")
    an.add_argument("--rec", required=True, help="AirPods マイクの録音 wav (64 kHz 想定)")
    an.add_argument("--out", default="out/result")
    an.add_argument("--play-fs", type=float, default=48_000, help="再生側のサンプリング周波数")
    a = p.parse_args()
    {"gen": cmd_gen, "analyze": cmd_analyze}[a.cmd](a)


if __name__ == "__main__":
    main()
