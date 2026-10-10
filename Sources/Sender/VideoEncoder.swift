import CoreMedia
import Foundation
import VideoToolbox
import Wire

/// VideoToolbox 하드웨어 인코더. 저지연을 위해 B-프레임을 끄고 실시간 모드로 동작한다.
final class VideoEncoder {
    let codec: Codec
    private var session: VTCompressionSession?
    private let onEncoded: (VideoFormat?, VideoFrame) -> Void

    init(width: Int, height: Int, codec: Codec, bitrateMbps: Int, fps: Int,
         onEncoded: @escaping (VideoFormat?, VideoFrame) -> Void) throws {
        self.codec = codec
        self.onEncoded = onEncoded

        let codecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var created: VTCompressionSession?
        // 저지연 레이트 컨트롤을 먼저 시도하고, 지원하지 않으면 일반 하드웨어 인코더로 만든다.
        for lowLatency in [true, false] {
            var spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
            if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            let status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: codecType,
                encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                compressionSessionOut: &created)
            if status == noErr, created != nil {
                log("인코더: \(codec == .hevc ? "HEVC" : "H.264") \(width)x\(height), 저지연=\(lowLatency)")
                break
            }
            if !lowLatency { throw SenderError.encoderFailed(status) }
        }
        guard let session = created else { throw SenderError.encoderFailed(-1) }

        let profile = codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: profile,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 10,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
        ]
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if status != noErr { log("인코더 속성 무시됨: \(key) (\(status))") }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
        setBitrate(mbps: bitrateMbps)
    }

    /// 인코딩 중에도 바꿀 수 있다 (연결 종류가 바뀔 때 사용).
    func setBitrate(mbps: Int) {
        guard let session else { return }
        let bitrate = mbps * 1_000_000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [bitrate / 8 * 2, 1] as CFArray)
    }

    deinit {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool) {
        guard let session else { return }
        let frameProperties = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: frameProperties, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else {
                if status != noErr { log("인코딩 오류: \(status)") }
                return
            }
            self.handle(sampleBuffer)
        }
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        var format: VideoFormat?
        if isKeyframe, let description = sampleBuffer.formatDescription {
            format = VideoFormat(codec: codec, parameterSets: parameterSets(of: description))
        }

        guard let block = sampleBuffer.dataBuffer else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }
        onEncoded(format, VideoFrame(isKeyframe: isKeyframe, data: data))
    }

    private func parameterSets(of description: CMFormatDescription) -> [Data] {
        var sets: [Data] = []
        var count = 0
        var index = 0
        repeat {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            if codec == .hevc {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            } else {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            }
            guard status == noErr, let pointer else { break }
            sets.append(Data(bytes: pointer, count: size))
            index += 1
        } while index < count
        return sets
    }
}
