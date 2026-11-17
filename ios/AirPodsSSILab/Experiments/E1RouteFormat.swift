import Foundation

/// E1: 各 AVAudioSession 構成で、実際にどの入力・サンプリング周波数になるかを観測する。
enum E1RouteFormat {
    static let spec = ExperimentSpec(
        id: "E1", title: "経路と形式",
        summary: "各音声構成で、入力が AirPods になるか・実際のサンプリング周波数・遅延を調べる。IMU の可否も確認する。",
        requirements: ["R1", "R7", "R8"], duration: "約 30 秒", run: run)

    @MainActor static func run(_ ctx: ExperimentContext) async throws -> ExperimentResult {
        var res = ExperimentResult(experimentID: "E1", title: spec.title)
        let dir = RunStore.shared.newRunDir("E1")
        try await ctx.instruct("準備", "AirPods を両耳に装着し、iPhone と接続した状態にしてください。\n各構成で 1.5 秒ずつ無音を録音します。")

        var snaps: [RouteSnapshot] = []
        let rig = AudioRig()
        for cfg in AudioSessionConfig.matrix {
            ctx.working("構成: \(cfg.name)")
            do {
                let rec = try await rig.record(config: cfg, seconds: 1.5, playback: nil)
                var s = rec.route
                // 実際に届いたサンプル数から実効レートを逆算(形式の申告と食い違うことがあるため)
                let span = HostClock.now() - rec.firstSampleTime
                ctx.say("\(cfg.name): in \(s.engineInputFs) Hz (\(s.inputs.first?.type ?? "-")) / out \(s.engineOutputFs) Hz, \(rec.samples.count) samples")
                if s.engineInputFs > 0 && span > 0.5 { res.metric("\(cfg.name) 実効入力レート", Double(rec.samples.count) / span, "%.0f") }
                try? FileOut.writeWAV(rec.samples, fs: rec.fs, to: dir.appendingPathComponent("\(cfg.name.replacingOccurrences(of: " / ", with: "_")).wav"))
                if s.error == nil && !s.inputIsAirPods { s.error = "入力が AirPods ではない" }
                snaps.append(s)
            } catch {
                var s = RouteSnapshot(); s.config = cfg.name; s.error = "\(error.localizedDescription)"
                snaps.append(s)
                ctx.say("\(cfg.name): エラー \(error.localizedDescription)")
            }
        }
        try? FileOut.writeJSON(snaps, to: dir.appendingPathComponent("routes.json"))

        for s in snaps {
            res.metric("\(s.config) 入力", s.error ?? "\(Int(s.engineInputFs)) Hz × \(s.engineInputChannels)ch \(s.inputs.first?.type ?? "")")
            res.metric("\(s.config) 出力", "\(Int(s.engineOutputFs)) Hz \(s.outputs.first?.type ?? "")")
            res.metric("\(s.config) 遅延 in/out/IO [ms]", String(format: "%.1f / %.1f / %.1f", s.inputLatency * 1000, s.outputLatency * 1000, s.ioBufferDuration * 1000))
        }
        if let hq = snaps.first, !hq.hqOptionApplied {
            res.notes.append("bluetoothHighQualityRecording は iOS 26 以上が必要。この端末では使えないため HQ 構成は通常の A2DP 設定で代用した。")
        }

        let ok = snaps.filter { $0.error == nil && $0.inputIsAirPods }
        let maxFs = ok.map { $0.engineInputFs }.max() ?? 0
        res.metric("AirPods 入力の最大 fs", maxFs, "%.0f")
        res.verdict("R1", maxFs >= 47_000 ? .pass : (ok.isEmpty ? .unknown : .fail),
                    ok.isEmpty ? "AirPods 入力の構成が一つも取れなかった" : "AirPods 入力の最大 fs = \(Int(maxFs)) Hz")
        res.verdict("R7", maxFs >= 16_000 ? .unknown : .fail,
                    maxFs >= 16_000 ? "帯域上は 8 kHz まで録れる。抑圧の有無は E3 で判定" : "fs が 16 kHz 未満")

        let mr = MotionRecorder()
        res.metric("ヘッドホンモーション 利用可", mr.available ? "yes" : "no")
        res.metric("モーション権限", mr.authorization)
        if !mr.available { res.verdict("R8", .fail, "CMHeadphoneMotionManager が使えない機種/接続") }
        return finish(&res, dir: dir)
    }
}
