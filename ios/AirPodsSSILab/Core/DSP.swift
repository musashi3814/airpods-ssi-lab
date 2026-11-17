import Accelerate
import Foundation

/// 実験で使う最小限の信号処理。Accelerate の FFT をラップする。
enum DSP {
    static func nextPow2(_ n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }

    // MARK: FFT

    /// 実数 FFT のセットアップを使い回すための小さなラッパ。
    final class RealFFT {
        let size: Int
        private let log2n: vDSP_Length
        private let setup: FFTSetup

        init(size: Int) {
            precondition(size >= 2 && size & (size - 1) == 0, "size must be power of two")
            self.size = size
            self.log2n = vDSP_Length(Int(log2(Double(size)).rounded()))
            self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        /// vDSP の packed 形式 (re[0]=DC, im[0]=Nyquist) で返す。値は DFT の 2 倍。
        func forward(_ x: [Float]) -> (re: [Float], im: [Float]) {
            var padded = [Float](repeating: 0, count: size)
            let n = min(x.count, size)
            if n > 0 { padded.replaceSubrange(0..<n, with: x[0..<n]) }
            var re = [Float](repeating: 0, count: size / 2)
            var im = [Float](repeating: 0, count: size / 2)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    padded.withUnsafeBufferPointer { pp in
                        pp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { cp in
                            vDSP_ctoz(cp, 2, &sc, 1, vDSP_Length(size / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            return (re, im)
        }

        /// packed 形式の逆変換。結果は size 倍されているので呼び出し側で割る。
        func inverse(re: [Float], im: [Float]) -> [Float] {
            var r = re, i = im
            var out = [Float](repeating: 0, count: size)
            r.withUnsafeMutableBufferPointer { rp in
                i.withUnsafeMutableBufferPointer { ip in
                    var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_INVERSE))
                    out.withUnsafeMutableBufferPointer { op in
                        op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { cp in
                            vDSP_ztoc(&sc, 1, cp, 2, vDSP_Length(size / 2))
                        }
                    }
                }
            }
            return out
        }

        /// 片側パワースペクトル (size/2+1 bin)。スケールは相対比較用。
        func power(_ x: [Float]) -> [Float] {
            let (re, im) = forward(x)
            var p = [Float](repeating: 0, count: size / 2 + 1)
            p[0] = re[0] * re[0]
            p[size / 2] = im[0] * im[0]
            for k in 1..<(size / 2) { p[k] = re[k] * re[k] + im[k] * im[k] }
            return p
        }
    }

    /// 相互相関 (valid モード)。out[k] = Σ_j x[k+j]·h[j]、長さ x.count - h.count + 1。
    static func correlateValid(_ x: [Float], _ h: [Float]) -> [Float] {
        let n = x.count, m = h.count
        guard m > 0, n >= m else { return [] }
        let size = nextPow2(n + m)
        let fft = RealFFT(size: size)
        let X = fft.forward(x)
        let H = fft.forward(Array(h.reversed()))
        var yr = [Float](repeating: 0, count: size / 2)
        var yi = [Float](repeating: 0, count: size / 2)
        yr[0] = X.re[0] * H.re[0]
        yi[0] = X.im[0] * H.im[0]
        for k in 1..<(size / 2) {
            let a = X.re[k], b = X.im[k], c = H.re[k], d = H.im[k]
            yr[k] = a * c - b * d
            yi[k] = a * d + b * c
        }
        let y = fft.inverse(re: yr, im: yi)
        let scale = 1 / Float(4 * size)
        return (0..<(n - m + 1)).map { y[$0 + m - 1] * scale }
    }

    // MARK: スペクトル

    static func hann(_ n: Int) -> [Float] {
        var w = [Float](repeating: 0, count: n)
        vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        return w
    }

    /// Welch 法の平均パワースペクトル。返り値の bin k の周波数は k·fs/nfft。
    static func welch(_ x: [Float], nfft: Int = 2048) -> [Float] {
        guard x.count >= nfft else {
            return welch(x + [Float](repeating: 0, count: nfft - x.count), nfft: nfft)
        }
        let fft = RealFFT(size: nfft)
        let w = hann(nfft)
        var acc = [Float](repeating: 0, count: nfft / 2 + 1)
        var count: Float = 0
        var start = 0
        while start + nfft <= x.count {
            let raw = Array(x[start..<(start + nfft)])
            var seg = [Float](repeating: 0, count: nfft)
            vDSP_vmul(raw, 1, w, 1, &seg, 1, vDSP_Length(nfft))
            let p = fft.power(seg)
            for k in 0..<acc.count { acc[k] += p[k] }
            count += 1
            start += nfft / 2
        }
        if count > 0 { acc = acc.map { $0 / count } }
        return acc
    }

    /// 帯域 [lo, hi) の平均パワー (dB)。
    static func bandDB(_ psd: [Float], fs: Double, nfft: Int, lo: Double, hi: Double) -> Double {
        let k0 = max(1, Int((lo / fs * Double(nfft)).rounded(.up)))
        let k1 = min(psd.count - 1, Int((hi / fs * Double(nfft)).rounded(.down)))
        guard k1 >= k0 else { return .nan }
        var s: Double = 0
        for k in k0...k1 { s += Double(psd[k]) }
        return 10 * log10(s / Double(k1 - k0 + 1) + 1e-20)
    }

    static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        var r: Float = 0
        x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &r, vDSP_Length($0.count)) }
        return r
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return .nan }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return .nan }
        let s = v.sorted()
        let idx = min(s.count - 1, max(0, Int((p / 100 * Double(s.count - 1)).rounded())))
        return s[idx]
    }

    static func argmaxAbs(_ x: ArraySlice<Float>) -> Int {
        var best = x.startIndex
        var bv: Float = -1
        for i in x.indices where abs(x[i]) > bv {
            bv = abs(x[i])
            best = i
        }
        return best
    }

    /// 線形補間でリサンプル(IMU を等間隔にそろえる用途。音声には使わない)。
    static func resampleLinear(times: [Double], values: [Float], t0: Double, dt: Double, count: Int) -> [Float] {
        guard !times.isEmpty else { return [Float](repeating: 0, count: count) }
        var out = [Float](repeating: 0, count: count)
        var j = 0
        for i in 0..<count {
            let t = t0 + Double(i) * dt
            while j + 1 < times.count && times[j + 1] < t { j += 1 }
            if t <= times[0] { out[i] = values[0]; continue }
            if j + 1 >= times.count { out[i] = values[times.count - 1]; continue }
            let a = (t - times[j]) / max(1e-9, times[j + 1] - times[j])
            out[i] = values[j] + Float(a) * (values[j + 1] - values[j])
        }
        return out
    }
}
