import Foundation
import WhisperKit
import AVFoundation

enum TranscriptionState {
    case notinited     // 未初始化
    case notStarted    // 未开始解析
    case transcribing  // 解析中
    case transcriberror  // 解析异常
    case completed     // 解析完成
}

enum TranscriptionError: Error {
    case invalidURL
    case audioProcessingFailed
    case transcriptionFailed
    case modelNotLoaded
    case cancelled
    case invalidResponse
    
    var localizedDescription: String {
        switch self {
        case .invalidURL: return "无效的音频 URL"
        case .audioProcessingFailed: return "音频处理失败"
        case .transcriptionFailed: return "转写失败"
        case .modelNotLoaded: return "模型未加载"
        case .cancelled: return "转写已取消"
        case .invalidResponse: return "服务器响应无效"
        }
    }
}

class TranscriptionManager: ObservableObject {
    @Published var state: TranscriptionState = .notStarted
    @Published var progress: Float = 0
    @Published var segments: [TranscriptionSegment] = []
    @Published var currentSegmentIndex: Int = 0
    
    var whisperKit: WhisperKit?
    var audioManager: AudioManager?
    private var processingTask: Task<Void, Error>?
    private var totalProcessedSamples: Int = 0
    private var transcriptionStartTime: Double = 0
    var transcriptionLatestStartOffset: Int64 = 0
    private var transcriptionlatestStartTime: Double = 0
    private var currentAudioRate: Int = 16000
    private var totalProcessed: Int64 = 0
    
    private let minChunkSize = 262144 // 256KB
    
    init(whisperKit: WhisperKit?,audioManager:AudioManager?) {
        self.whisperKit = whisperKit
        self.audioManager = audioManager
    }
    
    func startTranscription(from url: String, startTime: Double = 0) {
        guard let whisperKit = whisperKit else {
            state = .notinited
            return
        }
        
        cleanupCurrentTranscription()
        
        Task { @MainActor in
            do {
                await resetTranscriptionState()
                transcriptionStartTime = startTime
                                
                let (asyncBytes, response) = try await fetchAsyncBytes(from: url)
                try await processAudioStream(asyncBytes: asyncBytes, response: response)
                

            } catch is CancellationError {
                await handleTranscriptionCancellation()
            } catch {
                await handleError(error)
            }
        }
    }
    
    func stopTranscription() {
        processingTask?.cancel()
    }
    
    private func cleanupCurrentTranscription() {
        processingTask?.cancel()
        processingTask = nil
    }
    
    @MainActor
    private func resetTranscriptionState() {
        progress = 0
        totalProcessedSamples = 0
        segments = []
        currentSegmentIndex = 0
        state = .completed
    }
    
    private func fetchAsyncBytes(from urlString: String) async throws -> (URLSession.AsyncBytes, URLResponse) {
        guard let url = URL(string: urlString) else {
            throw TranscriptionError.invalidURL
        }
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 30000
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration)
        
        var startByte: Int64 = 0
        if transcriptionLatestStartOffset == 0 {
            let mp3Rate = try? await getMP3Bitrate(from: url)
            let bitRate: Double = Double(mp3Rate ?? 128000)
            let bytesPerSecond = bitRate / 8
            
            startByte = Int64(transcriptionStartTime * bytesPerSecond)
            transcriptionLatestStartOffset = startByte
            currentAudioRate = mp3Rate ?? 128000
        } else {
            transcriptionStartTime = transcriptionlatestStartTime
            startByte = transcriptionLatestStartOffset
        }
        
        var request = URLRequest(url: url)
        request.setValue("bytes=\(startByte)-", forHTTPHeaderField: "Range")
        
