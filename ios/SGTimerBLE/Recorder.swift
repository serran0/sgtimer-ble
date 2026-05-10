import AVFoundation
import Photos
import UIKit
import CoreImage

class Recorder {
    // Thread-safe overlay: set by AppServer (main thread), read on capture queue
    private let overlayLock = NSLock()
    private var _overlayImage: CIImage?
    var overlayImage: CIImage? {
        get { overlayLock.lock(); defer { overlayLock.unlock() }; return _overlayImage }
        set { overlayLock.lock(); _overlayImage = newValue; overlayLock.unlock() }
    }

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var sessionStarted = false

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var hwAudioFormat: AVAudioFormat?
    private var audioSourceFmtDesc: CMAudioFormatDescription?

    private(set) var isActive = false

    // MARK: - Audio setup (call before start, once AudioStreamer has started)

    func configureAudio(from hwFormat: AVAudioFormat) {
        hwAudioFormat = hwFormat
        // Build format description from the hardware format directly — AVAssetWriter
        // encodes float32 PCM to AAC without a PCM-to-PCM conversion step.
        var asbd = hwFormat.streamDescription.pointee
        var desc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd,
                                       layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &desc)
        audioSourceFmtDesc = desc
    }

    // MARK: - Lifecycle

    func start(videoSize: CGSize) throws {
        guard !isActive else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        outputURL = url

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // Video — H.264
        let vSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vInput.expectsMediaDataInRealTime = true

        let adapt = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String:          Int(videoSize.width),
                kCVPixelBufferHeightKey as String:         Int(videoSize.height)
            ]
        )

        // Audio — AAC, channel count and sample rate matched to hardware format
        let aSettings: [String: Any] = [
            AVFormatIDKey:         kAudioFormatMPEG4AAC,
            AVSampleRateKey:       hwAudioFormat?.sampleRate ?? 44100.0,
            AVNumberOfChannelsKey: Int(hwAudioFormat?.channelCount ?? 1),
            AVEncoderBitRateKey:   96_000
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio,
                                        outputSettings: aSettings,
                                        sourceFormatHint: audioSourceFmtDesc)
        aInput.expectsMediaDataInRealTime = true

        if writer.canAdd(vInput) { writer.add(vInput) }
        if writer.canAdd(aInput) { writer.add(aInput) }

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "Recorder", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter failed to start"])
        }

        assetWriter   = writer
        videoInput    = vInput
        audioInput    = aInput
        adaptor       = adapt
        sessionStarted = false
        isActive       = true
    }

    func stop(completion: @escaping (Bool) -> Void) {
        guard isActive, let writer = assetWriter, let url = outputURL else {
            completion(false); return
        }
        isActive = false
        overlayImage = nil
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        writer.finishWriting {
            guard writer.status == .completed else { completion(false); return }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    completion(false); return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { success, _ in
                    try? FileManager.default.removeItem(at: url)
                    completion(success)
                }
            }
        }
    }

    // MARK: - Video (called on capture queue)

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isActive,
              let writer = assetWriter,
              let vInput = videoInput, vInput.isReadyForMoreMediaData,
              let adapt  = adaptor,
              let imgBuf = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !sessionStarted {
            writer.startSession(atSourceTime: ts)
            sessionStarted = true
        }
        guard writer.status == .writing else { return }

        var ci = CIImage(cvPixelBuffer: imgBuf)

        if let overlay = overlayImage {
            let comp = CIFilter(name: "CISourceOverCompositing")!
            comp.setValue(overlay, forKey: kCIInputImageKey)
            comp.setValue(ci,      forKey: kCIInputBackgroundImageKey)
            if let out = comp.outputImage { ci = out }
        }

        guard let pool = adapt.pixelBufferPool else { return }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess,
              let pb else { return }
        ciContext.render(ci, to: pb)
        adapt.append(pb, withPresentationTime: ts)
    }

    // MARK: - Audio (called on engine render thread)

    func appendAudio(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard isActive, sessionStarted,
              let writer = assetWriter, writer.status == .writing,
              let aInput = audioInput, aInput.isReadyForMoreMediaData else { return }
        guard let sb = Self.makeCMSampleBuffer(from: buffer, time: time) else { return }
        aInput.append(sb)
    }

    // MARK: - PCM → CMSampleBuffer

    private static func makeCMSampleBuffer(from buf: AVAudioPCMBuffer,
                                            time: AVAudioTime) -> CMSampleBuffer? {
        let fmt = buf.format
        var asbd = fmt.streamDescription.pointee
        var fmtDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd,
                                              layoutSize: 0, layout: nil,
                                              magicCookieSize: 0, magicCookie: nil,
                                              extensions: nil,
                                              formatDescriptionOut: &fmtDesc) == noErr,
              let fmtDesc else { return nil }

        let frameCount    = Int(buf.frameLength)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let dataSize      = frameCount * bytesPerFrame
        guard dataSize > 0 else { return nil }

        // Pointer to the (mono / channel-0) sample data
        let dataPtr: UnsafeMutableRawPointer?
        switch fmt.commonFormat {
        case .pcmFormatInt16:   dataPtr = buf.int16ChannelData.map  { UnsafeMutableRawPointer($0[0]) }
        case .pcmFormatFloat32: dataPtr = buf.floatChannelData.map  { UnsafeMutableRawPointer($0[0]) }
        default: return nil
        }
        guard let dataPtr else { return nil }

        var blockBuf: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: dataSize,
            blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: dataSize, flags: 0,
            blockBufferOut: &blockBuf
        ) == noErr, let blockBuf else { return nil }
        CMBlockBufferAssureBlockMemory(blockBuf)
        CMBlockBufferReplaceDataBytes(dataPtr, blockBuf, 0, dataSize)

        let pts = CMTime(value:     CMTimeValue(time.sampleTime),
                         timescale: CMTimeScale(fmt.sampleRate))
        var timing = CMSampleTimingInfo(
            duration:               CMTime(value: CMTimeValue(frameCount),
                                           timescale: CMTimeScale(fmt.sampleRate)),
            presentationTimeStamp:  pts,
            decodeTimeStamp:        .invalid
        )

        var sb: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: blockBuf, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: fmtDesc, sampleCount: frameCount,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sb
        )
        return sb
    }
}
