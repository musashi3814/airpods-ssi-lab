# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "scipy"]
# ///
"""iOS アプリの E5(単語情報の検定)の記録を、オフラインで再解析する。

アプリと同じ 1-NN DTW + leave-one-out + 置換検定を、モダリティごとに計算する。
アプリ上の結果を確認するほか、特徴量や窓を変えて試すための土台として使う。

使い方:
  uv run --script e5_analyze.py <Runs/..._E5 ディレクトリ> [--perm 1000] [--modality imu passive active]
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np
from scipy.io import wavfile
from scipy.signal import correlate, stft

CHIRP_DUR = 2048 / 48_000
BANDS = {"ultrasonic": (17_500, 23_000), "nearUltra": (15_000, 20_000), "audible": (4_000, 8_000)}


def load(run: Path):
    fs, audio = wavfile.read(run / "audio.wav")
    audio = audio.astype(np.float64)
    trials = list(csv.DictReader(open(run / "trials.csv")))
    motion = list(csv.DictReader(open(run / "motion.csv"))) if (run / "motion.csv").exists() else []
    meta = json.loads((run / "meta.json").read_text()) if (run / "meta.json").exists() else {}
    return fs, audio, trials, motion, meta


def imu_features(motion, t0, t1, rate=50.0):
    rows = [r for r in motion if t0 - 0.1 <= float(r["t"]) <= t1 + 0.1]
    if len(rows) < 3:
        return None
    t = np.array([float(r["t"]) for r in rows])
    keys = ["ax", "ay", "az", "gx", "gy", "gz", "roll", "pitch", "yaw"]
    X = np.array([[float(r[k]) for k in keys] for r in rows])
    X[:, 6:] -= X[0, 6:]
    grid = t0 + np.arange(max(2, int((t1 - t0) * rate))) / rate
    return np.stack([np.interp(grid, t, X[:, j]) for j in range(X.shape[1])], 1)


def passive_features(x, fs):
    nper = 1 << int(np.ceil(np.log2(0.04 * fs)))
    hop = int(0.02 * fs)
    if len(x) <= nper + hop:
        return None
    f, _, Z = stft(x, fs=fs, nperseg=nper, noverlap=nper - hop, boundary=None, padded=False)
    P = np.abs(Z) ** 2
    edges = 100 * (min(8000, 0.47 * fs) / 100) ** (np.arange(17) / 16)
    feats = [np.log10(P[(f >= lo) & (f < hi)].mean(0) + 1e-12) for lo, hi in zip(edges[:-1], edges[1:])]
    return np.stack(feats, 1)


def echo_features(x, fs, band):
    lo, hi = BANDS[band]
    if hi >= 0.49 * fs:
        return None
    n = int(round(CHIRP_DUR * fs))
    t = np.arange(n) / fs
    T = n / fs
    ch = np.sin(2 * np.pi * (lo * t + (hi - lo) / (2 * T) * t * t)) * np.hanning(n)
    mf = correlate(x, ch, mode="valid", method="fft")
    period = CHIRP_DUR * fs
    nfr = int(len(mf) / period) - 1
    if nfr < 3:
        return None
    bounds = [(int(round(i * period)), int(round((i + 1) * period))) for i in range(nfr)]
    lag = int(np.median([np.argmax(np.abs(mf[a:b])) for a, b in bounds]))
    win = max(24, int(0.003 * fs))
    out = []
    for a, _ in bounds:
        a += lag
        if a + win > len(mf):
            break
        prof = np.abs(mf[a:a + win]) / max(abs(mf[a]), 1e-9)
        out.append([prof[d * win // 24:max(d * win // 24 + 1, (d + 1) * win // 24)].mean() for d in range(24)])
    return np.array(out) if out else None


def dtw(a, b, band_frac=0.25):
    n, m = len(a), len(b)
    band = max(abs(n - m), int(band_frac * max(n, m)))
    C = np.sqrt(((a[:, None, :] - b[None, :, :]) ** 2).sum(-1))
    D = np.full((n + 1, m + 1), np.inf)
    D[0, 0] = 0
    for i in range(1, n + 1):
        for j in range(max(1, i - band), min(m, i + band) + 1):
            D[i, j] = C[i - 1, j - 1] + min(D[i - 1, j], D[i, j - 1], D[i - 1, j - 1])
    return D[n, m] / (n + m)


def evaluate(name, seqs, labels, n_perm, rng):
    keep = [i for i, s in enumerate(seqs) if s is not None and len(s)]
    if len(keep) < 4 or len({labels[i] for i in keep}) < 2:
        return {"modality": name, "note": "有効な試行が不足"}
    X = [seqs[i] for i in keep]
    allf = np.concatenate(X)
    mu, sd = allf.mean(0), allf.std(0) + 1e-6
    X = [(s - mu) / sd for s in X]
    classes = sorted({labels[i] for i in keep})
    y = np.array([classes.index(labels[i]) for i in keep])
    n = len(X)
    D = np.zeros((n, n))
    for i in range(n):
        for j in range(i + 1, n):
            D[i, j] = D[j, i] = dtw(X[i], X[j])
    np.fill_diagonal(D, np.inf)
    nn = D.argmin(1)

    def acc(yy):
        return float((yy[nn] == yy).mean())

    a = acc(y)
    p = (1 + sum(acc(rng.permutation(y)) >= a for _ in range(n_perm))) / (n_perm + 1)
    cm = np.zeros((len(classes), len(classes)), int)
    for t, q in zip(y, y[nn]):
        cm[t, q] += 1
    return {"modality": name, "n": n, "classes": classes, "accuracy": a,
            "chance": float(np.bincount(y).max() / n), "p_value": p, "confusion": cm.tolist()}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run", type=Path)
    ap.add_argument("--perm", type=int, default=1000)
    ap.add_argument("--modality", nargs="+", default=["imu", "passive", "active"])
    a = ap.parse_args()
    fs, audio, trials, motion, meta = load(a.run)
    audio_start = float(trials[0]["audio_start"])
    labels = [t["label"] for t in trials]

    def seg(t):
        i0 = int((float(t["t0"]) - audio_start) * fs)
        i1 = int((float(t["t1"]) - audio_start) * fs)
        return audio[max(0, i0):max(0, i1)]

    rng = np.random.default_rng(0)
    out = []
    if "imu" in a.modality:
        out.append(evaluate("IMU", [imu_features(motion, float(t["t0"]), float(t["t1"])) for t in trials], labels, a.perm, rng))
    if "passive" in a.modality:
        out.append(evaluate("passive", [passive_features(seg(t), fs) for t in trials], labels, a.perm, rng))
    if "active" in a.modality and meta.get("probe") == "true":
        raw = [echo_features(seg(t), fs, meta.get("band", "ultrasonic")) for t in trials]
        frames = [r for r in raw if r is not None]
        if frames:
            med = np.median(np.concatenate(frames), 0)
            raw = [None if r is None else r - med for r in raw]
        out.append(evaluate("active", raw, labels, a.perm, rng))
    for r in out:
        if "note" in r:
            print(f"{r['modality']:8s} {r['note']}")
        else:
            verdict = "情報あり" if r["p_value"] < 0.05 and r["accuracy"] > r["chance"] else "情報なし"
            print(f"{r['modality']:8s} acc={r['accuracy']:.2f} chance={r['chance']:.2f} p={r['p_value']:.4f} n={r['n']} → {verdict}")
    (a.run / "classification_offline.json").write_text(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