        print("############fetchAsyncBytes-startByte:",startByte,
              ",transcriptionLatestStartOffset:",transcriptionLatestStartOffset,
              ",transcriptionStartTime:",transcriptionStartTime,
              ",currentAudioRate:",currentAudioRate)

        
        return try await session.bytes(for: request)
    }
    
    private func getMP3Bitrate(from url: URL) async throws -> Int? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-16384", forHTTPHeaderField: "Range")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        if data.count >= 3 && data.prefix(3) == Data([0x49, 0x44, 0x33]) {
            let id3Size = try await getID3Size(url: url, data: data)
            let frameOffset = id3Size
            return try await readFirstValidFrameBitrate(url: url, startOffset: frameOffset)
        } else {
            return try await readFirstValidFrameBitrate(url: url, startOffset: 0)
        }
    }
    
    private func getID3Size(url: URL, data: Data) async throws -> Int {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        
        let (headerData, _) = try await URLSession.shared.data(for: request)
        
        guard headerData.count >= 10 else {
            return 0
        }
        
        let size = (Int(headerData[6]) & 0x7F) << 21 |
        (Int(headerData[7]) & 0x7F) << 14 |
        (Int(headerData[8]) & 0x7F) << 7 |
        (Int(headerData[9]) & 0x7F)
        
        return size + 10
    }
    
    private func readFirstValidFrameBitrate(url: URL, startOffset: Int) async throws -> Int? {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(startOffset)-\(startOffset + 16384)", forHTTPHeaderField: "Range")
        
        let (frameData, _) = try await URLSession.shared.data(for: request)
        
        for i in 0...(frameData.count - 4) {
            if let bitrate = validateAndGetBitrate(frameData: frameData, offset: i) {
                return bitrate
            }
        }
        
        return 128000 // 默认返回 128kbps
    }
    
    private func validateAndGetBitrate(frameData: Data, offset: Int) -> Int? {
        let data = Array(frameData.dropFirst(offset).prefix(4))
        
        guard data.count >= 4,
              data[0] == 0xFF && (data[1] & 0xE0) == 0xE0 else {
            return nil
        }
        
        let version = Int(data[1] & 0x18) >> 3
        let layer = Int(data[1] & 0x06) >> 1
        let bitrateIndex = Int(data[2] & 0xf0) >> 4
        
        guard version != 1,
              layer != 0,
              bitrateIndex != 0 && bitrateIndex != 15 else {
            return nil
        }
        
        let bitrates: [[Int]] = [
            [0,  8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0],
            [0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,   0,   0,   0,   0, 0],
            [0,  8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0],
            [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
        ]
        
        guard version >= 0 && version <= 3,
              bitrateIndex >= 0 && bitrateIndex <= 15 else {
            return nil
        }
        
        let bitrate = bitrates[version][bitrateIndex] * 1000
        return bitrate > 0 ? bitrate : nil
    }
    
    private func processAudioStream(asyncBytes: URLSession.AsyncBytes, response: URLResponse) async throws {
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
            throw TranscriptionError.invalidResponse
        }

        print("############processAudioStream-date",Date())
        
        let totalSize = Float(response.expectedContentLength)
        var mp3Buffer = Data()
        
        for try await byte in asyncBytes {
            try Task.checkCancellation()
            
            mp3Buffer.append(byte)
            totalProcessed += 1
            transcriptionLatestStartOffset += 1
            transcriptionlatestStartTime = Double(transcriptionLatestStartOffset / Int64(currentAudioRate/8))
            
            if mp3Buffer.count >= minChunkSize {
                try await processMP3Chunk(mp3Buffer, totalProcessed: totalProcessed, totalSize: totalSize)
//                print("############processAudioStream-minChunkSize-date",Date())
                mp3Buffer.removeAll(keepingCapacity: true)
            }
        }
        
        if !mp3Buffer.isEmpty {
            try await processMP3Chunk(mp3Buffer, totalProcessed: totalProcessed, totalSize: totalSize)
        }
    }
    
    private func processMP3Chunk(_ mp3Buffer: Data, totalProcessed: Int64, totalSize: Float) async throws {
        let samples = try await convertMP3ToFloatArray(mp3Buffer)
        await MainActor.run {
            progress = Float(totalProcessed) / totalSize
        }
        
        try await processAudioChunk(samples)
    }
    
    private func processAudioChunk(_ chunk: [Float]) async throws {
        let startTime = transcriptionStartTime + (Double(totalProcessedSamples) / Double(WhisperKit.sampleRate))
        let chunkDuration = Double(chunk.count) / Double(WhisperKit.sampleRate)
        
        guard let whisperKit = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }
        
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            detectLanguage:true,
            wordTimestamps:false
