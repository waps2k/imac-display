import CoreMedia
import Foundation
import ScreenCaptureKit
import Wire

/// 지정한 디스플레이 하나를 ScreenCaptureKit으로 캡처한다.
/// 화면 내용이 바뀔 때만 프레임이 들어온다.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "capture", qos: .userInteractive)
    private var stream: SCStream?
    private let onFrame: (CVPixelBuffer, CMTime) -> Void

    init(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.onFrame = onFrame
    }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        // 새로 만든 가상 디스플레이가 목록에 나타날 때까지 잠시 기다린다.
        var target: SCDisplay?
        for _ in 0..<40 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            target = content.displays.first { $0.displayID == displayID }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let target else { throw SenderError.displayNotFound }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 6

        let filter = SCContentFilter(display: target, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        log(tr("캡처 시작", "Capture started") + ": \(width)x\(height) @\(fps)fps")
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        onFrame(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log(tr("캡처 중단", "Capture stopped") + ": \(error)")
    }
}
