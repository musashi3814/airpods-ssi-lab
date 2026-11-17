import Foundation

/// プローブ帯域。超音波が通らない経路でも解析パイプラインを試せるよう、可聴帯も選べる。
enum ProbeBand: String, CaseIterable, Codable, Identifiable {
    case ultrasonic   // 17.5–23 kHz (HEar-ID と同じ)
    case nearUltra    // 15–20 kHz
    case audible      // 4–8 kHz(パイプライン確認用。聞こえる)

    var id: String { rawValue }
    var range: (Double, Double) {
        switch self {
        case .ultrasonic: return (17_500, 23_000)
        case .nearUltra: return (15_000, 20_000)
        case .audible: return (4_000, 8_000)
        }
    }
    var label: String {
        switch self {
        case .ultrasonic: return "超音波 17.5–23 kHz"
        case .nearUltra: return "準超音波 15–20 kHz"
        case .audible: return "可聴 4–8 kHz(確認用)"
        }
    }
    /// fs で表現できるか(上限がナイキストの 98% 未満)。48 kHz で 23 kHz まで可。
    func representable(at fs: Double) -> Bool { range.1 < 0.49 * fs }
}

/// プローブ信号の定義。信号は連続時間で定義しているので、再生側・録音側で
/// サンプリング周波数が違っても、同じ式でテンプレートを作れる。
struct ProbeSignal {
    static let chirpDuration = 2048.0 / 48_000.0   // ~42.7 ms(HEar-ID と同程度)
    static let sweepDuration = 1.5
    static let lead = 1.0, gap = 0.5, trainDuration = 6.0, tail = 1.0

    /// 行列実験 (E2) 用の構成: 無音 → 対数スイープ → 無音 → チャープ列 → 無音
    static var matrixDuration: Double { lead + sweepDuration + gap + trainDuration + tail }
    static var sweepOffset: Double { lead }
    static var trainOffset: Double { lead + sweepDuration + gap }

    static func sweep(fs: Double, f1: Double? = nil) -> [Float] {
        let n = Int(sweepDuration * fs)
        let f0 = 100.0, fEnd = f1 ?? 0.47 * fs
        let k = log(fEnd / f0)
        // 端のクリックを避けるため、先頭と末尾 5% だけ余弦テーパをかける
        let edge = max(1, n / 20)
        return (0..<n).map { i in
            let t = Double(i) / fs
            let phase = 2 * Double.pi * f0 * sweepDuration / k * (exp(t / sweepDuration * k) - 1)
            let d = min(i, n - 1 - i)
            let g = d < edge ? 0.5 * (1 - cos(Double.pi * Double(d) / Double(edge))) : 1
            return Float(sin(phase) * g)
        }
    }

    static func chirp(fs: Double, band: ProbeBand) -> [Float] {
        let n = Int((chirpDuration * fs).rounded())
        let (f0, f1) = band.range
        let T = Double(n) / fs
        let w = DSP.hann(n)
        return (0..<n).map { i in
            let t = Double(i) / fs
            let phase = 2 * Double.pi * (f0 * t + (f1 - f0) / (2 * T) * t * t)
            return Float(sin(phase)) * w[i]
        }
    }

    /// E2 用の再生信号(出力サンプリング周波数で生成)。
    static func matrixSignal(fs: Double, band: ProbeBand, levelDBFS: Double) -> [Float] {
        let amp = Float(pow(10, levelDBFS / 20))
        var x = [Float](repeating: 0, count: Int(lead * fs))
        x += sweep(fs: fs)
        x += [Float](repeating: 0, count: Int(gap * fs))
        let c = chirp(fs: fs, band: band)
        let reps = Int(trainDuration / chirpDuration)
        for _ in 0..<reps { x += c }
        x += [Float](repeating: 0, count: Int(tail * fs))
        return x.map { $0 * amp }
    }

    /// 連続再生用(E5 など)。1 周期 = 1 チャープ。ループ再生する。
    static func loopSignal(fs: Double, band: ProbeBand, levelDBFS: Double) -> [Float] {
        let amp = Float(pow(10, levelDBFS / 20))
        return chirp(fs: fs, band: band).map { $0 * amp }
    }
}