//            language: "en"
        )
        
        do {
            let results = try await whisperKit.transcribe(audioArray: chunk, decodeOptions: options)
            
            
            if let result = results.first {
                await MainActor.run {
                    let adjustedSegments = result.segments.map { segment in
                        var newSegment = segment
                        newSegment.start = Float(startTime + Double(segment.start))
//                        newSegment.end = Float(startTime + min(Double(segment.end), chunkDuration))
                        newSegment.end = Float(startTime + Double(segment.end))

                        return newSegment
                    }
                    
                    mergeAndSortSegments(adjustedSegments)
                }
            }
        } catch {
            throw TranscriptionError.transcriptionFailed
        }
        
        totalProcessedSamples += chunk.count
    }
    
     
    
    private func convertMP3ToFloatArray(_ mp3Data: Data) async throws -> [Float] {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".mp3")
        
        do {
            try mp3Data.write(to: tempFile)
            defer { try? FileManager.default.removeItem(at: tempFile) }
            
            let file = try AVAudioFile(forReading: tempFile)
            let format = AVAudioFormat(standardFormatWithSampleRate: Double(WhisperKit.sampleRate), channels: 1)!
            
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let converter = AVAudioConverter(from: file.processingFormat, to: format)!
            
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: nil)
            
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw TranscriptionError.audioProcessingFailed
            }
            
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                do {
                    let audioBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inNumPackets)!
                    try file.read(into: audioBuffer)
                    outStatus.pointee = .haveData
                    return audioBuffer
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }
            
            try autoreleasepool {
                converter.convert(to: buffer, error: &error, withInputFrom: inputBlock)
            }
            
            if let error = error {
                throw error
            }
            
            guard let channelData = buffer.floatChannelData else {
                throw TranscriptionError.audioProcessingFailed
            }
            
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            
        } catch {
            try? FileManager.default.removeItem(at: tempFile)
            throw error
        }
    }
    
    @MainActor
    private func mergeAndSortSegments(_ newSegments: [TranscriptionSegment]) {
        segments.append(contentsOf: newSegments)
        segments.sort { $0.start < $1.start }
        
        var index = 0
        while index < segments.count - 1 {
            let current = segments[index]
            let next = segments[index + 1]
            
            let currentText = cleanTranscriptText(current.text)
            let nextText = cleanTranscriptText(next.text)
            
            if shouldMergeSegments(current: currentText, next: nextText) {
                var mergedSegment = current
                mergedSegment.start = min(current.start, next.start)
                mergedSegment.end = max(current.end, next.end)
                mergedSegment.text = mergeTexts(current: currentText, next: nextText)
                
                segments[index] = mergedSegment
                segments.remove(at: index + 1)
            } else {
                index += 1
            }
        }
        
        for i in 1..<segments.count {
            var current = segments[i]
            let previous = segments[i - 1]
            
            if current.start <= previous.end {
                current.start = previous.end + 0.05
                segments[i] = current
            }
        }
    }
    
    private func shouldMergeSegments(current: String, next: String) -> Bool {
        let endingPunctuation = [".", "!", "?"]
        if endingPunctuation.contains(where: { current.hasSuffix($0) }) {
            return false
        }
        
        let incompleteWords = ["the", "a", "an", "and", "or", "but", "in", "on", "at", "to"]
        
        return incompleteWords.contains(where: { current.lowercased().hasSuffix($0) }) ||
        (next.first?.isLowercase == true) ||
        current.hasSuffix(",") ||
        incompleteWords.contains(where: { next.lowercased().hasPrefix($0) })
    }
    
    private func mergeTexts(current: String, next: String) -> String {
        let cleanCurrent = current.trimmingCharacters(in: .whitespaces)
        let cleanNext = next.trimmingCharacters(in: .whitespaces)
        
        if cleanCurrent.hasSuffix(",") {
            return cleanCurrent + " " + cleanNext
        }
        
        if let firstChar = cleanNext.first, [",", ".", "!", "?"].contains(firstChar) {
            return cleanCurrent + cleanNext
        }
        
        return cleanCurrent + " " + cleanNext
    }
    
    @MainActor
    private func handleTranscriptionCancellation() {
        segments.sort { $0.start < $1.start }
        state = .transcriberror
        progress = 0
    }
    
    @MainActor
    private func handleError(_ error: Error) {
        state = .transcriberror
        print("Transcription error:",error)
    }
    
    private func cleanTranscriptText(_ text: String) -> String {
        let pattern = "<\\|.*?\\|>"
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(location: 0, length: text.utf16.count)
        var cleanText = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        
        cleanText = cleanText.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return cleanText
    }
}
