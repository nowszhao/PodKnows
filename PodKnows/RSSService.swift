import Foundation
import FeedKit

class RSSService {
    static let shared = RSSService()
    
    private init() {}
    
    func fetchPodcast(url: String) async throws -> PodcastFeed {
        guard let feedURL = URL(string: url) else {
            throw URLError(.badURL)
        }
        
        let (data, _) = try await URLSession.shared.data(from: feedURL)
        let parser = FeedParser(data: data)
        let result = try await parser.parse()
        
        switch result {
        case .success(let feed):
            guard let rssFeed = feed.rssFeed else {
                throw NSError(domain: "RSSParser", code: -1, 
                            userInfo: [NSLocalizedDescriptionKey: "Invalid RSS feed format"])
            }
            
            // 解析单集
            let episodes = rssFeed.items?.compactMap { item -> PodcastEpisode? in
                guard let title = item.title,
                      let audioUrl = item.enclosure?.attributes?.url else {
                    return nil
                }
                
                // 解析时长
                let duration: TimeInterval
                if let iTunesDuration = item.iTunes?.iTunesDuration {
                    duration = iTunesDuration
                } else {
                    // 尝试从其他字段获取时长信息
                    if let durationStr = item.iTunes?.iTunesSubtitle,
                       durationStr.contains(":") {
                        duration = parseDuration(durationStr)
                    } else {
                        duration = 0
                    }
                }
                
                // 解析发布日期
                let publishDate = item.pubDate ?? Date()
                
                return PodcastEpisode(
                    title: title,
                    audioUrl: audioUrl,
                    duration: duration,
                    publishDate: publishDate
                )
            } ?? []
            
            return PodcastFeed(
                id: UUID(),
                title: rssFeed.title ?? "Unknown Podcast",
                url: url,
                episodes: episodes
            )
            
        case .failure(let error):
            throw error
        }
    }
    
    private func parseDuration(_ durationString: String) -> TimeInterval {
        // 处理 HH:MM:SS 格式
        let components = durationString.components(separatedBy: ":")
        if components.count == 3,
           let hours = Int(components[0]),
           let minutes = Int(components[1]),
           let seconds = Int(components[2]) {
            return TimeInterval(hours * 3600 + minutes * 60 + seconds)
        }
        
        // 处理 MM:SS 格式
        if components.count == 2,
           let minutes = Int(components[0]),
           let seconds = Int(components[1]) {
            return TimeInterval(minutes * 60 + seconds)
        }
        
        // 处理纯秒数
        if let seconds = Int(durationString) {
            return TimeInterval(seconds)
        }
        
        return 0
    }
} 