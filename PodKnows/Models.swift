import Foundation
import WhisperKit
import CoreML

// 添加自定义错误类型
enum AppError: LocalizedError {
    case directoryCreationFailed
    case modelDownloadFailed(String)
    case modelLoadFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed:
            return "无法创建模型目录"
        case .modelDownloadFailed(let reason):
            return "模型下载失败: \(reason)"
        case .modelLoadFailed(let reason):
            return "模型加载失败: \(reason)"
        }
    }
}

// 应用全局状态管理
class AppState: ObservableObject {
    @Published var whisperKit: WhisperKit?
    @Published var modelState: ModelState = .unloaded
    @Published var selectedModel: String = "openai_whisper-tiny.en"
    @Published var availableModels: [String] = []
    @Published var localModels: [String] = []
    @Published var loadingProgress: Float = 0.0
    @Published var podcasts: [PodcastFeed] = []
    @Published var currentEpisode: PodcastEpisode?
    @Published var selectedTab = 2
    @Published var modelDownloadProgress: Float = 0
    @Published var isDownloadingModel: Bool = false
    
    // 计算属性 - 获取本地模型路径
    var localModelPath: String {
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let modelPath = documents.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
            
            // 确保目录存在
            try? FileManager.default.createDirectory(
                at: modelPath,
                withIntermediateDirectories: true
            )
            
            return modelPath.path
        }
        return ""
    }
    
    // 日志工具
    static func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("[\(timestamp)] [AppState] \(message)")
    }
    
    // 添加播客管理方法
    func addPodcast(_ podcast: PodcastFeed) {
        // 检查是否已存在相同的播客
        if !podcasts.contains(where: { $0.url == podcast.url }) {
            podcasts.append(podcast)
            savePodcasts()
            
            // 立即加载新添加的播客的 feed
            Task {
                do {
                    let updatedFeed = try await RSSService.shared.fetchPodcast(url: podcast.url)
                    await MainActor.run {
                        if let index = self.podcasts.firstIndex(where: { $0.id == podcast.id }) {
                            var existingPodcast = self.podcasts[index]
                            existingPodcast.update(from: updatedFeed)
                            self.podcasts[index] = existingPodcast
                            self.savePodcasts()
                        }
                    }
                } catch {
                    print("加载新添加的播客 feed 失败: \(error)")
                }
            }
        }
    }
    
    func removePodcast(_ podcast: PodcastFeed) {
        podcasts.removeAll { $0.id == podcast.id }
        savePodcasts()
    }
    
    private func savePodcasts() {
        // 保存到本地存储
        if let data = try? JSONEncoder().encode(podcasts) {
            UserDefaults.standard.set(data, forKey: "savedPodcasts")
        }
    }
    
    private func loadPodcasts() {
        // 从本地存储加载
        if let data = UserDefaults.standard.data(forKey: "savedPodcasts"),
           let savedPodcasts = try? JSONDecoder().decode([PodcastFeed].self, from: data) {
            podcasts = savedPodcasts
        }
    }
    
    init() {
        // 从本地存储加载播客
        if let data = UserDefaults.standard.data(forKey: "savedPodcasts"),
           let savedPodcasts = try? JSONDecoder().decode([PodcastFeed].self, from: data),
           !savedPodcasts.isEmpty {
            podcasts = savedPodcasts
        } else {
            podcasts = Self.defaultPodcasts
            savePodcasts()
        }
        
        // 确保默认模型在可用模型列表中
        if !availableModels.contains("openai_whisper-tiny.en") {
            availableModels.append("openai_whisper-tiny.en")
        }
        
        // 立即开始加载所有播客的 RSS feed
        loadAllPodcastFeeds()
    }
    
    // 添加加载所有播客 feed 的方法
    private func loadAllPodcastFeeds() {
        Task {
            for podcast in podcasts {
                do {
                    let updatedFeed = try await RSSService.shared.fetchPodcast(url: podcast.url)
                    await MainActor.run {
                        // 更新播客信息
                        if let index = self.podcasts.firstIndex(where: { $0.id == podcast.id }) {
                            var existingPodcast = self.podcasts[index]
                            existingPodcast.update(from: updatedFeed)
                            self.podcasts[index] = existingPodcast
                            // 保存更新后的播客列表
                            self.savePodcasts()
                        }
                    }
                } catch {
                    print("加载播客 feed 失败: \(error)")
                }
            }
        }
    }
    
    // 添加初始化 WhisperKit 的方法
    private func initializeWhisperKit() async throws {
        if whisperKit == nil {
            let config = WhisperKitConfig(
                computeOptions: nil,
                verbose: false,
                logLevel: .info,
                prewarm: false,
                load: false,
                download: false
            )
            whisperKit = try await WhisperKit(config)
            AppState.log("WhisperKit 实例已初始化")
        }
    }
    
    // 修改下载模型方法
    func downloadAndLoadModel(_ modelName: String) async throws {
        isDownloadingModel = true
        modelState = .downloading(progress: 0)
        
        do {
            // 确保 WhisperKit 实例已初始化
            try await initializeWhisperKit()
            
            // 确保目录存在
            let modelDir = try await createModelDirectory()
            let modelPath = modelDir.appendingPathComponent(modelName)
            
            // 检查模型是否已存在且可用
            if FileManager.default.fileExists(atPath: modelPath.path) {
                AppState.log("发现本地模型，尝试直接加载")
                
                guard let whisperKit = whisperKit else {
                    throw AppError.modelLoadFailed("WhisperKit 实例未初始化")
                }
                
                // 直接使用本地模型
                whisperKit.modelFolder = modelPath
                
                do {
                    AppState.log("开始加载本地模型")
                    try await whisperKit.loadModels()
                    
                    await MainActor.run {
                        if !localModels.contains(modelName) {
                            localModels.append(modelName)
                        }
                        modelState = .loaded
                        AppState.log("本地模型加载完成")
                    }
                    isDownloadingModel = false
                    return
                } catch {
                    AppState.log("本地模型加载失败，将重新下载: \(error)")
                    try? FileManager.default.removeItem(at: modelPath)
                }
            }
            
            // 如果本地模型不存在或加载失败��则下载新模型
            AppState.log("开始下载模型: \(modelName)")
            let modelURL = try await WhisperKit.download(
                variant: modelName,
                from: "argmaxinc/whisperkit-coreml",
                progressCallback: { progress in
                    Task { @MainActor in
                        self.modelDownloadProgress = Float(progress.fractionCompleted)
                        self.modelState = .downloading(progress: Float(progress.fractionCompleted))
                        AppState.log("下载进度: \(Int(self.modelDownloadProgress * 100))%")
                    }
                }
            )
            
            // 加载新下载的模型
            guard let whisperKit = whisperKit else {
                throw AppError.modelLoadFailed("WhisperKit 实例未初始化")
            }
            
            AppState.log("设置模型文件夹: \(modelURL.path)")
            whisperKit.modelFolder = modelURL
            
            AppState.log("开始加载模型")
            try await whisperKit.loadModels()
            
            await MainActor.run {
                if !localModels.contains(modelName) {
                    localModels.append(modelName)
                }
                modelState = .loaded
                AppState.log("模型加载完成")
            }
        } catch {
            AppState.log("模型下载或加载失败: \(error)")
            await MainActor.run {
                modelState = .unloaded
            }
            throw AppError.modelLoadFailed(error.localizedDescription)
        }
        
        isDownloadingModel = false
    }
    
    private func createModelDirectory() async throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw AppError.directoryCreationFailed
        }
        
        let modelDir = documents.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
        
        do {
            try FileManager.default.createDirectory(
                at: modelDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return modelDir
        } catch {
            throw AppError.directoryCreationFailed
        }
    }
}

