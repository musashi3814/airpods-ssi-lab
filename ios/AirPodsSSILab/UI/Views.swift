import SwiftUI

@main
struct SSILabApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        TabView {
            NavigationStack { ExperimentsView() }.tabItem { Label("実験", systemImage: "waveform") }
            NavigationStack { RequirementsView() }.tabItem { Label("要件", systemImage: "checklist") }
            NavigationStack { RunsView() }.tabItem { Label("記録", systemImage: "folder") }
            NavigationStack { SettingsView() }.tabItem { Label("設定", systemImage: "gearshape") }
        }
        .fullScreenCover(isPresented: Binding(get: { model.isRunning }, set: { _ in })) {
            RunnerView().environmentObject(model)
        }
    }
}

// MARK: 実験一覧

struct ExperimentsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            Section {
                Button {
                    model.run(ExperimentSpec.all.map { $0.id })
                } label: {
                    Label("E1〜E5 を順番に全部実行", systemImage: "play.circle.fill").font(.headline)
                }
                Text("各実験の終わりに結果が保存され、次の実験に自動で進みます。途中で中断しても、それまでの結果は残ります。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("個別に実行") {
                ForEach(ExperimentSpec.all) { spec in
                    NavigationLink {
                        ExperimentDetailView(spec: spec)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(spec.id)  \(spec.title)").font(.headline)
                                Spacer()
                                if let r = model.results[spec.id] { StatusDots(verdicts: r.verdicts) }
                            }
                            Text(spec.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
        .navigationTitle("AirPods SSI Lab")
    }
}

struct StatusDots: View {
    let verdicts: [Verdict]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(verdicts) { v in Image(systemName: v.status.symbol).foregroundStyle(v.status.color).font(.caption) }
        }
    }
}

struct ExperimentDetailView: View {
    @EnvironmentObject var model: AppModel
    let spec: ExperimentSpec
    var body: some View {
        List {
            Section {
                Text(spec.summary)
                LabeledContent("所要時間", value: spec.duration)
                LabeledContent("確認する要件", value: spec.requirements.joined(separator: ", "))
                Button { model.run([spec.id]) } label: { Label("実行", systemImage: "play.fill") }
            }
            if let r = model.results[spec.id] { ResultSections(result: r) }
        }
        .navigationTitle("\(spec.id) \(spec.title)")
    }
}

struct ResultSections: View {
    let result: ExperimentResult
    var body: some View {
        Section("判定 (\(result.date.formatted(date: .abbreviated, time: .shortened)))") {
            ForEach(result.verdicts) { v in
                HStack(alignment: .top) {
                    Image(systemName: v.status.symbol).foregroundStyle(v.status.color)
                    VStack(alignment: .leading) {
                        Text("\(v.requirement)  \(Requirement.all.first { $0.id == v.requirement }?.title ?? "")").font(.subheadline.bold())
                        Text(v.detail).font(.caption)
                    }
                }
            }
        }
        Section("計測値") {
            ForEach(result.metrics) { m in
                VStack(alignment: .leading) {
                    Text(m.name).font(.caption).foregroundStyle(.secondary)
                    Text(m.value).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
        }
        if !result.notes.isEmpty {
            Section("メモ") { ForEach(result.notes, id: \.self) { Text($0).font(.caption) } }
        }
        Section { Text("保存先: Runs/\(result.runDir)").font(.caption2).foregroundStyle(.secondary) }
    }
}

// MARK: 実行中のガイド画面

struct RunnerView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { RunnerContent(ctx: model.ctx) }
}

struct RunnerContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ctx: ExperimentContext

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(model.runningID.flatMap { id in ExperimentSpec.all.first { $0.id == id }.map { "\($0.id) \($0.title)" } } ?? "")
                    .font(.headline)
                Spacer()
                if model.queue.count > 1 { Text("残り \(model.queue.count - 1) 件").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            switch ctx.phase {
            case .idle, .done:
                ProgressView()
            case let .instruction(title, body):
                Text(title).font(.title2.bold())
                ScrollView { Text(body).font(.body).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 320)
                Button { ctx.next() } label: { Text("次へ").frame(maxWidth: .infinity).padding(.vertical, 8) }
                    .buttonStyle(.borderedProminent)
            case let .countdown(title, body, remaining, total):
                Text(title).font(.title3).foregroundStyle(.secondary)
                Text(body).font(.system(size: 56, weight: .bold)).minimumScaleFactor(0.3).lineLimit(2).multilineTextAlignment(.center)
                ProgressView(value: max(0, total - remaining), total: total).progressViewStyle(.linear)
                Text(String(format: "%.1f s", max(0, remaining))).font(.caption.monospacedDigit())
            case let .working(msg):
                ProgressView()
                Text(msg).font(.callout)
            }
            Spacer()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(ctx.log.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.caption2.monospaced()).id(i)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
                .onChange(of: ctx.log.count) { _, n in proxy.scrollTo(n - 1) }
            }
            Button(role: .destructive) { model.cancel() } label: { Text("中断") }
        }
        .padding()
    }
}

