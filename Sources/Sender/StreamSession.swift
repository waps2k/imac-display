import CoreMedia
import Foundation
import Wire

/// 연결 하나에 대한 송신 파이프라인: 가상 디스플레이 → 캡처 → 인코딩 → 전송.
final class StreamSession {
    /// 전송 대기열이 이 수를 넘으면 새 프레임을 인코딩하지 않고 건너뛴다.
    /// 인코딩 전에 버리기 때문에 수신 측 디코딩이 깨지지 않는다.
    private static let maxInFlight = 3

    private let display: VirtualDisplay
    private let connection: MessageConnection
    private let width: Int
    private let height: Int
    private let fps: Int
    private var encoder: VideoEncoder!
    private var capturer: ScreenCapturer!
    private var refreshTimer: DispatchSourceTimer?

    // 아래 상태는 capturer.queue에서만 접근한다.
    private var latest: CVPixelBuffer?
    private var needsRefresh = false
    private var forceKeyframe = true

    init(hello: Hello, options: SenderOptions, connection: MessageConnection) throws {
        var width = hello.pixelWidth
        var height = hello.pixelHeight
        if options.maxWidth > 0, width > options.maxWidth {
            height = height * options.maxWidth / width
            width = options.maxWidth
        }
        // 인코더와 HiDPI 모드를 위해 짝수(가능하면 4의 배수)로 맞춘다.
        width -= width % 4
        height -= height % 4

        self.connection = connection
        self.width = width
        self.height = height
        self.fps = options.fps

        log("수신기: \(hello.name) \(hello.pixelWidth)x\(hello.pixelHeight) → 전송 \(width)x\(height)")
        display = try VirtualDisplay(
            name: hello.name, pixelWidth: width, pixelHeight: height,
            hiDPI: options.hiDPI && hello.scale >= 2,
            sizeInMillimeters: CGSize(width: hello.widthMillimeters, height: hello.heightMillimeters),
            refreshRate: Double(options.fps))

        encoder = try VideoEncoder(width: width, height: height, codec: options.codec,
                                   bitrateMbps: options.bitrateMbps, fps: options.fps) { [connection] format, frame in
            if let format { connection.send(.format, format.encoded()) }
            connection.send(.frame, frame.encoded())
        }
        capturer = ScreenCapturer { [weak self] pixelBuffer, _ in
            self?.didCapture(pixelBuffer)
        }
    }

    func start() async throws {
        try await capturer.start(displayID: display.displayID, width: width, height: height, fps: fps)

        // 백프레셔로 건너뛴 프레임이 있으면 전송 여유가 생겼을 때 최신 화면을 다시 보낸다.
        // (화면이 멈춰 있으면 ScreenCaptureKit이 새 프레임을 주지 않기 때문)
        let timer = DispatchSource.makeTimerSource(queue: capturer.queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self, self.needsRefresh, self.connection.pendingSends < Self.maxInFlight else { return }
            self.encodeLatest()
        }
        timer.resume()
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.cancel()
        refreshTimer = nil
        capturer.stop()
    }

    func requestKeyframe() {
        capturer.queue.async {
            self.forceKeyframe = true
            self.needsRefresh = true
        }
    }

    private func didCapture(_ pixelBuffer: CVPixelBuffer) {
        latest = pixelBuffer
        if connection.pendingSends >= Self.maxInFlight {
            needsRefresh = true
            return
        }
        encodeLatest()
    }

    private func encodeLatest() {
        guard let latest else { return }
        needsRefresh = false
        let key = forceKeyframe
        forceKeyframe = false
        // 같은 버퍼를 다시 인코딩할 수도 있으니 PTS는 항상 증가하는 호스트 시간으로 준다.
        encoder.encode(latest, pts: CMClockGetTime(CMClockGetHostTimeClock()), forceKeyframe: key)
    }
}
