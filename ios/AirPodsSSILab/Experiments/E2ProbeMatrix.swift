import Foundation

/// E2: 各構成でプローブ(スイープ + チャープ列)を再生しながら録音し、
/// 帯域・エコー除去・遅延安定性を調べる。最後に内蔵マイクで出力帯域を確認する。
enum E2ProbeMatrix {
    static let spec = ExperimentSpec(
        id: "E2", title: "プローブ行列",
        summary: "AirPods からプローブ音を出しながら AirPods マイクで録り、超音波帯が通るか・再生音がエコー除去で消されないか・遅延が安定かを構成ごとに測る。",
        requirements: ["R1", "R2", "R3", "R4", "R5"], duration: "約 2 分", run: run)

    @MainActor static func run(_ ctx: ExperimentContext) async throws -> ExperimentResult {
        var res = ExperimentResult(experimentID: "E2", title: spec.title)
        let dir = RunStore.shared.newRunDir("E2")
        let band = ctx.settings.probeBand, level = ctx.settings.levelDBFS
        try await ctx.instruct("準備", """
        AirPods を両耳に装着し、静かな場所で動かずにいてください。
        システム音量は 30〜50% 程度にしてください(プローブは \(Int(level)) dBFS)。
        プローブ帯: \(band.label)。1 構成あたり約 \(Int(ProbeSignal.matrixDuration)) 秒です。
        """)

        let rig = AudioRig()
        var all: [ProbeMetrics] = []
        for cfg in AudioSessionConfig.matrix {
            try Task.checkCancellation()
            ctx.working("録音中: \(cfg.name)")
            do {
                let rec = try await rig.record(config: cfg, seconds: ProbeSignal.matrixDuration, playback: { fs in
                    ProbeSignal.matrixSignal(fs: fs, band: band, levelDBFS: level)
                })
                ctx.working("解析中: \(cfg.name)")
                let m = await Task.detached { ProbeAnalysis.analyze(rec, band: band) }.value
                all.append(m)
                try? FileOut.writeWAV(rec.samples, fs: rec.fs, to: dir.appendingPathComponent("\(safe(cfg.name)).wav"))
                ctx.say("\(cfg.name): fs \(Int(m.inputFs)) / probe SNR \(fmt(m.chirpBandSNR)) dB / peak \(fmt(m.chirpPeakToMedian))")
            } catch {
                var m = ProbeMetrics(); m.config = cfg.name; m.error = error.localizedDescription
                all.append(m)
                ctx.say("\(cfg.name): エラー \(error.localizedDescription)")
            }
        }

        // 出力帯域の確認(R3)
        var outM: ProbeMetrics?
        do {
            try await ctx.instruct("出力帯域の確認", """
            片方の AirPod を耳から外し、スピーカー側を iPhone の下端(マイク穴)に 1 cm ほどまで近づけて持ってください。
            もう片方は耳に装着したままで構いません。「次へ」を押すと約 \(Int(ProbeSignal.matrixDuration)) 秒測定します。
            """)
            ctx.working("録音中: 出力帯域")
            let rec = try await rig.record(config: AudioSessionConfig.outputCheck, seconds: ProbeSignal.matrixDuration, playback: { fs in
                ProbeSignal.matrixSignal(fs: fs, band: band, levelDBFS: level)
            })
            let m = await Task.detached { ProbeAnalysis.analyze(rec, band: band) }.value
            outM = m
            try? FileOut.writeWAV(rec.samples, fs: rec.fs, to: dir.appendingPathComponent("output_check.wav"))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            ctx.say("出力帯域の確認: エラー \(error.localizedDescription)")
        }
        try? FileOut.writeJSON(["matrix": all] as [String: [ProbeMetrics]], to: dir.appendingPathComponent("probe_metrics.json"))
        if let outM { try? FileOut.writeJSON(outM, to: dir.appendingPathComponent("output_check.json")) }

        for m in all {
            if let e = m.error { res.metric(m.config, "エラー: \(e)"); continue }
            res.metric(m.config, String(format: "fs %.0f | 遅延 %@ ms | プローブ SNR %@ dB | ピーク比 %@ | 揺らぎ %@ ms | ドリフト %@ ppm",
                                         m.inputFs, fmt(m.latencyMs), fmt(m.chirpBandSNR), fmt(m.chirpPeakToMedian), fmt(m.lagJitterMs, "%.3f"), fmt(m.driftPPM)))
            let bands = ProbeAnalysis.bandEdges.map(ProbeAnalysis.label).compactMap { k in m.bandSNR[k].map { "\(k): \(fmt($0))" } }
            res.metric("\(m.config) 帯域 SNR [dB]", bands.joined(separator: ", "))
        }
        if let o = outM {
            res.metric("出力確認(内蔵マイク)", String(format: "fs %.0f | プローブ SNR %@ dB | 20-24k %@ dB", o.inputFs, fmt(o.chirpBandSNR), fmt(o.bandSNR["20-24k"] ?? .nan)))
        }

        // 判定: AirPods 入力で最も良い構成を基準にする
        let valid = all.filter { $0.error == nil }
        let best = valid.max { score($0) < score($1) }
        if let best { res.metric("最良構成", best.config) }
        let maxFs = valid.map { $0.inputFs }.max() ?? 0
        res.verdict("R1", maxFs >= 47_000 ? .pass : (valid.isEmpty ? .unknown : .fail), "最大入力 fs = \(Int(maxFs)) Hz")
        if let b = best, b.probeRepresentable {
            res.verdict("R2", b.bandwidthOK ? .pass : .fail, "\(b.config): プローブ帯 SNR \(fmt(b.chirpBandSNR)) dB")
            res.verdict("R4", b.probeSurvives ? .pass : .fail,
                        "\(b.config): ピーク比 \(fmt(b.chirpPeakToMedian))" + (b.bandwidthOK && !b.probeSurvives ? "(帯域はあるのにピークが立たない = エコー除去の疑い)" : ""))
            if b.probeSurvives {
                res.verdict("R5", b.lagJitterMs < 0.1 ? .pass : .fail, "揺らぎ \(fmt(b.lagJitterMs, "%.3f")) ms, ドリフト \(fmt(b.driftPPM)) ppm")
            } else {
                res.verdict("R5", .skipped, "プローブが検出できないため測れない")
            }
        } else {
            res.verdict("R2", valid.isEmpty ? .unknown : .fail, "どの構成でもプローブ帯を表現できる fs にならない")
            res.verdict("R4", .skipped, "R2 不成立")
            res.verdict("R5", .skipped, "R2 不成立")
        }
        if let o = outM, o.error == nil {
            if o.probeRepresentable {
                res.verdict("R3", o.chirpBandSNR > 10 ? .pass : .fail, "内蔵マイクでプローブ帯 SNR \(fmt(o.chirpBandSNR)) dB(近づけ方で変わるので低い場合は再試行)")
            } else {
                res.verdict("R3", .unknown, "内蔵マイクの fs \(Int(o.inputFs)) Hz ではプローブ帯を測れない")
            }
        } else {
            res.verdict("R3", .unknown, "出力確認を実行できなかった")
        }
        res.notes.append("ピーク比は整合フィルタ出力のピーク/中央値。雑音だけなら数程度、プローブが届いていれば数十〜数千になる。")
        return finish(&res, dir: dir)
    }

    private static func score(_ m: ProbeMetrics) -> Double {
        guard m.probeRepresentable else { return m.inputFs / 1e6 }
        return (m.chirpPeakToMedian.isFinite ? m.chirpPeakToMedian : 0) + 1
    }
}

func fmt(_ v: Double, _ f: String = "%.1f") -> String { v.isFinite ? String(format: f, v) : "n/a" }
func safe(_ s: String) -> String { s.replacingOccurrences(of: " / ", with: "_").replacingOccurrences(of: " ", with: "_") }
