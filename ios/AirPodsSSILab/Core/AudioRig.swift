import AVFoundation
import Foundation

/// 全実験で共通の時計。AVAudioTime の hostTime と CMDeviceMotion.timestamp は
/// どちらも mach_absolute_time 系なので、秒に直せば同じ軸で比べられる。
enum HostClock {
    static func seconds(_ hostTime: UInt64) -> Double { AVAudioTime.seconds(forHostTime: hostTime) }
    static func now() -> Double { seconds(mach_absolute_time()) }
    static func hostTime(_ seconds: Double) -> UInt64 { AVAudioTime.hostTime(forSeconds: seconds) }
}

/// AVAudioSession の構成。E2 ではこれを総当たりする。
struct AudioSessionConfig: Identifiable, Codable, Hashable {
    enum Route: String, Codable {
        case highQuality        // iOS 26 の bluetoothHighQualityRecording
        case hfp                // 従来の Bluetooth ヘッドセット (HFP)
        case builtInMic         // 出力は AirPods (A2DP)、入力は iPhone 内蔵マイク(出力帯域の確認用)
    }
    enum Mode: String, Codable { case standard, measurement, voiceChat }

    var id: String { name }
    let name: String
    let route: Route
    let mode: Mode
    let voiceProcessing: Bool
    let note: String

    var avMode: AVAudioSession.Mode {
        switch mode {
        case .standard: return .default
        case .measurement: return .measurement
        case .voiceChat: return .voiceChat
        }
    }

    /// 実際に適用できたオプションと、高品質録音が使えたかを返す。
    func categoryOptions() -> (AVAudioSession.CategoryOptions, Bool) {
        switch route {
        case .highQuality:
            if #available(iOS 26.0, *) {
                return ([.bluetoothHighQualityRecording, .allowBluetoothA2DP], true)
            }
            return ([.allowBluetoothA2DP], false)
        case .hfp:
            return ([.allowBluetooth], false)
        case .builtInMic:
            return ([.allowBluetoothA2DP], false)
        }
    }

    static let matrix: [AudioSessionConfig] = [
        .init(name: "HQ / default", route: .highQuality, mode: .standard, voiceProcessing: false,
              note: "iOS 26 高品質 Bluetooth 録音。本命"),
        .init(name: "HQ / measurement", route: .highQuality, mode: .measurement, voiceProcessing: false,
              note: "システム側の音声処理を最小化するモード"),
        .init(name: "HQ / voice processing", route: .highQuality, mode: .standard, voiceProcessing: true,
              note: "AEC を明示的にオン(プローブが消えるかの対照)"),
        .init(name: "HFP / default", route: .hfp, mode: .standard, voiceProcessing: false,
              note: "従来の通話経路 (16/24 kHz)"),
        .init(name: "HFP / measurement", route: .hfp, mode: .measurement, voiceProcessing: false, note: ""),
        .init(name: "HFP / voiceChat", route: .hfp, mode: .voiceChat, voiceProcessing: false,
              note: "通話アプリと同じ処理"),
    ]

    static let outputCheck = AudioSessionConfig(
        name: "A2DP out / iPhone mic", route: .builtInMic, mode: .measurement, voiceProcessing: false,
        note: "AirPods を外して iPhone 下端のマイクに近づけ、出力が高域を出しているかを見る")
}

struct PortInfo: Codable {
    let type: String
    let name: String
    let channels: Int
    let dataSources: [String]
}

/// 実行時に観測した経路・形式。E1 の結果そのもの。
struct RouteSnapshot: Codable {
    var config: String = ""
    var hqOptionApplied = false
    var inputs: [PortInfo] = []
    var outputs: [PortInfo] = []
    var availableInputs: [PortInfo] = []
    var sessionSampleRate: Double = 0
    var engineInputFs: Double = 0
    var engineOutputFs: Double = 0
    var engineInputChannels: Int = 0
    var ioBufferDuration: Double = 0
    var inputLatency: Double = 0
    var outputLatency: Double = 0
    var voiceProcessing = false
    var inputIsAirPods = false
    var outputIsAirPods = false
    var error: String?
}

struct Recording {
    var samples: [Float]
    var fs: Double
    /// samples[0] のホスト時刻 [s]
    var firstSampleTime: Double
    /// 再生開始のホスト時刻 [s](再生なしなら nil)
    var playStartTime: Double?
    var route: RouteSnapshot

    func index(at hostSeconds: Double) -> Int { Int(((hostSeconds - firstSampleTime) * fs).rounded()) }

    func slice(from t0: Double, to t1: Double) -> [Float] {
        let a = max(0, index(at: t0)), b = min(samples.count, index(at: t1))
        return a < b ? Array(samples[a..<b]) : []
    }
}

/// 再生と録音を同時に行う。録音はハードウェアの入力形式のまま(チャンネル 0)取る。
final class AudioRig {
    private var engine: AVAudioEngine?
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var firstTime: Double?
    private var snapshot = RouteSnapshot()
    private var playStart: Double?

