import CoreMedia
import Foundation
import os
import Wire

/// 송신 파이프라인: 가상 디스플레이 → 캡처 → 인코딩 → 전송.
/// 연결은 갈아 끼울 수 있어서, 연결이 바뀌어도(Wi-Fi → 썬더볼트 등) 가상 디스플레이와 창 배치가 유지된다.
final class StreamSession {
    /// 전송 대기열이 이 수를 넘으면 새 프레임을 인코딩하지 않고 건너뛴다.
    /// 인코딩 전에 버리기 때문에 수신 측 디코딩이 깨지지 않는다.
    private static let maxInFlight = 3

    struct Counters {
        var framesSent: UInt64 = 0
        var framesSkipped: UInt64 = 0
    }

    let hello: Hello
    let width: Int
    let height: Int
    let codec: Codec

    private let display: VirtualDisplay
    private let fps: Int
    private let connection = OSAllocatedUnfairLock<MessageConnection?>(initialState: nil)
    private let counters = OSAllocatedUnfairLock(initialState: Counters())
    private var encoder: VideoEncoder!
    private var capturer: ScreenCapturer!
    private var refreshTimer: DispatchSourceTimer?

    // 아래 상태는 capturer.queue에서만 접근한다.
    private var latest: CVPixelBuffer?
    private var needsRefresh = false
    private var forceKeyframe = true

    var stats: Counters { counters.withLock { $0 } }

    init(hello: Hello, options: SenderOptions, bitrateMbps: Int) throws {
        var width = hello.pixelWidth
        var height = hello.pixelHeight
        if options.maxWidth > 0, width > options.maxWidth {
            height = height * options.maxWidth / width
            width = options.maxWidth
        }
        // 인코더와 HiDPI 모드를 위해 짝수(가능하면 4의 배수)로 맞춘다.
        width -= width % 4
        height -= height % 4

        self.hello = hello
        self.width = width
        self.height = height
        self.fps = options.fps
        self.codec = options.codec

        log("수신기: \(hello.name) \(hello.pixelWidth)x\(hello.pixelHeight) → 전송 \(width)x\(height)")
        display = try VirtualDisplay(
            name: hello.name, pixelWidth: width, pixelHeight: height,
            hiDPI: options.hiDPI && hello.scale >= 2,
            sizeInMillimeters: CGSize(width: hello.widthMillimeters, height: hello.heightMillimeters),
            refreshRate: Double(options.fps))

        encoder = try VideoEncoder(width: width, height: height, codec: options.codec,
                                   bitrateMbps: bitrateMbps, fps: options.fps) { [weak self] format, frame in
            guard let self, let conn = self.connection.withLock({ $0 }) else { return }
            if let format { conn.send(.format, format.encoded()) }
            conn.send(.frame, frame.encoded())
            self.counters.withLock { $0.framesSent += 1 }
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
            guard let self, self.needsRefresh, self.canSend else { return }
            self.encodeLatest()
        }
        timer.resume()
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.cancel()
        refreshTimer = nil
        capturer.stop()
        detach()
    }

    /// 새 연결로 전송을 이어간다. 수신기가 디코딩을 시작할 수 있도록 키프레임부터 보낸다.
    func attach(_ conn: MessageConnection, bitrateMbps: Int) {
        connection.withLock { $0 = conn }
        encoder.setBitrate(mbps: bitrateMbps)
        requestKeyframe()
    }

    /// 연결이 끊긴 동안에는 캡처만 하고 보내지 않는다.
    func detach() {
        connection.withLock { $0 = nil }
    }

    func requestKeyframe() {
        capturer.queue.async {
            self.forceKeyframe = true
            self.needsRefresh = true
        }
    }

    private var canSend: Bool {
        guard let conn = connection.withLock({ $0 }) else { return false }
        return conn.pendingSends < Self.maxInFlight
    }

    private func didCapture(_ pixelBuffer: CVPixelBuffer) {
        latest = pixelBuffer
        guard canSend else {
            if connection.withLock({ $0 }) != nil {
                counters.withLock { $0.framesSkipped += 1 }
            }
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
