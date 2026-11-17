import Foundation
import SwiftUI

// MARK: - 要件カタログ(docs/requirements.md と同じ ID)

struct Requirement: Identifiable {
    let id: String
    let group: String
    let title: String
    let threshold: String
    let experiment: String

    static let all: [Requirement] = [
        .init(id: "R1", group: "アクティブ音響", title: "マイク fs ≥ 47 kHz", threshold: "入力 fs ≥ 47 kHz の構成がある", experiment: "E1"),
        .init(id: "R2", group: "アクティブ音響", title: "マイクがプローブ帯を通す", threshold: "プローブ帯 SNR > 10 dB", experiment: "E2"),
        .init(id: "R3", group: "アクティブ音響", title: "スピーカーがプローブ帯を出す", threshold: "内蔵マイクでプローブ帯 SNR > 10 dB", experiment: "E2"),
        .init(id: "R4", group: "アクティブ音響", title: "プローブがエコー除去で消えない", threshold: "整合フィルタ ピーク/中央値 > 10", experiment: "E2"),
        .init(id: "R5", group: "アクティブ音響", title: "遅延が安定", threshold: "遅延の揺らぎ < 0.1 ms", experiment: "E2"),
        .init(id: "R6", group: "アクティブ音響", title: "マイクが耳の内側の音を拾う", threshold: "ANC オン/オフで外来音が 10 dB 以上変化", experiment: "E3"),
        .init(id: "R7", group: "パッシブ音響", title: "ささやきが録れる", threshold: "ささやきの 2–8 kHz SNR > 10 dB", experiment: "E3"),
        .init(id: "R8", group: "IMU", title: "IMU レート ≥ 50 Hz", threshold: "実効レート ≥ 50 Hz", experiment: "E4"),
        .init(id: "R9", group: "IMU", title: "静止中も途切れない", threshold: "200 ms 超のギャップなし", experiment: "E4"),
        .init(id: "R10", group: "IMU", title: "口の動きが IMU に出る", threshold: "口パク/安静 > 3 dB", experiment: "E4"),
        .init(id: "R11a", group: "単語情報", title: "IMU で単語を区別できる", threshold: "LOO 精度 > チャンス, p < 0.05", experiment: "E5"),
        .init(id: "R11b", group: "単語情報", title: "パッシブ音で区別できる", threshold: "同上", experiment: "E5"),
        .init(id: "R11c", group: "単語情報", title: "アクティブ反射で区別できる", threshold: "同上", experiment: "E5"),
        .init(id: "R12", group: "単語情報", title: "音声と IMU の同期", threshold: "同一ホストクロックで記録", experiment: "E5"),
    ]
}

// MARK: - 結果モデル

enum VerdictStatus: String, Codable {
    case pass, fail, unknown, skipped

    var symbol: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        case .skipped: return "minus.circle"
        }
    }
    var color: Color {
        switch self {
        case .pass: return .green
        case .fail: return .red
        case .unknown: return .orange
        case .skipped: return .gray
        }
    }
}

struct Verdict: Codable, Identifiable {
    var id: String { requirement }
    let requirement: String
    let status: VerdictStatus
    let detail: String
}

struct Metric: Codable, Identifiable {
    var id: String { name }
    let name: String
    let value: String
}

struct ExperimentResult: Codable {
    var experimentID: String
    var title: String
    var date = Date()
    var runDir = ""
    var metrics: [Metric] = []
    var verdicts: [Verdict] = []
    var notes: [String] = []

    mutating func metric(_ name: String, _ v: Double, _ fmt: String = "%.1f") {
        metrics.append(Metric(name: name, value: v.isFinite ? String(format: fmt, v) : "n/a"))
    }
    mutating func metric(_ name: String, _ v: String) { metrics.append(Metric(name: name, value: v)) }
    mutating func verdict(_ r: String, _ s: VerdictStatus, _ d: String) {
        verdicts.removeAll { $0.requirement == r }
        verdicts.append(Verdict(requirement: r, status: s, detail: d))
    }
}

// MARK: - 実験設定

final class LabSettings: ObservableObject {
    @AppStorage("probeBand") var probeBandRaw = ProbeBand.ultrasonic.rawValue
    @AppStorage("levelDBFS") var levelDBFS = -30.0
    @AppStorage("e5Words") var wordsText = "はい,いいえ,つぎ,もどる,ストップ"
    @AppStorage("e5Reps") var reps = 8
    @AppStorage("e5Articulation") var articulation = "無声(口パク)"
    @AppStorage("e5Probe") var e5Probe = true
    @AppStorage("captureConfig") var captureConfigName = AudioSessionConfig.matrix[0].name

    var probeBand: ProbeBand { ProbeBand(rawValue: probeBandRaw) ?? .ultrasonic }
    var words: [String] { wordsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    var captureConfig: AudioSessionConfig {
        (AudioSessionConfig.matrix + [AudioSessionConfig.outputCheck]).first { $0.name == captureConfigName } ?? AudioSessionConfig.matrix[0]
    }
}

// MARK: - 実験と UI の橋渡し

/// 実験コードはこのコンテキスト経由でユーザへの指示・カウントダウンを出す。
@MainActor
final class ExperimentContext: ObservableObject {
    enum Phase: Equatable {
        case idle
        case instruction(title: String, body: String)
        case countdown(title: String, body: String, remaining: Double, total: Double)
        case working(String)
        case done
    }

    @Published var phase: Phase = .idle
    @Published var log: [String] = []
    let settings: LabSettings
    private var waiter: CheckedContinuation<Void, Error>?

    init(settings: LabSettings) { self.settings = settings }

    func say(_ s: String) { log.append(s) }

    /// 指示を出し、「次へ」が押されるまで待つ。
    func instruct(_ title: String, _ body: String) async throws {
        try Task.checkCancellation()
        phase = .instruction(title: title, body: body)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in waiter = c }
        } onCancel: {
            Task { @MainActor in self.waiter?.resume(throwing: CancellationError()); self.waiter = nil }
        }
    }

    func next() {
        waiter?.resume()
        waiter = nil
    }

    /// 秒数だけカウントダウンを表示する。返り値は [開始, 終了] のホスト時刻。
    @discardableResult
    func countdown(_ title: String, _ body: String, seconds: Double) async throws -> (Double, Double) {
        let t0 = HostClock.now()
        var remaining = seconds
        while remaining > 0 {
            try Task.checkCancellation()
            phase = .countdown(title: title, body: body, remaining: remaining, total: seconds)
            try await Task.sleep(nanoseconds: 50_000_000)
            remaining = seconds - (HostClock.now() - t0)
        }
        return (t0, HostClock.now())
    }

    func working(_ s: String) { phase = .working(s) }
}

struct ExperimentSpec: Identifiable {
    let id: String
    let title: String
    let summary: String
    let requirements: [String]
    let duration: String
    let run: @MainActor (ExperimentContext) async throws -> ExperimentResult

    static let all: [ExperimentSpec] = [E1RouteFormat.spec, E2ProbeMatrix.spec, E3MicLocation.spec, E4Motion.spec, E5InfoTest.spec]
}

/// 結果を runDir に保存して返す共通処理。
func finish(_ result: inout ExperimentResult, dir: URL) -> ExperimentResult {
    result.runDir = dir.lastPathComponent
    try? FileOut.writeJSON(result, to: dir.appendingPathComponent("result.json"))
    return result
}
