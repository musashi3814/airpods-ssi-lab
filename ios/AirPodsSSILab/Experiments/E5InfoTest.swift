import Foundation
import UIKit

/// E5: 単語ごとの情報が信号に含まれるかの検定。
/// 少数の単語を無声で繰り返し、IMU / パッシブ音 / アクティブ反射それぞれで
/// 1-NN DTW の leave-one-out 精度と置換検定 p 値を出す。
enum E5InfoTest {
    static let spec = ExperimentSpec(
        id: "E5", title: "単語情報の検定",
        summary: "数個の単語を無声で繰り返し発話し、IMU・パッシブ音・アクティブ反射のそれぞれで単語を区別できる情報があるかを統計的に確かめる。",
        requirements: ["R11a", "R11b", "R11c", "R12"], duration: "約 4 分(設定による)", run: run)

    static let restLabel = "(安静)"
    static let prep = 1.2, window = 2.0, gap = 0.6

    struct Trial { let label: String; let t0: Double; let t1: Double }

    @MainActor static func run(_ ctx: ExperimentContext) async throws -> ExperimentResult {
        var res = ExperimentResult(experimentID: "E5", title: spec.title)
        let dir = RunStore.shared.newRunDir("E5")
        let s = ctx.settings
        let cfg = s.captureConfig, band = s.probeBand, level = s.levelDBFS
        let labels = s.words + [restLabel]
        var order: [String] = []
        for _ in 0..<max(2, s.reps) { order += labels }
        order.shuffle()
        res.metric("録音構成", cfg.name)
        res.metric("発話様式", s.articulation)
        res.metric("単語", labels.joined(separator: " / "))
        res.metric("試行数", Double(order.count), "%.0f")
        res.metric("プローブ", s.e5Probe ? band.label : "なし")

        try await ctx.instruct("準備", """
        画面に出る単語を「\(s.articulation)」で発話してください。\(restLabel) のときは何もしません。
        「準備」の間に単語を確認し、「どうぞ」の 2 秒間に 1 回だけ発話します。頭は動かさないでください。
        全 \(order.count) 試行、約 \(Int(Double(order.count) * (prep + window + gap) / 60) + 1) 分です。
        """ + (s.e5Probe ? "\nプローブ音を小さく流し続けます。" : ""))

        let mr = MotionRecorder()
        let rig = AudioRig()
        let useProbe = s.e5Probe
        var playback: ((Double) -> [Float])? = nil
        if useProbe { playback = { fs in ProbeSignal.loopSignal(fs: fs, band: band, levelDBFS: level) } }
        let snap = try await rig.start(config: cfg, playback: playback, loop: true)
        if mr.available { mr.start() }
        let haptic = UIImpactFeedbackGenerator(style: .medium)

        var trials: [Trial] = []
        do {
            try await ctx.countdown("開始します", "", seconds: 2)
            for (i, w) in order.enumerated() {
                try await ctx.countdown("準備 \(i + 1)/\(order.count)", w, seconds: prep)
                haptic.impactOccurred()
                let (t0, t1) = try await ctx.countdown("どうぞ", w, seconds: window)
                trials.append(Trial(label: w, t0: t0, t1: t1))
                try await ctx.countdown("—", "", seconds: gap)
            }
        } catch {
            _ = rig.stop(); mr.stop()
            throw error
        }
        let rec = rig.stop()
        let motion = mr.available ? mr.stop() : []

        ctx.working("保存中…")
        try? FileOut.writeWAV(rec.samples, fs: rec.fs, to: dir.appendingPathComponent("audio.wav"))
        try? FileOut.writeMotionCSV(motion, to: dir.appendingPathComponent("motion.csv"))
        try? FileOut.writeLines(["label,t0,t1,audio_start"] + trials.map { "\($0.label),\($0.t0),\($0.t1),\(rec.firstSampleTime)" },
                                to: dir.appendingPathComponent("trials.csv"))
        try? FileOut.writeJSON(snap, to: dir.appendingPathComponent("route.json"))
        try? FileOut.writeJSON(["band": band.rawValue, "levelDBFS": "\(level)", "probe": "\(s.e5Probe)", "articulation": s.articulation],
                               to: dir.appendingPathComponent("meta.json"))

        ctx.working("特徴量を計算中…")
        let fs = rec.fs
        let y = trials.map { $0.label }
        let (imu, pas, act) = await Task.detached { () -> ([Sequence2D?], [Sequence2D?], [Sequence2D?]) in
            let imu = trials.map { Features.imu(motion, t0: $0.t0, t1: $0.t1) }
            let pas = trials.map { Features.passiveAudio(rec.slice(from: $0.t0, to: $0.t1), fs: fs) }
            var act: [Sequence2D?] = Array(repeating: nil, count: trials.count)
            if useProbe {
                let raw = trials.map { Features.echoFrames(rec.slice(from: $0.t0, to: $0.t1), fs: fs, band: band)?.frames }
                // 耳道の静的な形を除くため、全試行の中央値プロファイルを引く
                let allFrames = raw.compactMap { $0 }.flatMap { $0 }
                if let d = allFrames.first?.count {
                    let med = (0..<d).map { j in Float(DSP.median(allFrames.map { Double($0[j]) })) }
                    act = raw.map { $0?.map { f in (0..<d).map { f[$0] - med[$0] } } }
                }
            }
            return (imu, pas, act)
        }.value

        ctx.working("DTW 1-NN と置換検定(数十秒かかります)…")
        let reports = await Task.detached { () -> [ClassificationReport] in
            [Classifier.evaluate(modality: "IMU", seqs: imu, labels: y),
             Classifier.evaluate(modality: "パッシブ音", seqs: pas, labels: y),
             Classifier.evaluate(modality: "アクティブ反射", seqs: act, labels: y)]
        }.value
        try? FileOut.writeJSON(reports, to: dir.appendingPathComponent("classification.json"))

        for (rid, r) in zip(["R11a", "R11b", "R11c"], reports) {
            if let note = r.note {
                res.metric(r.modality, note)
                res.verdict(rid, .skipped, "\(r.modality): \(note)")
                continue
            }
            res.metric(r.modality, String(format: "精度 %.0f%% (チャンス %.0f%%), p = %.3f, n = %ld", r.accuracy * 100, r.chance * 100, r.pValue, r.nTrials))
            res.metric("\(r.modality) 混同行列", r.classes.enumerated().map { i, c in "\(c): \(r.confusion[i].map(String.init).joined(separator: " "))" }.joined(separator: " | "))
            res.verdict(rid, r.informative ? .pass : .fail,
                        "\(r.modality): \(Int(r.accuracy * 100))% vs チャンス \(Int(r.chance * 100))%, p = \(String(format: "%.3f", r.pValue))")
        }
        if useProbe && !band.representable(at: fs) {
            res.verdict("R11c", .skipped, "入力 fs \(Int(fs)) Hz ではプローブ帯を表現できない(E2 参照)")
        }
        if motion.isEmpty {
            res.verdict("R12", .unknown, "モーションが記録されていない")
        } else {
            let overlap = min(motion.last!.t, rec.firstSampleTime + Double(rec.samples.count) / fs) - max(motion.first!.t, rec.firstSampleTime)
            res.verdict("R12", overlap > 0 ? .pass : .fail, "音声とモーションを同一ホストクロックで記録(重なり \(fmt(overlap)) s)")
        }
        res.notes.append("p < 0.05 なら「単語の情報がある」。精度そのものは語彙・試行数・個人差に強く依存するので、製品精度の見積もりには使わない。")
        res.notes.append("装着し直して 2 回目を実行すると R13(再現性)の確認になる。")
        return finish(&res, dir: dir)
    }
}
