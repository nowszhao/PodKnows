import AVFoundation

class AudioManager: NSObject, ObservableObject {
    private var player: AVPlayer?
    private var timeObserver: Any?
    
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isSeeking: Bool = false
    @Published var currentUrl: String = ""
    @Published var audioFormat: String = ""
    
    var isPlayerReady: Bool {
        player != nil
    }
    
    var onPlaybackFinished: (() -> Void)?
    var onPlaybackTimeUpdated: ((TimeInterval) -> Void)?
    
    override init() {
        super.init()
    }
    
    func pause(){
        player?.pause()
    }
    
    func reset() {
        // 停止当前播放
        player?.pause()
        
        // 移除时间观察器
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        
        // 重置状态
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        isSeeking = false
        currentUrl = ""
        audioFormat = "" // 重置音频格式
    }
    
    func loadAudio(from urlString: String) {
        // 在加载新音频前重置
        reset()
        
        guard let url = URL(string: urlString) else {
            print("Invalid URL: \(urlString)")
            return
        }
        
        currentUrl = urlString
        audioFormat = url.pathExtension // 设置音频格式
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        
        // 设置播放器观察器
        setupAudioPlayer()
        
        // 使用更高精度的时间观察
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 1000),
            queue: .main
        ) { [weak self] time in
            guard let self = self, !self.isSeeking else { return }
            self.currentTime = time.seconds
        }
        
        // 获取音频时长
        let duration = playerItem.asset.duration
        if duration != .invalid && duration.seconds.isFinite {
            self.duration = duration.seconds
        }
        
        // 添加状态观察
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePlaybackEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
    }
    
    func play() {
        ensurePlayerReady()
        player?.play()
    }
    
    func togglePlayPause() {
        ensurePlayerReady()
        
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
    }
    
    func seek(to time: TimeInterval) {
        isSeeking = true
        let cmTime = CMTime(seconds: time, preferredTimescale: 1000)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.isSeeking = false
        }
    }
    
    func setPlaybackRate(_ rate: Double) {
        player?.rate = Float(rate)
    }
    
    func ensurePlayerReady() {
        if player == nil && !currentUrl.isEmpty {
            loadAudio(from: currentUrl)
        }
    }
    
    @objc private func handlePlaybackEnd() {
        isPlaying = false
        onPlaybackFinished?()
    }
    
    private func setupPlayerObservers() {
        player?.actionAtItemEnd = .pause
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }
    
    @objc private func playerItemDidReachEnd() {
        onPlaybackFinished?()
    }
    
    deinit {
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupAudioPlayer() {
        player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self = self else { return }
            let currentTime = time.seconds
            self.currentTime = currentTime
            self.onPlaybackTimeUpdated?(currentTime)
        }
        
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                            object: player?.currentItem,
                                            queue: .main) { [weak self] _ in
            self?.onPlaybackFinished?()
        }
    }
}