// MARK: 要件チェックリスト

struct RequirementsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            Section {
                Text("サイレントスピーチに必要なデータ要件と、この iPhone + AirPods での最新の判定。詳細は docs/requirements.md。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(Dictionary(grouping: Requirement.all, by: { $0.group }).keys.sorted()), id: \.self) { g in
                Section(g) {
                    ForEach(Requirement.all.filter { $0.group == g }) { req in
                        let v = model.verdict(for: req.id)
                        HStack(alignment: .top) {
                            Image(systemName: (v?.0.status ?? .unknown).symbol)
                                .foregroundStyle(v == nil ? Color.secondary : v!.0.status.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(req.id)  \(req.title)").font(.subheadline.bold())
                                Text("基準: \(req.threshold)").font(.caption2).foregroundStyle(.secondary)
                                Text(v.map { "\($0.1.experimentID): \($0.0.detail)" } ?? "未測定(\(req.experiment) で確認)").font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("要件チェック")
        .refreshable { model.reload() }
    }
}

// MARK: 記録

struct RunsView: View {
    @EnvironmentObject var model: AppModel
    @State private var runs: [URL] = []
    @State private var shareURL: URL?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Button { export(runs, name: "ssilab_all") } label: { Label("すべてを zip で共有", systemImage: "square.and.arrow.up") }
                    .disabled(runs.isEmpty)
                Text("「ファイル」アプリの「このiPhone内 > SSI Lab > Runs」からも取り出せます。解析は analysis/ の Python スクリプトで。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("実行記録") {
                ForEach(runs, id: \.self) { dir in
                    NavigationLink {
                        RunDetailView(dir: dir)
                    } label: {
                        Text(dir.lastPathComponent).font(.callout.monospaced())
                    }
                    .swipeActions {
                        Button("共有") { export([dir], name: dir.lastPathComponent) }.tint(.blue)
                        Button("削除", role: .destructive) {
                            try? FileManager.default.removeItem(at: dir)
                            refresh()
                        }
                    }
                }
            }
        }
        .navigationTitle("記録")
        .onAppear(perform: refresh)
        .refreshable { refresh() }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { item in
            ShareSheet(items: [item.url])
        }
        .alert("エラー", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func refresh() {
        runs = RunStore.shared.listRuns()
        model.reload()
    }

    private func export(_ dirs: [URL], name: String) {
        do { shareURL = try RunStore.shared.zip(dirs, name: name) } catch { self.error = error.localizedDescription }
    }
}

struct ShareItem: Identifiable { let url: URL; var id: URL { url } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct RunDetailView: View {
    let dir: URL
    var body: some View {
        List {
            if let r = RunStore.shared.loadResult(dir) { ResultSections(result: r) }
            Section("ファイル") {
                ForEach((try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? [], id: \.self) { f in
                    Text(f).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle(dir.lastPathComponent)
    }
}

// MARK: 設定

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SettingsForm(settings: model.settings)
    }
}

struct SettingsForm: View {
    @ObservedObject var settings: LabSettings
    var body: some View {
        Form {
            Section("プローブ") {
                Picker("帯域", selection: $settings.probeBandRaw) {
                    ForEach(ProbeBand.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Stepper(value: $settings.levelDBFS, in: -60 ... -10, step: 5) {
                    Text("レベル \(Int(settings.levelDBFS)) dBFS")
                }
                Text("超音波は聞こえなくても耳に届いています。音量は控えめにし、違和感があればすぐ外してください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("E3 / E5 の録音構成") {
                Picker("構成", selection: $settings.captureConfigName) {
                    ForEach(AudioSessionConfig.matrix) { Text($0.name).tag($0.name) }
                }
                Text("E2 の「最良構成」を選ぶのがおすすめ。").font(.caption).foregroundStyle(.secondary)
            }
            Section("E5 単語情報の検定") {
                TextField("単語(カンマ区切り)", text: $settings.wordsText)
                Stepper("1 単語あたり \(settings.reps) 回", value: $settings.reps, in: 3...30)
                Picker("発話様式", selection: $settings.articulation) {
                    ForEach(["無声(口パク)", "ささやき", "普通の声"], id: \.self) { Text($0) }
                }
                Toggle("プローブを流す(アクティブ反射)", isOn: $settings.e5Probe)
            }
            Section {
                Link("要件と実験の説明 (GitHub)", destination: URL(string: "https://github.com/musashi3814/airpods-ssi-lab/blob/main/docs/requirements.md")!)
            }
        }
        .navigationTitle("設定")
    }
}
