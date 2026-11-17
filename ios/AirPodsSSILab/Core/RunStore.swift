import Foundation

/// 実験結果の保存先。Documents/Runs/<日時>_<実験ID>/ に WAV・CSV・JSON を書く。
/// UIFileSharingEnabled を有効にしているので「ファイル」アプリからも見える。
final class RunStore {
    static let shared = RunStore()

    let root: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let r = docs.appendingPathComponent("Runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        return r
    }()

    func newRunDir(_ experimentID: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        let dir = root.appendingPathComponent("\(f.string(from: Date()))_\(experimentID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func listRuns() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func loadResult(_ dir: URL) -> ExperimentResult? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("result.json")) else { return nil }
        return try? JSONDecoder.iso.decode(ExperimentResult.self, from: d)
    }

    func latestResults() -> [String: ExperimentResult] {
        var out: [String: ExperimentResult] = [:]
        for dir in listRuns() {
            if let r = loadResult(dir), out[r.experimentID] == nil { out[r.experimentID] = r }
        }
        return out
    }

    /// 共有用にディレクトリを zip にする(NSFileCoordinator の forUploading を利用)。
    func zip(_ dirs: [URL], name: String) throws -> URL {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for d in dirs {
            try FileManager.default.copyItem(at: d, to: staging.appendingPathComponent(d.lastPathComponent))
        }
        var result: URL?
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordError) { zipURL in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).zip")
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: zipURL, to: dest); result = dest } catch { copyError = error }
        }
        if let e = coordError ?? (copyError as NSError?) { throw e }
        return result!
    }
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }()
}

enum FileOut {
    /// 32-bit float モノラル WAV を書く。
    static func writeWAV(_ x: [Float], fs: Double, to url: URL) throws {
        var d = Data()
        func u32(_ v: UInt32) { var le = v.littleEndian; d.append(Data(bytes: &le, count: 4)) }
        func u16(_ v: UInt16) { var le = v.littleEndian; d.append(Data(bytes: &le, count: 2)) }
        let dataBytes = UInt32(x.count * 4)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(1)
        u32(UInt32(fs)); u32(UInt32(fs) * 4); u16(4); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        x.withUnsafeBufferPointer { d.append($0) }
        try d.write(to: url)
    }

    static func writeJSON<T: Encodable>(_ v: T, to url: URL) throws {
        try JSONEncoder.pretty.encode(v).write(to: url)
    }

    static func writeLines(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeMotionCSV(_ s: [MotionSample], to url: URL) throws {
        try writeLines([MotionSample.csvHeader] + s.map { $0.csv }, to: url)
    }
}
