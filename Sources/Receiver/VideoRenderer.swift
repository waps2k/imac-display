import AVFoundation
import CoreMedia
import Wire

/// 수신한 HEVC/H.264 프레임을 AVSampleBufferDisplayLayer에 넣는다.
/// 디코딩은 레이어가 VideoToolbox 하드웨어 디코더로 처리한다.
final class VideoRenderer {
    let layer = AVSampleBufferDisplayLayer()
    /// 디코딩이 깨져서 키프레임이 필요할 때 호출된다.
    var onNeedKeyframe: (() -> Void)?

    private var format: CMVideoFormatDescription?
    private var waitingForKeyframe = true

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor.black
    }

    func reset() {
        format = nil
        waitingForKeyframe = true
        layer.flushAndRemoveImage()
    }

    func setFormat(_ videoFormat: VideoFormat) {
        guard let description = makeFormatDescription(videoFormat) else {
            log("포맷 생성 실패")
            return
        }
        if let format, CMFormatDescriptionEqual(format, otherFormatDescription: description) { return }
        let dims = CMVideoFormatDescriptionGetDimensions(description)
        log("비디오 포맷: \(videoFormat.codec == .hevc ? "HEVC" : "H.264") \(dims.width)x\(dims.height)")
        format = description
    }

    func enqueue(_ frame: VideoFrame) {
        if layer.status == .failed {
            log("디코더 오류: \(layer.error.map { "\($0)" } ?? "알 수 없음") — 키프레임 요청")
            layer.flush()
            waitingForKeyframe = true
            onNeedKeyframe?()
        }
        if waitingForKeyframe {
            guard frame.isKeyframe else { return }
            waitingForKeyframe = false
        }
        guard let format, let sampleBuffer = makeSampleBuffer(frame.data, format: format) else { return }
        layer.enqueue(sampleBuffer)
    }

    private func makeFormatDescription(_ videoFormat: VideoFormat) -> CMVideoFormatDescription? {
        let sets = videoFormat.parameterSets
        guard !sets.isEmpty else { return nil }
        let joined = sets.reduce(Data(), +)
        return joined.withUnsafeBytes { raw -> CMVideoFormatDescription? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0
            for set in sets {
                pointers.append(base + offset)
                offset += set.count
            }
            let sizes = sets.map(\.count)
            var description: CMFormatDescription?
            let status: OSStatus
            switch videoFormat.codec {
            case .hevc:
                status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                    formatDescriptionOut: &description)
            case .h264:
                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
            return status == noErr ? description : nil
        }
    }

    private func makeSampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }

        let copied = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        // 타임스탬프 없이 도착 즉시 표시한다.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }
}
