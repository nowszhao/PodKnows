import SwiftUI
import AVFoundation
import WhisperKit

private struct AdvancedSettingsView: View {
    @Binding var enablePromptPrefill: Bool
    @Binding var enableCachePrefill: Bool
    @Binding var enableSpecialCharacters: Bool
    @Binding var enableTimestamps: Bool
    @Binding var sampleLength: Double
    @Binding var aiResponse: String
    let transcriptionSegments: [TranscriptionSegment]
    let currentSegmentIndex: Int
    @Environment(\.dismiss) private var dismiss
    
    private var settingsForm: some View {
        VStack(spacing: 16) {
            // 标题和原文
            if let currentSegment = transcriptionSegments[safe: currentSegmentIndex] {
                VStack(alignment: .leading, spacing: 8) {
                    Text("原文")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text(cleanTranscriptText(currentSegment.text))
                        .font(.body)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                }
                .padding(.horizontal)
            }
            
            Divider()
            
            // AI 解析结果
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if(aiResponse != "AI 正在思考中..." ){
                        Text("AI 解析")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }
                
                if !aiResponse.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if aiResponse == "AI 正在思考中..." {
                                Text(aiResponse)
                                    .foregroundColor(.blue)
                                    .font(.body)
                            } else {
                                // 解析结果展示
                                VStack(alignment: .leading, spacing: 8) {
                                    // 难词解释
                                    if !aiResponse.isEmpty {
                                        Text(aiResponse)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                            .lineSpacing(6)
                                            .padding(12)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.blue.opacity(0.05))
                                            .cornerRadius(8)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                        .textSelection(.enabled)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
    }
    
    var body: some View {
        NavigationStack {
            settingsForm
                .navigationTitle("AI解析")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            dismiss()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                                .imageScale(.large)
                        }
                        .buttonStyle(.plain)
                    }
                }
        }
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

struct TranscriptionSegmentView: View {
    let segment: TranscriptionSegment
    let isCurrentSegment: Bool
    let isPlaying: Bool
    let onTap: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(formatTimestamp(segment.start))
                    .font(.caption)
                    .foregroundColor(.gray)
                
                Text("→")
                    .font(.caption)
                    .foregroundColor(.gray)
                
                Text(formatTimestamp(segment.end))
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            Text(cleanTranscriptText(segment.text))
                .font(.body)
                .foregroundColor(isCurrentSegment ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrentSegment ?
                      (isPlaying ? Color.blue.opacity(0.15) : Color.blue.opacity(0.1)) :
                        Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCurrentSegment ? Color.blue : Color.clear,
                       lineWidth: isPlaying ? 2 : 1)
        )
        .scaleEffect(isCurrentSegment && isPlaying ? 1.02 : 1.0)
        .animation(.spring(response: 0.3), value: isCurrentSegment)
        .animation(.spring(response: 0.3), value: isPlaying)
        .onTapGesture(perform: onTap)
    }
}