// 模型计算单元配置
struct ModelComputeOptions {
    var melCompute: MLComputeUnits
    var audioEncoderCompute: MLComputeUnits
    var textDecoderCompute: MLComputeUnits
    var prefillCompute: MLComputeUnits
    
    init(
        melCompute: MLComputeUnits = .cpuAndGPU,
        audioEncoderCompute: MLComputeUnits = .cpuAndNeuralEngine,
        textDecoderCompute: MLComputeUnits = .cpuAndNeuralEngine,
        prefillCompute: MLComputeUnits = .cpuOnly
    ) {
        if WhisperKit.isRunningOnSimulator {
            self.melCompute = .cpuOnly
            self.audioEncoderCompute = .cpuOnly
            self.textDecoderCompute = .cpuOnly
            self.prefillCompute = .cpuOnly
            return
        }
        
        self.melCompute = melCompute
        self.audioEncoderCompute = audioEncoderCompute
        self.textDecoderCompute = textDecoderCompute
        self.prefillCompute = prefillCompute
    }
}

// 音频处理状态
enum AudioProcessingState {
    case idle
    case recording
    case processing
    case finished
    case error(String)
}

// 播客订阅源
struct PodcastFeed: Identifiable, Codable {
    var id: UUID
    var title: String
    var url: String
    var episodes: [PodcastEpisode]
    
