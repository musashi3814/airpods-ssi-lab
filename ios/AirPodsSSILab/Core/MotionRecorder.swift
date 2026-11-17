import CoreMotion
import Foundation

struct MotionSample {
    let t: Double                     // ホスト時刻 [s](CMLogItem.timestamp と同じ軸)
    let ax, ay, az: Float             // userAcceleration [g]
    let gx, gy, gz: Float             // rotationRate [rad/s]
    let roll, pitch, yaw: Float       // attitude [rad]
    let qw, qx, qy, qz: Float
    let sensorLocation: Int           // 0 default, 1 左, 2 右(iOS 17+)

    static let csvHeader = "t,ax,ay,az,gx,gy,gz,roll,pitch,yaw,qw,qx,qy,qz,location"
    var csv: String { "\(t),\(ax),\(ay),\(az),\(gx),\(gy),\(gz),\(roll),\(pitch),\(yaw),\(qw),\(qx),\(qy),\(qz),\(sensorLocation)" }
}

/// CMHeadphoneMotionManager(公開 API)で AirPods のモーションを記録する。
final class MotionRecorder: NSObject, CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var samples: [MotionSample] = []
    private(set) var connected = false
    private(set) var lastError: String?

    override init() {
        super.init()
        queue.maxConcurrentOperationCount = 1
        manager.delegate = self
    }

    var available: Bool { manager.isDeviceMotionAvailable }
    var authorization: String {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) { connected = true }
    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) { connected = false }

    func start() {
        lock.lock(); samples = []; lock.unlock()
        lastError = nil
        manager.startDeviceMotionUpdates(to: queue) { [weak self] m, err in
            guard let self else { return }
            if let err { self.lastError = "\(err)"; return }
            guard let m else { return }
            let q = m.attitude.quaternion
            var loc = 0
            if #available(iOS 17.0, *) { loc = m.sensorLocation.rawValue }
            let s = MotionSample(
                t: m.timestamp,
                ax: Float(m.userAcceleration.x), ay: Float(m.userAcceleration.y), az: Float(m.userAcceleration.z),
                gx: Float(m.rotationRate.x), gy: Float(m.rotationRate.y), gz: Float(m.rotationRate.z),
                roll: Float(m.attitude.roll), pitch: Float(m.attitude.pitch), yaw: Float(m.attitude.yaw),
                qw: Float(q.w), qx: Float(q.x), qy: Float(q.y), qz: Float(q.z),
                sensorLocation: loc)
            self.lock.lock(); self.samples.append(s); self.lock.unlock()
        }
    }

    @discardableResult
    func stop() -> [MotionSample] {
        manager.stopDeviceMotionUpdates()
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    func snapshot() -> [MotionSample] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}

enum MotionStats {
    /// 実効レートとサンプル間隔の統計。
    static func timing(_ s: [MotionSample]) -> [String: Double] {
        guard s.count > 2 else { return ["count": Double(s.count)] }
        let dts = zip(s.dropFirst(), s).map { $0.t - $1.t }
        let span = s.last!.t - s.first!.t
        return [
            "count": Double(s.count),
            "rate_hz": Double(s.count - 1) / max(span, 1e-9),
            "dt_p50_ms": DSP.median(dts) * 1000,
            "dt_p95_ms": DSP.percentile(dts, 95) * 1000,
            "dt_max_ms": (dts.max() ?? 0) * 1000,
            "gaps_over_200ms": Double(dts.filter { $0 > 0.2 }.count),
        ]
    }

    static func window(_ s: [MotionSample], _ t0: Double, _ t1: Double) -> [MotionSample] {
        s.filter { $0.t >= t0 && $0.t < t1 }
    }

    /// 区間内の |userAccel| と |rotationRate| の RMS(平均を引いた後)。
    static func energy(_ s: [MotionSample]) -> (accel: Double, gyro: Double) {
        guard s.count > 1 else { return (.nan, .nan) }
        func rmsDetrended(_ v: [Float]) -> Double {
            let m = v.reduce(0, +) / Float(v.count)
            return Double(sqrt(v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(v.count)))
        }
        let a = [s.map { $0.ax }, s.map { $0.ay }, s.map { $0.az }].map(rmsDetrended)
        let g = [s.map { $0.gx }, s.map { $0.gy }, s.map { $0.gz }].map(rmsDetrended)
        return (sqrt(a.map { $0 * $0 }.reduce(0, +)), sqrt(g.map { $0 * $0 }.reduce(0, +)))
    }
}
