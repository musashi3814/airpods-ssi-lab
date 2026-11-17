import Accelerate
import Foundation

// MARK: - プローブ解析(E2)

struct ProbeMetrics: Codable {
    var config = ""
    var inputFs: Double = 0
    var outputFs: Double = 0
    var sweepFound = false
    var sweepPeakToMedian: Double = .nan
    var latencyMs: Double = .nan
    var bandSNR: [String: Double] = [:]
    var probeRepresentable = false
    var chirpBandSNR: Double = .nan
    var chirpPeakToMedian: Double = .nan
    var lagJitterMs: Double = .nan
    var driftPPM: Double = .nan
    var error: String?

    var bandwidthOK: Bool { probeRepresentable && chirpBandSNR > 10 }
    var probeSurvives: Bool { probeRepresentable && chirpPeakToMedian > 10 && chirpBandSNR > 10 }
}

enum ProbeAnalysis {
    static let bandEdges: [(Double, Double)] = [
        (100, 1_000), (1_000, 4_000), (4_000, 8_000), (8_000, 12_000), (12_000, 16_000),
        (16_000, 20_000), (20_000, 24_000), (24_000, 32_000),
    ]

    static func label(_ e: (Double, Double)) -> String {
        "\(Int(e.0 / 1000))-\(Int(e.1 / 1000))k"
    }

    /// E2 の録音を解析する。再生信号は ProbeSignal.matrixSignal。
    static func analyze(_ rec: Recording, band: ProbeBand) -> ProbeMetrics {
        var m = ProbeMetrics()
        m.config = rec.route.config
        m.inputFs = rec.fs
        m.outputFs = rec.route.engineOutputFs
        let fs = rec.fs, x = rec.samples
        guard fs > 0, x.count > Int(fs * 3) else { m.error = "録音が短すぎる"; return m }

        // 1) スイープで位置合わせ。録音側で表現できる周波数までの部分だけをテンプレートにする。
        let fEnd = 0.47 * max(rec.route.engineOutputFs, fs)
        let full = ProbeSignal.sweep(fs: fs, f1: fEnd)
        let fc = min(0.4 * fs, fEnd)
        let k = log(fEnd / 100.0)
        let tcut = ProbeSignal.sweepDuration * log(fc / 100.0) / k
        let tmpl = Array(full.prefix(max(256, Int(tcut * fs))))
        let c = DSP.correlateValid(x, tmpl).map { abs($0) }
        guard !c.isEmpty else { m.error = "相関計算に失敗"; return m }
        let s0 = DSP.argmaxAbs(c[...])
        let med = DSP.median(stride(from: 0, to: c.count, by: 97).map { Double(c[$0]) })
        m.sweepPeakToMedian = Double(c[s0]) / max(med, 1e-12)
        m.sweepFound = m.sweepPeakToMedian > 20
        if let ps = rec.playStartTime {
            let tRec = rec.firstSampleTime + Double(s0) / fs
            m.latencyMs = (tRec - (ps + ProbeSignal.sweepOffset)) * 1000
        }

        // 2) 帯域ごとの SNR(スイープ区間 vs 直前の無音)
        let nfft = 2048
        let nA = max(0, s0 - Int(0.9 * fs)), nB = max(nA + 1, s0 - Int(0.1 * fs))
        let noise = Array(x[nA..<min(nB, x.count)])
        let sw = Array(x[s0..<min(x.count, s0 + Int(ProbeSignal.sweepDuration * fs))])
        let pN = DSP.welch(noise, nfft: nfft), pS = DSP.welch(sw, nfft: nfft)
        for e in bandEdges where e.1 <= fs / 2 + 1 {
            m.bandSNR[label(e)] = DSP.bandDB(pS, fs: fs, nfft: nfft, lo: e.0, hi: e.1)
                - DSP.bandDB(pN, fs: fs, nfft: nfft, lo: e.0, hi: e.1)
        }

        // 3) チャープ列: 整合フィルタのピーク、遅延の揺らぎ、クロックドリフト
        m.probeRepresentable = band.representable(at: fs)
        guard m.probeRepresentable else { return m }
        let t0 = s0 + Int((ProbeSignal.trainOffset - ProbeSignal.sweepOffset) * fs)
        let t1 = min(x.count, t0 + Int(ProbeSignal.trainDuration * fs))
        guard t1 - t0 > Int(fs) else { m.error = "チャープ列の区間が足りない"; return m }
        let body = Array(x[t0..<t1])
        let (lo, hi) = band.range
        let pB = DSP.welch(body, nfft: nfft)
        m.chirpBandSNR = DSP.bandDB(pB, fs: fs, nfft: nfft, lo: lo, hi: hi) - DSP.bandDB(pN, fs: fs, nfft: nfft, lo: lo, hi: hi)
        let ch = ProbeSignal.chirp(fs: fs, band: band)
        let mf = DSP.correlateValid(body, ch)
        let period = ProbeSignal.chirpDuration * fs
        let nfr = Int(Double(mf.count) / period) - 1
        guard nfr > 4 else { return m }
        var ratios: [Double] = [], lags: [Double] = []
        for i in 0..<nfr {
            let a = Int((Double(i) * period).rounded()), b = Int((Double(i + 1) * period).rounded())
            let seg = mf[a..<b].map { abs($0) }
            let mx = seg.max() ?? 0
            let md = DSP.median(seg.map(Double.init))
            ratios.append(Double(mx) / max(md, 1e-12))
            lags.append(Double(DSP.argmaxAbs(mf[a..<b]) - a))
        }
        m.chirpPeakToMedian = DSP.median(ratios)
        // 遅延の直線当てはめ(傾き = ドリフト、残差 = 揺らぎ)。フレーム境界での折り返しは無視できる程度と仮定
        let n = Double(lags.count)
        let xs = (0..<lags.count).map(Double.init)
        let mx = xs.reduce(0, +) / n, my = lags.reduce(0, +) / n
        let sxy = zip(xs, lags).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
        let sxx = xs.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
        let slope = sxy / max(sxx, 1e-12)
        let resid = zip(xs, lags).map { $1 - (my + slope * ($0 - mx)) }
        m.driftPPM = slope / period * 1e6
        m.lagJitterMs = sqrt(resid.map { $0 * $0 }.reduce(0, +) / n) / fs * 1000
        return m
    }
}

