import AVFoundation
import Vision

struct AppError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Head direction from face landmarks, and the monitor box traced by a sweep.
enum Gaze {
    struct Box { let u0, u1, v0, v1: Double }

    /// Points are in image pixels (y down, not mirrored). Returns (u, v), where
    /// u grows as you turn right and v grows as you look down. Measuring along
    /// the eye line cancels head tilt; dividing by face size cancels distance.
    static func direction(eyeL: CGPoint, eyeR: CGPoint, nose: CGPoint, mouth: CGPoint) -> (Double, Double)? {
        let mid = CGPoint(x: (eyeL.x + eyeR.x) / 2, y: (eyeL.y + eyeR.y) / 2)
        let ex = Double(eyeR.x - eyeL.x), ey = Double(eyeR.y - eyeL.y)
        let d = hypot(ex, ey)
        guard d > 1e-6 else { return nil }
        let ax = (ex / d, ey / d)
        var ay = (-ax.1, ax.0)
        if ay.1 < 0 { ay = (-ay.0, -ay.1) }
        let n = (Double(nose.x - mid.x), Double(nose.y - mid.y))
        let m = (Double(mouth.x - mid.x), Double(mouth.y - mid.y))
        let faceHeight = m.0 * ay.0 + m.1 * ay.1
        guard faceHeight > 1e-6 else { return nil }
        return (-(n.0 * ax.0 + n.1 * ax.1) / d, (n.0 * ay.0 + n.1 * ay.1) / faceHeight)
    }

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        let k = Double(s.count - 1) * p / 100
        let lo = Int(k.rounded(.down)), hi = Int(k.rounded(.up))
        return lo == hi ? s[lo] : s[lo] * (Double(hi) - k) + s[hi] * (k - Double(lo))
    }

    /// `sweep`: readings while looking around the monitor. `laptop`: readings
    /// while looking at the laptop, used as the reference point.
    static func box(sweep: [(Double, Double)], laptop: [(Double, Double)]) throws -> Box {
        guard laptop.count >= 4 else {
            throw AppError("Didn't see you look back at the laptop after the second sound.")
        }
        let bu = percentile(laptop.map { $0.0 }, 50), bv = percentile(laptop.map { $0.1 }, 50)
        let rel = sweep.map { ($0.0 - bu, $0.1 - bv) }
        let dist = rel.map { hypot($0.0, $0.1) }
        let reach = percentile(dist, 90)
        // Ignore moments you were still looking at the laptop.
        let away = zip(rel, dist).filter { $0.1 > 0.25 * reach }.map { $0.0 }
        guard away.count >= 6, reach >= 0.02 else {
            throw AppError("Didn't catch you looking at the monitor. Turn your head toward it more.")
        }
        let us = away.map { $0.0 }, vs = away.map { $0.1 }
        return Box(u0: percentile(us, 4), u1: percentile(us, 96),
                   v0: percentile(vs, 4), v1: percentile(vs, 96))
    }
}

/// Runs the camera through one sweep: wait for a face, "start" cue, look around
/// the monitor, "back" cue, look at the laptop, done.
final class GazeSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let sweepTime = 4.5
    static let settleTime = 0.6
    static let laptopTime = 0.9

    typealias Readings = (sweep: [(Double, Double)], laptop: [(Double, Double)])

    private enum Phase { case waiting, sweeping, done }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "screensense.camera")
    private var phase = Phase.waiting
    private var opened = 0.0, started = 0.0, cuedBack = false
    private var sweep: [(Double, Double)] = []
    private var laptop: [(Double, Double)] = []
    private let mirrored: Bool
    private let onCue: (String) -> Void
    private let onDone: (Result<Readings, AppError>) -> Void

    init(mirrored: Bool, onCue: @escaping (String) -> Void,
         onDone: @escaping (Result<Readings, AppError>) -> Void) {
        self.mirrored = mirrored
        self.onCue = onCue
        self.onDone = onDone
    }

    func start() throws {
        let builtIn = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
        guard let device = builtIn.first ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            throw AppError("Couldn't open the camera.")
        }
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw AppError("Couldn't open the camera.")
        }
        session.addInput(input)
        session.addOutput(output)
        if let conn = output.connection(with: .video), conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = false
        }
        session.commitConfiguration()
        opened = CACurrentMediaTime()
        queue.async { self.session.startRunning() }
    }

    func cancel(_ reason: String) {
        queue.async { self.finish(.failure(AppError(reason))) }
    }

    private func finish(_ result: Result<Readings, AppError>) {
        guard phase != .done else { return }
        phase = .done
        session.stopRunning()
        let done = onDone
        DispatchQueue.main.async { done(result) }
    }

    private func cue(_ name: String) {
        let cue = onCue
        DispatchQueue.main.async { cue(name) }
    }

    private func read(_ buffer: CVPixelBuffer) -> (Double, Double)? {
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let lm = face.landmarks, let le = lm.leftEye, let re = lm.rightEye,
              let nose = lm.nose, let lips = lm.outerLips else { return nil }

        let w = CGFloat(CVPixelBufferGetWidth(buffer)), h = CGFloat(CVPixelBufferGetHeight(buffer))
        func center(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
            let pts = region.pointsInImage(imageSize: CGSize(width: w, height: h))
            guard !pts.isEmpty else { return .zero }
            let n = CGFloat(pts.count)
            return CGPoint(x: pts.reduce(0) { $0 + $1.x } / n,
                           y: h - pts.reduce(0) { $0 + $1.y } / n)
        }
        var a = center(le), b = center(re)
        if a.x > b.x { swap(&a, &b) }
        guard var dir = Gaze.direction(eyeL: a, eyeR: b, nose: center(nose), mouth: center(lips)) else {
            return nil
        }
        if mirrored { dir.0 = -dir.0 }
        return dir
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard phase != .done, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        let reading = read(buffer)

        switch phase {
        case .waiting:
            if reading != nil {
                phase = .sweeping
                started = now
                cue("start")
            } else if now - opened > 8 {
                finish(.failure(AppError("Couldn't see your face. Sit in front of the laptop camera.")))
            }
        case .sweeping:
            let t = now - started
            let s = GazeSession.self
            if !cuedBack && t >= s.sweepTime {
                cuedBack = true
                cue("back")
            }
            if t >= s.sweepTime + s.settleTime + s.laptopTime {
                finish(.success((sweep: sweep, laptop: laptop)))
                return
            }
            guard let r = reading else { return }
            if t >= 0.2 && t < s.sweepTime + 0.15 {
                sweep.append(r)
            } else if t >= s.sweepTime + s.settleTime {
                laptop.append(r)
            }
        case .done:
            break
        }
    }
}