struct PracticeRoomView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var audioManager = AudioManager()
    @StateObject private var transcriptionManager: TranscriptionManager
    
    @State private var isPlaying = false
    @State private var isLooping = false
    @State private var playbackSpeed: Double = 1.0
    @State private var sliderValue: Double = 0.0
    @State private var currentAudioUrl: String = ""
    @State private var isLoading = false
    @State private var showTranscriptionSettings = false
    @State private var aiResponse: String = ""
    @State private var scrollProxy: ScrollViewProxy?
    @State private var currentLoopSegment: TranscriptionSegment?
    
    // 转写配置
    @AppStorage("sampleLength") private var sampleLength: Double = 224
    @AppStorage("enablePromptPrefill") private var enablePromptPrefill: Bool = true
    @AppStorage("enableCachePrefill") private var enableCachePrefill: Bool = true
    @AppStorage("enableSpecialCharacters") private var enableSpecialCharacters: Bool = false
    @AppStorage("enableTimestamps") private var enableTimestamps: Bool = true
    
    init() {
        let manager = TranscriptionManager(whisperKit: nil,audioManager:nil)
        _transcriptionManager = StateObject(wrappedValue: manager)
    }
    
    private var subtitleAreaView: some View {
        Group {
            switch transcriptionManager.state {
            case .notinited:
                VStack {
                    Text("模型未加载或加载异常")
                        .font(.headline)
                        .foregroundColor(.gray)
                    Button(action: {
                        appState.selectedTab = 2
                    }) {
                        Label("去加载模型", systemImage: "bolt.fill")
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .notStarted:
                VStack {
                    Text("暂无字幕")
                        .font(.headline)
                        .foregroundColor(.gray)
                    Button(action: {
                        transcriptionManager.startTranscription(from: currentAudioUrl)
                    }) {
                        Label("开始转录", systemImage: "waveform")
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .disabled(appState.modelState != .loaded)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .transcribing:
                VStack {
                    Text("努力转录中...")
                        .font(.headline)
                        .foregroundColor(.gray)
                    ProgressView(value: transcriptionManager.progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 200)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .transcriberror:
                VStack {
                    Text("转录异常")
                        .font(.headline)
                        .foregroundColor(.red)
                    Button(action: {
                        transcriptionManager.startTranscription(from: currentAudioUrl)
                    }) {
                        Label("继续转录", systemImage: "waveform")
                            .padding()
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .disabled(appState.modelState != .loaded)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .completed:
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(transcriptionManager.segments.enumerated()), id: \.1.text) { index, segment in
                                TranscriptionSegmentView(
                                    segment: segment,
                                    isCurrentSegment: index == transcriptionManager.currentSegmentIndex,
                                    isPlaying: isPlaying,
                                    onTap: {
                                        playSegment(at: index)
                                    }
                                )
                                .id(index)
                            }
                            Color.clear
                                .frame(height: UIScreen.main.bounds.height / 2)
                        }
                        .padding()
                    }
                    .onChange(of: transcriptionManager.currentSegmentIndex) { _, newValue in
                        scrollToCurrentSegment()
                    }
                    .onAppear {
                        scrollProxy = proxy
                    }
                }
                
                // 添加转录进度指示器
                VStack(alignment: .listRowSeparatorLeading, spacing: 4) {
                    if (transcriptionManager.state == .transcribing || transcriptionManager.state == .completed) {
                        HStack(spacing: 4) {
                            Text("已转录")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(String(format: "%.1f%%", transcriptionManager.progress * 100))
                                .font(.caption)
                                .foregroundColor(.blue)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.blue.opacity(0.1))
                        )
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                    }
                }
                
            }
        }
    }
    
    var body: some View {
        ZStack {
            if isLoading {
                ProgressView("加载中...")
                    .progressViewStyle(CircularProgressViewStyle())
            } else {
                VStack(spacing: 0) {
                    if let episode = appState.currentEpisode {
                        Text(episode.title)
                            .font(.headline)
                            .padding()
                            .lineLimit(2)
                    } else {
                        Text("请从播客库中选择节目")
                            .font(.headline)
                            .foregroundColor(.gray)
                            .padding()
                    }
                    
                    subtitleAreaView
                    
                    playbackControlsView
                }
            }
        }
        .onAppear {
            setupLoopPlayback()
            transcriptionManager.whisperKit = appState.whisperKit
        }
        .onChange(of: appState.currentEpisode) { _, episode in
            if let episode = episode {
                handleNewEpisode(episode)
            }
        }
        .sheet(isPresented: $showTranscriptionSettings) {
            AdvancedSettingsView(
                enablePromptPrefill: $enablePromptPrefill,
                enableCachePrefill: $enableCachePrefill,
                enableSpecialCharacters: $enableSpecialCharacters,
                enableTimestamps: $enableTimestamps,
                sampleLength: $sampleLength,
                aiResponse: $aiResponse,
                transcriptionSegments: transcriptionManager.segments,
                currentSegmentIndex: transcriptionManager.currentSegmentIndex
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
        }
    }
    
    private var playbackControlsView: some View {
        VStack(spacing: 16) {
            HStack {
                Text(formatTime(audioManager.currentTime))
                    .font(.caption)
                    .foregroundColor(.gray)
                
                Slider(
                    value: Binding(
                        get: { audioManager.currentTime },
                        set: { time in
                            sliderValue = time
                            audioManager.seek(to: time)
                        }
                    ),
                    in: 0...max(audioManager.duration, 1),
                    onEditingChanged: { editing in
                        print("#############onEditingChanged: \(sliderValue)")
                        if editing {
                            print("Started dragging")
                        } else {
                            print("Stopped dragging")
                            Task {
                               
                                handleSeek(to: sliderValue)
                            }
                        }
                    }
                )
                .tint(.blue)
                
                Text(formatTime(audioManager.duration))
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.horizontal)
            
            HStack(spacing: 24) {
                Menu {
                    ForEach([0.75, 1.0, 1.5, 1.75], id: \.self) { speed in
                        Button(action: {
                            playbackSpeed = speed
                            audioManager.setPlaybackRate(speed)
                        }) {
                            HStack {
                                Text(formatPlaybackSpeed(speed))
                                if speed == playbackSpeed {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(formatPlaybackSpeed(playbackSpeed))
                        .font(.system(.body, design: .monospaced))
                }
                
                Button(action: previousSegment) {
                    Image(systemName: "backward.end.fill")
                        .font(.title2)
                }
                
                Button(action: togglePlayPause) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                
                Button(action: nextSegment) {
                    Image(systemName: "forward.end.fill")
                        .font(.title2)
                }
                
                Button(action: toggleLoopPlayback) {
                    Image(systemName: isLooping ? "repeat.1.circle.fill" : "repeat.1.circle")
                        .font(.title2)
                        .foregroundColor(isLooping ? .blue : .primary)
                }
                
                Button(action: {
                    showTranscriptionSettings.toggle()
                    audioManager.pause()
                    analyzeByGPT()
                    isPlaying = false
                }) {
                    Image(systemName: "brain.head.profile")
                        .font(.title2)
                }
            }
            .padding(.bottom)
        }
        .padding()
    }
    
    private func handleNewEpisode(_ episode: PodcastEpisode) {
        isLoading = true
        
        Task {
            do {
                await resetAllStates()
                try await Task.sleep(nanoseconds: 100_000_000)
                
                await MainActor.run {
                    currentAudioUrl = episode.audioUrl
                    audioManager.currentUrl = episode.audioUrl
                    audioManager.loadAudio(from: episode.audioUrl)
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    print("加载音频失败:", error)
                }
            }
        }
    }
    
    private func resetAllStates() async {
        await MainActor.run {
            isPlaying = false
            isLooping = false
            currentLoopSegment = nil
            transcriptionManager.state = .notStarted
            audioManager.reset()
        }
    }
    
    private func setupLoopPlayback() {
        audioManager.onPlaybackFinished = {
            if isLooping, let loopSegment = currentLoopSegment {
                let segmentStartTime = TimeInterval(loopSegment.start)
                audioManager.seek(to: segmentStartTime)
                audioManager.play()
                isPlaying = true
            }
        }
        
        audioManager.onPlaybackTimeUpdated = { currentTime in
            if isLooping, let loopSegment = currentLoopSegment {
                let segmentEndTime = TimeInterval(loopSegment.end)
                if currentTime >= segmentEndTime {
                    let segmentStartTime = TimeInterval(loopSegment.start)
                    audioManager.seek(to: segmentStartTime)
                    if !audioManager.isPlaying {
                        audioManager.play()
                        isPlaying = true
                    }
                }
            }
            updateCurrentSegment(at: currentTime)
        }
    }
    
    private func updateCurrentSegment(at time: TimeInterval) {
        let index = findSegmentIndex(for: time)
        if transcriptionManager.currentSegmentIndex != index {
            transcriptionManager.currentSegmentIndex = index
        }
    }
    
    private func findSegmentIndex(for time: TimeInterval) -> Int {
        let segments = transcriptionManager.segments
        var left = 0
        var right = segments.count - 1
        let tolerance: TimeInterval = 0.1
        
        while left <= right {
            let mid = (left + right) / 2
            let segment = segments[mid]
            let start = TimeInterval(segment.start)
            let end = TimeInterval(segment.end)
            
            if time >= start - tolerance && time < end + tolerance {
                return mid
            } else if time < start - tolerance {
                right = mid - 1
            } else {
                left = mid + 1
            }
        }
        
        if left >= segments.count {
            return segments.count - 1
        }
        if right < 0 {
            return 0
        }
        
        return left
    }
    
    private func scrollToCurrentSegment() {
        if let proxy = scrollProxy {
            withAnimation(.easeInOut(duration: 0.3)) {
                let scrollPosition: UnitPoint
                if transcriptionManager.currentSegmentIndex == 0 {
                    scrollPosition = .top
                } else if transcriptionManager.currentSegmentIndex == transcriptionManager.segments.count - 1 {
                    scrollPosition = .bottom
                } else {
                    scrollPosition = .center
                }
                
                let targetIndex = min(transcriptionManager.currentSegmentIndex + 1, transcriptionManager.segments.count - 1)
                proxy.scrollTo(targetIndex, anchor: scrollPosition)
            }
        }
    }
    
    private func togglePlayPause() {
        audioManager.ensurePlayerReady()
        audioManager.togglePlayPause()
        isPlaying.toggle()
    }
    
    private func playSegment(at index: Int) {
        guard index >= 0 && index < transcriptionManager.segments.count else { return }
        
        let segment = transcriptionManager.segments[index]
        let segmentStartTime = TimeInterval(segment.start)
        
        withAnimation(.easeInOut(duration: 0.3)) {
            if isLooping {
                currentLoopSegment = segment
            } else {
                currentLoopSegment = nil
            }
            
            audioManager.seek(to: segmentStartTime)
            transcriptionManager.currentSegmentIndex = index
            
            if !isPlaying {
                togglePlayPause()
            }
        }
    }
    
    private func previousSegment() {
        if isLooping {
            playSegment(at: transcriptionManager.currentSegmentIndex)
        } else {
            playSegment(at: transcriptionManager.currentSegmentIndex - 1)
        }
    }
    
    private func nextSegment() {
        if isLooping {
            playSegment(at: transcriptionManager.currentSegmentIndex)
        } else {
            playSegment(at: transcriptionManager.currentSegmentIndex + 1)
        }
    }
    
    private func toggleLoopPlayback() {
        isLooping.toggle()
        if isLooping {
            if transcriptionManager.currentSegmentIndex < transcriptionManager.segments.count {
                currentLoopSegment = transcriptionManager.segments[transcriptionManager.currentSegmentIndex]
                let segmentStartTime = TimeInterval(transcriptionManager.segments[transcriptionManager.currentSegmentIndex].start)
                audioManager.seek(to: segmentStartTime)
                
                if !isPlaying {
                    audioManager.play()
                    isPlaying = true
                }
            }
        } else {
            currentLoopSegment = nil
        }
    }
    
    private func handleSeek(to time: TimeInterval) {
        Task {
            transcriptionManager.transcriptionLatestStartOffset = 0
            transcriptionManager.startTranscription(from: currentAudioUrl, startTime: time)
        }
    }
    
    private func analyzeByGPT() {
        guard !transcriptionManager.segments.isEmpty else {
            aiResponse = "没有可用字幕"
            return
        }
        
        guard transcriptionManager.currentSegmentIndex >= 0 && 
                transcriptionManager.currentSegmentIndex < transcriptionManager.segments.count else {
            aiResponse = "当前字幕段无效"
            return
        }
        
        let currentText = transcriptionManager.segments[transcriptionManager.currentSegmentIndex].text
        guard !currentText.isEmpty else {
            aiResponse = "当前字幕内容为空"
            return
        }
        
        let prompt = "请纠错字幕、翻译为中文和解析难词和短语：\(cleanTranscriptText(currentText))"
        
        sendChatRequest(content: prompt) { result in
            switch result {
            case .success(let responseString):
                parseResponse(responseString)
            case .failure(let error):
                DispatchQueue.main.async {
                    self.aiResponse = "解析请求失败: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func parseResponse(_ response: String) {
        let lines = response.split(separator: "\n")
        
        for line in lines {
            if line.hasPrefix("data: ") {
                let jsonString = line.dropFirst(6)
                if let jsonData = jsonString.data(using: .utf8) {
                    do {
                        if let json = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                            if let event = json["event"] as? String {
                                DispatchQueue.main.async {
                                    switch event {
                                    case "req":
                                        aiResponse = ""
                                    case "loading":
                                        if let loading = json["loading"] as? Bool, loading {
                                            if aiResponse.isEmpty {
                                                aiResponse = "AI 正在思考中..."
                                            }
                                        }
                                    case "cmpl":
                                        if let text = json["text"] as? String, !text.isEmpty {
                                            if aiResponse == "AI 正在思考中..." {
                                                aiResponse = text
                                            } else {
                                                aiResponse += text
                                            }
                                        }
                                    case "all_done":
                                        if aiResponse == "AI 正在思考中..." {
                                            aiResponse = "抱歉，我暂时无法解析这段内容。"
                                        }
                                    default:
                                        break
                                    }
                                }
                            }
                        }
                    } catch {
                        print("JSON 解析错误:", error.localizedDescription)
                    }
                }
            }
        }
    }
}

private func formatTimestamp(_ seconds: Float) -> String {
    let minutes = Int(seconds) / 60
    let remainingSeconds = Int(seconds) % 60
    return String(format: "%02d:%02d", minutes, remainingSeconds)
}

private func formatTime(_ time: TimeInterval) -> String {
    let minutes = Int(time) / 60
    let seconds = Int(time) % 60
    return String(format: "%d:%02d", minutes, seconds)
}

private func formatPlaybackSpeed(_ speed: Double) -> String {
    if speed == 1.0 {
        return "1x"
    } else if speed.truncatingRemainder(dividingBy: 1) == 0 {
        return "\(Int(speed))x"
    } else {
        return "\(speed)x"
    }
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

private func sendChatRequest(content: String, completion: @escaping (Result<String, Error>) -> Void) {
    let chatID = "ct9r3qu32aquff0b9j50"
    let url = URL(string: "https://kimi.moonshot.cn/api/chat/\(chatID)/completion/stream")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJ1c2VyLWNlbnRlciIsImV4cCI6MTczOTU0NzQ3OCwiaWF0IjoxNzMxNzcxNDc4LCJqdGkiOiJjc3Nib2xuZDBwODBpaGswYmIwMCIsInR5cCI6ImFjY2VzcyIsImFwcF9pZCI6ImtpbWkiLCJzdWIiOiJjb2ZzamI5a3FxNHR0cmdhaGhxZyIsInNwYWNlX2lkIjoiY29mc2piOWtxcTR0dHJnYWhocGciLCJhYnN0cmFjdF91c2VyX2lkIjoiY29mc2piOWtxcTR0dHJnYWhocDAifQ.fPEyGwA2GNsrBAPoBVJwGde6BSdRViykCodDOwDeyeabxIuAO8dtZZ8x9gsk9kxJyknfWZ1JG2pZOnMQbQmf9w", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let json: [String: Any] = [
        "messages": [
            [
                "role": "user",
                "content": content
            ]
        ],
        "refs": [],
        "user_search": true
    ]
    
    let jsonData = try! JSONSerialization.data(withJSONObject: json, options: [])
    request.httpBody = jsonData
    
    Task {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            }
            
            for try await line in bytes.lines {
                completion(.success(line))
            }
        } catch {
            completion(.failure(error))
        }
    }
}

#Preview {
    PracticeRoomView()
        .environmentObject(AppState())
}