    private static func isAirPods(_ p: AVAudioSessionPortDescription) -> Bool {
        let bt: [AVAudioSession.Port] = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]
        return bt.contains(p.portType) || p.portName.localizedCaseInsensitiveContains("airpods")
    }

    private static func info(_ p: AVAudioSessionPortDescription) -> PortInfo {
        PortInfo(type: p.portType.rawValue, name: p.portName, channels: p.channels?.count ?? 0,
                 dataSources: p.dataSources?.map { $0.dataSourceName } ?? [])
    }

    /// セッションを構成して経路を観測する(録音はしない)。E1 で使う。
    static func configureSession(_ config: AudioSessionConfig) async -> RouteSnapshot {
        var snap = RouteSnapshot()
        snap.config = config.name
        let s = AVAudioSession.sharedInstance()
        let (opts, hq) = config.categoryOptions()
        snap.hqOptionApplied = hq
        do {
            try s.setCategory(.playAndRecord, mode: config.avMode, options: opts)
            try? s.setPreferredSampleRate(48_000)
            try s.setActive(true)
            try await Task.sleep(nanoseconds: 400_000_000)  // 経路切り替えが落ち着くのを待つ
            let avail = s.availableInputs ?? []
            snap.availableInputs = avail.map(info)
            let want: AVAudioSessionPortDescription?
            switch config.route {
            case .builtInMic: want = avail.first { $0.portType == .builtInMic }
            default: want = avail.first(where: isAirPods)
            }
            if let want { try? s.setPreferredInput(want) }
            try await Task.sleep(nanoseconds: 300_000_000)
        } catch {
            snap.error = "\(error)"
        }
        snap.inputs = s.currentRoute.inputs.map(info)
        snap.outputs = s.currentRoute.outputs.map(info)
        snap.inputIsAirPods = s.currentRoute.inputs.contains(where: isAirPods)
        snap.outputIsAirPods = s.currentRoute.outputs.contains(where: isAirPods)
        snap.sessionSampleRate = s.sampleRate
        snap.ioBufferDuration = s.ioBufferDuration
        snap.inputLatency = s.inputLatency
        snap.outputLatency = s.outputLatency
        return snap
    }

    /// 録音を開始する。playback があれば startDelay 秒後に再生する(loop なら繰り返し)。
    /// playback は「出力のサンプリング周波数」を受け取って信号を返すクロージャ。
    func start(config: AudioSessionConfig,
               playback: ((Double) -> [Float])?,
               loop: Bool = false,
               startDelay: Double = 0.5) async throws -> RouteSnapshot {
        var snap = await Self.configureSession(config)
        if let e = snap.error { throw NSError(domain: "AudioRig", code: 1, userInfo: [NSLocalizedDescriptionKey: e]) }

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(config.voiceProcessing)
        snap.voiceProcessing = config.voiceProcessing

        let inFmt = input.outputFormat(forBus: 0)
        let outFs = engine.outputNode.outputFormat(forBus: 0).sampleRate
        snap.engineInputFs = inFmt.sampleRate
        snap.engineInputChannels = Int(inFmt.channelCount)
        snap.engineOutputFs = outFs
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
            throw NSError(domain: "AudioRig", code: 2, userInfo: [NSLocalizedDescriptionKey: "入力が見つからない(AirPods 接続とマイク許可を確認)"])
        }

        engine.attach(player)
        let monoOut = AVAudioFormat(standardFormatWithSampleRate: outFs, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: monoOut)

        lock.lock()
        buffer = []
        buffer.reserveCapacity(Int(inFmt.sampleRate * 60))
        firstTime = nil
        playStart = nil
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buf, time in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            self.lock.lock()
            if self.firstTime == nil, time.isHostTimeValid {
                self.firstTime = HostClock.seconds(time.hostTime)
            }
            self.buffer.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
            self.lock.unlock()
        }

        engine.prepare()
        try engine.start()

        if let playback {
            let sig = playback(outFs)
            let pcm = AVAudioPCMBuffer(pcmFormat: monoOut, frameCapacity: AVAudioFrameCount(sig.count))!
            pcm.frameLength = AVAudioFrameCount(sig.count)
            sig.withUnsafeBufferPointer { src in
                pcm.floatChannelData![0].update(from: src.baseAddress!, count: sig.count)
            }
            player.scheduleBuffer(pcm, at: nil, options: loop ? [.loops] : [], completionHandler: nil)
            let t = HostClock.now() + startDelay
            player.play(at: AVAudioTime(hostTime: HostClock.hostTime(t)))
            lock.lock(); playStart = t; lock.unlock()
        }
        snapshot = snap
        return snap
    }

    func stop() -> Recording {
        player.stop()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.detach(player)
        }
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        lock.lock()
        defer { lock.unlock() }
        return Recording(samples: buffer, fs: snapshot.engineInputFs,
                         firstSampleTime: firstTime ?? HostClock.now(),
                         playStartTime: playStart, route: snapshot)
    }

    /// 決まった長さだけ録音する(再生つき)。
    func record(config: AudioSessionConfig, seconds: Double,
                playback: ((Double) -> [Float])?, loop: Bool = false) async throws -> Recording {
        _ = try await start(config: config, playback: playback, loop: loop)
        try await Task.sleep(nanoseconds: UInt64((seconds + 0.5) * 1e9))
        return stop()
    }
}
