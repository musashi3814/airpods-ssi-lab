import Foundation

/// E3: 届いているマイク信号が「耳の内側(ANC 後)」か「外向き」かを推定する。
/// ANC をオン/外部音取り込みに切り替えたとき、外来音のレベルがどれだけ変わるかを見る。
/// 外向きマイクなら ANC の影響を受けないので変化は小さい。
enum E3MicLocation {
    static let spec = ExperimentSpec(
        id: "E3", title: "マイク位置の推定",
        summary: "外来音を流した状態で ANC オン/外部音取り込みを切り替え、マイク信号が耳の内側か外側かを推定する。ささやきが録れるかも確認する。",
        requirements: ["R6", "R7"], duration: "約 2 分(手動操作あり)", run: run)

    struct Step { let key, title, body: String; let seconds: Double }

    @MainActor static func run(_ ctx: ExperimentContext) async throws -> ExperimentResult {
        var res = ExperimentResult(experimentID: "E3", title: spec.title)
        let dir = RunStore.shared.newRunDir("E3")
        let cfg = ctx.settings.captureConfig
        let rig = AudioRig()
        res.metric("録音構成", cfg.name)

        try await ctx.instruct("準備", """
        別の機器(PC やスマホのスピーカー)で、ホワイトノイズか音楽を中くらいの音量で流し続けてください。AirPods から 1 m ほど離して置きます。
        ノイズコントロールはコントロールセンター(音量バーを長押し)で切り替えます。
        各ステップは「次へ」で録音が始まります。
        """)

        let steps: [Step] = [
            .init(key: "ext_anc", title: "外来音 + ノイズキャンセリング", body: "ノイズコントロールを「ノイズキャンセリング」にしてから「次へ」。黙って動かずに。", seconds: 6),
            .init(key: "ext_transparency", title: "外来音 + 外部音取り込み", body: "「外部音取り込み」に切り替えてから「次へ」。黙って動かずに。", seconds: 6),
            .init(key: "quiet", title: "無音", body: "外来音を止めてから「次へ」。ノイズコントロールはそのままで構いません。", seconds: 5),
            .init(key: "hum", title: "口を閉じてハミング", body: "口を閉じたまま「んー」と低めの声で鳴らし続けてください。", seconds: 5),
            .init(key: "whisper", title: "ささやき", body: "ささやき声で「あいうえお」を繰り返してください(声帯は鳴らさない)。", seconds: 5),
            .init(key: "voice", title: "普通の声", body: "普通の声で「あいうえお」を繰り返してください。", seconds: 5),
        ]
        var psd: [String: [Float]] = [:]
        var fsUsed: Double = 0
        let nfft = 2048
        for st in steps {
            try await ctx.instruct(st.title, st.body)
            _ = try await rig.start(config: cfg, playback: nil)
            try await ctx.countdown(st.title, "録音中…", seconds: st.seconds)
            let rec = rig.stop()
            fsUsed = rec.fs
            let body = Array(rec.samples.dropFirst(Int(0.5 * rec.fs)))  // 切り替え直後を捨てる
            psd[st.key] = DSP.welch(body, nfft: nfft)
            try? FileOut.writeWAV(rec.samples, fs: rec.fs, to: dir.appendingPathComponent("\(st.key).wav"))
        }
        let fs = fsUsed
        func db(_ k: String, _ lo: Double, _ hi: Double) -> Double {
            guard let p = psd[k] else { return .nan }
            return DSP.bandDB(p, fs: fs, nfft: nfft, lo: lo, hi: min(hi, 0.47 * fs))
        }
        // スペクトルそのものも保存(Python で詳しく見る用)
        let spectra = psd.mapValues { p in p.map { 10 * log10(Double($0) + 1e-20) } }
        try? FileOut.writeJSON(["fs": [fs], "nfft": [Double(nfft)]].merging(spectra) { a, _ in a }, to: dir.appendingPathComponent("spectra_db.json"))

        let extTrans = db("ext_transparency", 100, 1000) - db("quiet", 100, 1000)
        let ancDelta = db("ext_transparency", 100, 1000) - db("ext_anc", 100, 1000)
        let whisperSNR = db("whisper", 2000, 8000) - db("quiet", 2000, 8000)
        let humLow = db("hum", 80, 400) - db("quiet", 80, 400)
        let voiceHigh = db("voice", 2000, 8000) - db("quiet", 2000, 8000)
        res.metric("入力 fs", fs, "%.0f")
        res.metric("外来音の大きさ(取り込み時, 0.1–1 kHz) [dB]", extTrans)
        res.metric("ANC による外来音の減少(0.1–1 kHz) [dB]", ancDelta)
        res.metric("ハミング低域 (80–400 Hz) [dB]", humLow)
        res.metric("ささやき 2–8 kHz SNR [dB]", whisperSNR)
        res.metric("普通の声 2–8 kHz SNR [dB]", voiceHigh)
        res.metric("ハミング低域 − 声の高域 [dB](大きいほど閉塞効果的)", humLow - voiceHigh)

        if !(extTrans > 10) {
            res.verdict("R6", .unknown, "外来音がほとんど録れていない(\(fmt(extTrans)) dB)。音量を上げて再試行するか、通話用ノイズ抑圧で消されている可能性")
        } else if ancDelta > 10 {
            res.verdict("R6", .pass, "ANC で外来音が \(fmt(ancDelta)) dB 減った → 耳の内側(ANC 後)の信号を含む")
        } else if ancDelta < 3 {
            res.verdict("R6", .fail, "ANC でも外来音が変わらない(\(fmt(ancDelta)) dB)→ 外向きマイクの信号と推定")
        } else {
            res.verdict("R6", .unknown, "中間的な変化 \(fmt(ancDelta)) dB。ビームフォーミング出力に内側マイクが一部混ざっている可能性")
        }
        res.verdict("R7", whisperSNR > 10 ? .pass : .fail, "ささやき 2–8 kHz SNR \(fmt(whisperSNR)) dB")
        res.notes.append("判定はヒューリスティック。iOS が通話モードのノイズ抑圧をかけていると、外来音そのものが消えて判定不能になる。")
        return finish(&res, dir: dir)
    }
}