    init(id: UUID = UUID(), title: String, url: String, episodes: [PodcastEpisode] = []) {
        self.id = id
        self.title = title
        self.url = url
        self.episodes = episodes
    }
    
    mutating func update(from feed: PodcastFeed) {
        self.title = feed.title
        self.episodes = feed.episodes
    }
}

// 播客单集
struct PodcastEpisode: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var audioUrl: String
    var duration: TimeInterval
    var publishDate: Date
    var transcription: String?
    
    init(id: UUID = UUID(), title: String, audioUrl: String, duration: TimeInterval, publishDate: Date, transcription: String? = nil) {
        self.id = id
        self.title = title
        self.audioUrl = audioUrl
        self.duration = duration
        self.publishDate = publishDate
        self.transcription = transcription
    }
    
    static func == (lhs: PodcastEpisode, rhs: PodcastEpisode) -> Bool {
        lhs.id == rhs.id
    }
}

// 在 AppState 类前添加
enum ModelState: Equatable {
    case unloaded
    case loading
    case downloading(progress: Float)
    case loaded
    
    var description: String {
        switch self {
        case .unloaded:
            return "未加载"
        case .loading:
            return "加载中"
        case .downloading(let progress):
            return "下载中 \(Int(progress * 100))%"
        case .loaded:
            return "已加载"
        }
    }
    
    // 添加比较方法
    static func == (lhs: ModelState, rhs: ModelState) -> Bool {
        switch (lhs, rhs) {
        case (.unloaded, .unloaded),
             (.loading, .loading),
             (.loaded, .loaded):
            return true
        case (.downloading(let p1), .downloading(let p2)):
            return p1 == p2
        default:
            return false
        }
    }
}

// 添加内置播客源
extension AppState {
    static let defaultPodcasts: [PodcastFeed] = [
        PodcastFeed(
            id: UUID(),
            title: "All Ears English",
            url: "https://feeds.megaphone.fm/allearsenglish",
            episodes: []
        ),
        PodcastFeed(
            id: UUID(),
            title: "How to Be American",
            url: "https://feeds.megaphone.fm/howto",
            episodes: []
        ),
        PodcastFeed(
            id: UUID(),
            title: "爱英语FM",
            url: "https://aezfm.meldingcloud.com/rss/program/5",
            episodes: []
        ),
        PodcastFeed(
            id: UUID(),
            title: "ESL Podcast",
            url: "https://www.omnycontent.com/d/playlist/e73c998e-6e60-432f-8610-ae210140c5b1/a91018a4-ea4f-4130-bf55-ae270180c327/44710ecc-10bb-48d1-93c7-ae270180c33e/podcast.rss",
            episodes: []
        )
    ]
}
