import Foundation

/// E4: CMHeadphoneMotionManager の実効レート・途切れ・口の動きへの感度を測る。
enum E4Motion {
    static let spec = ExperimentSpec(
        id: "E4", title: "IMU の性能",
        summary: "公開 API のヘッドホンモーションで、実効レート・静止時の途切れ・口パクが安静時と区別できるかを測る。",
        requirements: ["R8", "R9", "R10"], duration: "約 1 分", run: run)

    @MainActor static func run(_ ctx: ExperimentContext) async throws -> ExperimentResult {
        var res = ExperimentResult(experimentID: "E4", title: spec.title)
        let dir = RunStore.shared.newRunDir("E4")
        let mr = MotionRecorder()
        guard mr.available else {
            res.verdict("R8", .fail, "CMHeadphoneMotionManager が使えない(対応 AirPods を接続しているか確認)")
            return finish(&res, dir: dir)
        }
        try await ctx.instruct("準備", "AirPods を装着し、椅子に座って頭を楽にしてください。\n各ステップは自動で続きます。頭はできるだけ動かさないでください。")

        let steps: [(String, String, Double)] = [
            ("rest", "安静: 頭も口も動かさない", 8),
            ("mouth", "口パク: 声を出さずに『あいうえお』をはっきり繰り返す", 8),
            ("jaw", "顎の開閉: 口を大きく開け閉めする", 8),
            ("voice", "発声: 普通の声で『あいうえお』", 8),
            ("teeth", "歯を軽くカチカチ鳴らす", 6),
            ("nod", "対照: ゆっくりうなずく", 6),
        ]
        mr.start()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var windows: [(String, Double, Double)] = []
        for (key, text, sec) in steps {
            let (t0, t1) = try await ctx.countdown(text, "", seconds: sec)
            windows.append((key, t0 + 0.5, t1))   // 動作の立ち上がりを除く
        }
        let samples = mr.stop()
        try? FileOut.writeMotionCSV(samples, to: dir.appendingPathComponent("motion.csv"))
        try? FileOut.writeLines(["label,t0,t1"] + windows.map { "\($0.0),\($0.1),\($0.2)" }, to: dir.appendingPathComponent("windows.csv"))

        let tm = MotionStats.timing(samples)
        for k in ["count", "rate_hz", "dt_p50_ms", "dt_p95_ms", "dt_max_ms", "gaps_over_200ms"] {
            res.metric(k, tm[k] ?? .nan)
        }
        if let err = mr.lastError { res.notes.append("CoreMotion エラー: \(err)") }
        let locs = Set(samples.map { $0.sensorLocation })
        res.metric("sensorLocation(0=既定,1=左,2=右)", locs.sorted().map(String.init).joined(separator: ","))

        var energies: [String: (Double, Double)] = [:]
        var restTiming: [String: Double] = [:]
        for (k, t0, t1) in windows {
            let w = MotionStats.window(samples, t0, t1)
            energies[k] = MotionStats.energy(w)
            if k == "rest" { restTiming = MotionStats.timing(w); restTiming["expected"] = (t1 - t0) * (tm["rate_hz"] ?? 0) }
            res.metric("\(k): 加速度 RMS [mg] / 角速度 RMS [mrad/s] / 件数",
                       String(format: "%@ / %@ / %ld", fmt(energies[k]!.0 * 1000, "%.2f"), fmt(energies[k]!.1 * 1000, "%.2f"), w.count))
        }
        let rest = energies["rest"] ?? (.nan, .nan)
        func ratioDB(_ k: String) -> Double {
            guard let e = energies[k] else { return .nan }
            let a = 20 * log10(e.0 / rest.0), g = 20 * log10(e.1 / rest.1)
            return max(a.isFinite ? a : -.infinity, g.isFinite ? g : -.infinity)
        }
        for k in ["mouth", "jaw", "voice", "teeth", "nod"] { res.metric("\(k) / 安静 [dB]", ratioDB(k)) }

        let rate = tm["rate_hz"] ?? 0
        res.verdict("R8", rate >= 50 ? .pass : .fail, "実効レート \(fmt(rate)) Hz")
        let restCount = Double(MotionStats.window(samples, windows[0].1, windows[0].2).count)
        let gaps = restTiming["gaps_over_200ms"] ?? .nan
        if restCount < 0.5 * (restTiming["expected"] ?? 1) || gaps > 0 {
            res.verdict("R9", .fail, "安静中のサンプル \(Int(restCount)) 件、200 ms 超のギャップ \(fmt(gaps, "%.0f")) 回")
        } else {
            res.verdict("R9", .pass, "安静中も連続(\(Int(restCount)) 件)")
        }
        let m = ratioDB("mouth")
        res.verdict("R10", !m.isFinite ? .unknown : (m > 3 ? .pass : .fail), "口パク/安静 = \(fmt(m)) dB(顎の開閉は \(fmt(ratioDB("jaw"))) dB)")
        return finish(&res, dir: dir)
    }
}