// MARK: - 特徴量(E5)

typealias Sequence2D = [[Float]]   // [frame][dim]

enum Features {
    /// IMU: 9 ch(userAccel 3, rotationRate 3, attitude の窓内変化 3)を 50 Hz に揃える。
    static func imu(_ s: [MotionSample], t0: Double, t1: Double, rate: Double = 50) -> Sequence2D? {
        let w = s.filter { $0.t >= t0 - 0.1 && $0.t <= t1 + 0.1 }
        guard w.count >= 3 else { return nil }
        let ts = w.map { $0.t }
        let r0 = w[0].roll, p0 = w[0].pitch, y0 = w[0].yaw
        let chans: [[Float]] = [
            w.map { $0.ax }, w.map { $0.ay }, w.map { $0.az },
            w.map { $0.gx }, w.map { $0.gy }, w.map { $0.gz },
            w.map { $0.roll - r0 }, w.map { $0.pitch - p0 }, w.map { $0.yaw - y0 },
        ]
        let count = max(2, Int((t1 - t0) * rate))
        let rs = chans.map { DSP.resampleLinear(times: ts, values: $0, t0: t0, dt: 1 / rate, count: count) }
        return (0..<count).map { i in rs.map { $0[i] } }
    }

    /// パッシブ音: 20 ms ごとの対数バンドエネルギー(100 Hz〜8 kHz を 16 帯に対数分割)。
    static func passiveAudio(_ x: [Float], fs: Double) -> Sequence2D? {
        let hop = Int(0.02 * fs)
        let nfft = DSP.nextPow2(Int(0.04 * fs))
        guard x.count > nfft + hop else { return nil }
        let fft = DSP.RealFFT(size: nfft)
        let w = DSP.hann(nfft)
        let fMax = min(8_000, 0.47 * fs), fMin = 100.0, nb = 16
        let edges = (0...nb).map { fMin * pow(fMax / fMin, Double($0) / Double(nb)) }
        let bins = edges.map { max(1, min(nfft / 2, Int($0 / fs * Double(nfft)))) }
        var out: Sequence2D = []
        var i = 0
        while i + nfft <= x.count {
            let seg = (0..<nfft).map { x[i + $0] * w[$0] }
            let p = fft.power(seg)
            out.append((0..<nb).map { b in
                let a = bins[b], z = max(bins[b] + 1, bins[b + 1])
                var s: Float = 0
                for k in a..<min(z, p.count) { s += p[k] }
                return log10(s / Float(z - a) + 1e-12)
            })
            i += hop
        }
        return out
    }

    /// アクティブ反射: チャープごとの整合フィルタ出力のうち、直達ピークから 3 ms 分の
    /// 振幅プロファイル(直達で正規化、24 次元に平均プーリング)。
    static func echoFrames(_ x: [Float], fs: Double, band: ProbeBand) -> (frames: Sequence2D, lag: Int)? {
        guard band.representable(at: fs) else { return nil }
        let ch = ProbeSignal.chirp(fs: fs, band: band)
        let mf = DSP.correlateValid(x, ch)
        let period = ProbeSignal.chirpDuration * fs
        let nfr = Int(Double(mf.count) / period) - 1
        guard nfr >= 3 else { return nil }
        var lags: [Double] = []
        for f in 0..<nfr {
            let a = Int((Double(f) * period).rounded()), b = Int((Double(f + 1) * period).rounded())
            lags.append(Double(DSP.argmaxAbs(mf[a..<b]) - a))
        }
        let lag = Int(DSP.median(lags))
        let win = max(24, Int(0.003 * fs))
        let dims = 24
        var frames: Sequence2D = []
        for f in 0..<nfr {
            let a = Int((Double(f) * period).rounded()) + lag
            guard a + win <= mf.count else { break }
            let direct = max(abs(mf[a]), 1e-9)
            let prof = (0..<win).map { abs(mf[a + $0]) / direct }
            frames.append((0..<dims).map { d in
                let s = d * win / dims, e = max(s + 1, (d + 1) * win / dims)
                return prof[s..<e].reduce(0, +) / Float(e - s)
            })
        }
        return frames.isEmpty ? nil : (frames, lag)
    }

