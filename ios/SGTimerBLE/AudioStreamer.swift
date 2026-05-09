import AVFoundation

// AudioStreamer captures the microphone, encodes to AAC and wraps each packet
// in an ADTS header so it can be served as a streamable HTTP audio response.
// Multiple HTTP clients each get their own frame queue (pub/sub pattern).

class AudioStreamer {

    // MARK: - Subscriber

    final class Subscriber {
        private var queue = [Data]()
        private let lock  = NSLock()
        private let sem   = DispatchSemaphore(value: 0)

        fileprivate func push(_ frame: Data) {
            lock.lock()
            queue.append(frame)
            if queue.count > 8 { queue.removeFirst() } // ~185 ms max back-log
            lock.unlock()
            sem.signal()
        }

        // Returns nil on timeout (allows the streaming loop to check for disconnect)
        func next(timeout: TimeInterval = 0.5) -> Data? {
            guard sem.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock(); defer { lock.unlock() }
            return queue.isEmpty ? nil : queue.removeFirst()
        }
    }

    private var subscribers = [UUID: Subscriber]()
    private let subLock = NSLock()

    func subscribe() -> (UUID, Subscriber) {
        let id = UUID()
        let sub = Subscriber()
        subLock.lock(); subscribers[id] = sub; subLock.unlock()
        return (id, sub)
    }

    func unsubscribe(_ id: UUID) {
        subLock.lock(); subscribers.removeValue(forKey: id); subLock.unlock()
    }

    private func broadcast(_ frame: Data) {
        subLock.lock(); let subs = Array(subscribers.values); subLock.unlock()
        for s in subs { s.push(frame) }
    }

    // MARK: - Engine

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var hwSampleRate: Double = 44100

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .mixWithOthers])
        try session.setActive(true)

        let inputNode = engine.inputNode
        let hwFormat  = inputNode.inputFormat(forBus: 0)
        hwSampleRate  = hwFormat.sampleRate

        let aacSettings: [String: Any] = [
            AVFormatIDKey:         kAudioFormatMPEG4AAC,
            AVSampleRateKey:       hwSampleRate,
            AVNumberOfChannelsKey: 1,           // always stream mono
            AVEncoderBitRateKey:   64_000
        ]
        guard let aacFormat = AVAudioFormat(settings: aacSettings) else {
            throw NSError(domain: "AudioStreamer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create AAC format"])
        }
        guard let conv = AVAudioConverter(from: hwFormat, to: aacFormat) else {
            throw NSError(domain: "AudioStreamer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create AVAudioConverter"])
        }
        converter = conv

        // 1024 samples per tap == one AAC frame at standard rates
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buf, _ in
            self?.encodePCM(buf)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Encoding

    private func encodePCM(_ input: AVAudioPCMBuffer) {
        guard let conv = converter else { return }

        let outBuf = AVAudioCompressedBuffer(
            format: conv.outputFormat,
            packetCapacity: 8,
            maximumPacketSize: conv.maximumOutputPacketSize
        )

        var inputConsumed = false
        var convErr: NSError?

        let status = conv.convert(to: outBuf, error: &convErr) { _, outStatus in
            if inputConsumed { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData
            inputConsumed = true
            return input
        }

        guard status != .error, outBuf.packetCount > 0 else { return }

        let raw = Data(bytes: outBuf.data, count: Int(outBuf.byteLength))

        // Iterate individual packets and wrap each in an ADTS header
        if let descs = outBuf.packetDescriptions {
            for i in 0..<Int(outBuf.packetCount) {
                let d     = descs[i]
                let start = Int(d.mStartOffset)
                let size  = Int(d.mDataByteSize)
                guard start + size <= raw.count else { continue }
                let adts  = adtsHeader(dataLen: size) + raw[start..<(start + size)]
                broadcast(adts)
            }
        } else {
            // Fallback: treat entire buffer as a single packet
            broadcast(adtsHeader(dataLen: raw.count) + raw)
        }
    }

    // MARK: - ADTS header (7 bytes, no CRC)
    //
    // syncword(12) | ID(1) | layer(2) | protection_absent(1)
    // profile(2) | sampling_freq_index(4) | private(1) | channel_config(3)
    // originality(1) | home(1) | copyright_id(1) | copyright_start(1)
    // aac_frame_length(13) | adts_buffer_fullness(11) | num_raw_blocks(2)

    private func adtsHeader(dataLen: Int) -> Data {
        let fullLen  = UInt32(dataLen + 7) // including the 7-byte header itself
        let freqIdx  = sampleRateIndex(hwSampleRate)
        let profile  = UInt32(1)   // AAC-LC (ObjectType 2 → stored as ObjectType-1)
        let chanCfg  = UInt32(1)   // mono

        var h = [UInt8](repeating: 0, count: 7)
        h[0] = 0xFF
        h[1] = 0xF1  // sync[3:0]=F, MPEG-4 ID=0, layer=00, no CRC
        h[2] = UInt8((profile << 6) | (freqIdx << 2) | (chanCfg >> 2))
        h[3] = UInt8(((chanCfg & 3) << 6) | ((fullLen >> 11) & 0x3))
        h[4] = UInt8((fullLen >> 3) & 0xFF)
        h[5] = UInt8(((fullLen & 7) << 5) | 0x1F)   // VBR buffer fullness upper
        h[6] = 0xFC                                   // VBR buffer fullness lower, 0 raw blocks
        return Data(h)
    }

    private func sampleRateIndex(_ rate: Double) -> UInt32 {
        let table: [Double] = [96000, 88200, 64000, 48000, 44100,
                               32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        return UInt32(table.firstIndex(of: rate) ?? 4)
    }
}
