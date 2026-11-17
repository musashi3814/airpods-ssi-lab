import SwiftUI

/// 実験の実行・連続実行・結果の集約を担う。
@MainActor
final class AppModel: ObservableObject {
    let settings = LabSettings()
    let ctx: ExperimentContext
    @Published var results: [String: ExperimentResult] = RunStore.shared.latestResults()
    @Published var runningID: String?
    @Published var queue: [String] = []
    @Published var lastError: String?
    private var task: Task<Void, Never>?

    init() { ctx = ExperimentContext(settings: settings) }

    var isRunning: Bool { runningID != nil }

    func run(_ ids: [String]) {
        guard task == nil else { return }
        queue = ids
        ctx.log = []
        task = Task {
            for id in ids {
                guard let spec = ExperimentSpec.all.first(where: { $0.id == id }) else { continue }
                runningID = id
                ctx.say("▶︎ \(spec.id) \(spec.title)")
                do {
                    let r = try await spec.run(ctx)
                    results[id] = r
                    ctx.say("✓ \(spec.id) 完了")
                } catch is CancellationError {
                    ctx.say("中断しました")
                    break
                } catch {
                    lastError = "\(spec.id): \(error.localizedDescription)"
                    ctx.say("✗ \(spec.id): \(error.localizedDescription)")
                }
                queue.removeFirst()
            }
            runningID = nil
            queue = []
            ctx.phase = .done
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    /// 要件ごとの最新判定(後に実行した実験の判定で上書き)。
    func verdict(for rid: String) -> (Verdict, ExperimentResult)? {
        results.values
            .flatMap { r in r.verdicts.filter { $0.requirement == rid }.map { ($0, r) } }
            .max { $0.1.date < $1.1.date }
    }

    func reload() { results = RunStore.shared.latestResults() }
}