    /// 全試行をまとめて、チャンネルごとに z 正規化する。
    static func zscore(_ seqs: [Sequence2D]) -> [Sequence2D] {
        guard let d = seqs.first(where: { !$0.isEmpty })?.first?.count else { return seqs }
        var mean = [Double](repeating: 0, count: d), sq = [Double](repeating: 0, count: d)
        var n = 0.0
        for s in seqs { for f in s { for j in 0..<d { mean[j] += Double(f[j]); sq[j] += Double(f[j] * f[j]) } ; n += 1 } }
        guard n > 1 else { return seqs }
        let mu = mean.map { $0 / n }
        let sd = (0..<d).map { sqrt(max(sq[$0] / n - mu[$0] * mu[$0], 1e-12)) }
        return seqs.map { s in s.map { f in (0..<d).map { Float((Double(f[$0]) - mu[$0]) / sd[$0]) } } }
    }
}

// MARK: - DTW 1-NN 分類と置換検定

struct ClassificationReport: Codable {
    var modality = ""
    var nTrials = 0
    var classes: [String] = []
    var accuracy: Double = .nan
    var chance: Double = .nan
    var pValue: Double = .nan
    var confusion: [[Int]] = []
    var note: String?

    var informative: Bool { pValue < 0.05 && accuracy > chance }
}

enum Classifier {
    static func dtw(_ a: Sequence2D, _ b: Sequence2D, bandFrac: Double = 0.25) -> Double {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return .infinity }
        let band = max(abs(n - m), Int(bandFrac * Double(max(n, m))))
        var prev = [Double](repeating: .infinity, count: m + 1)
        var cur = [Double](repeating: .infinity, count: m + 1)
        prev[0] = 0
        let d = a[0].count
        for i in 1...n {
            cur = [Double](repeating: .infinity, count: m + 1)
            let jLo = max(1, i - band), jHi = min(m, i + band)
            if jLo > jHi { prev = cur; continue }
            for j in jLo...jHi {
                var c: Float = 0
                let ai = a[i - 1], bj = b[j - 1]
                for k in 0..<d { let t = ai[k] - bj[k]; c += t * t }
                cur[j] = Double(sqrt(c)) + min(prev[j], cur[j - 1], prev[j - 1])
            }
            prev = cur
        }
        return prev[m] / Double(n + m)
    }

    static func distanceMatrix(_ seqs: [Sequence2D]) -> [[Double]] {
        let n = seqs.count
        var D = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: n) { i in
            var row = [Double](repeating: 0, count: n)
            for j in (i + 1)..<max(i + 1, n) { row[j] = dtw(seqs[i], seqs[j]) }
            lock.lock(); D[i] = row; lock.unlock()
        }
        for i in 0..<n { for j in (i + 1)..<max(i + 1, n) { D[j][i] = D[i][j] } }
        return D
    }

    static func looAccuracy(_ D: [[Double]], _ y: [Int]) -> (Double, [Int]) {
        var correct = 0
        var pred = [Int](repeating: -1, count: y.count)
        for i in 0..<y.count {
            var best = -1
            var bd = Double.infinity
            for j in 0..<y.count where j != i && D[i][j] < bd { bd = D[i][j]; best = j }
            pred[i] = best >= 0 ? y[best] : -1
            if pred[i] == y[i] { correct += 1 }
        }
        return (Double(correct) / Double(max(1, y.count)), pred)
    }

    static func evaluate(modality: String, seqs: [Sequence2D?], labels: [String], permutations: Int = 500) -> ClassificationReport {
        var r = ClassificationReport()
        r.modality = modality
        let keep = seqs.indices.filter { seqs[$0] != nil && !(seqs[$0]!.isEmpty) }
        let classes = Array(Set(keep.map { labels[$0] })).sorted()
        r.classes = classes
        r.nTrials = keep.count
        guard keep.count >= 4, classes.count >= 2 else { r.note = "有効な試行が不足"; return r }
        let X = Features.zscore(keep.map { seqs[$0]! })
        let y = keep.map { classes.firstIndex(of: labels[$0])! }
        let D = distanceMatrix(X)
        let (acc, pred) = looAccuracy(D, y)
        r.accuracy = acc
        // チャンス = 最頻クラスの割合
        let counts = classes.indices.map { c in y.filter { $0 == c }.count }
        r.chance = Double(counts.max() ?? 0) / Double(y.count)
        var cm = [[Int]](repeating: [Int](repeating: 0, count: classes.count), count: classes.count)
        for (t, p) in zip(y, pred) where p >= 0 { cm[t][p] += 1 }
        r.confusion = cm
        var ge = 0
        var yp = y
        for _ in 0..<permutations {
            yp.shuffle()
            if looAccuracy(D, yp).0 >= acc { ge += 1 }
        }
        r.pValue = Double(ge + 1) / Double(permutations + 1)
        return r
    }
}
