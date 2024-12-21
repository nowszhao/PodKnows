import SwiftUI

struct PodcastListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showAddPodcast = false
    @State private var isEditing = false
    @State private var selectedPodcasts = Set<UUID>()
    @State private var showDeleteConfirmation = false
    @State private var podcastToDelete: PodcastFeed?
    @State private var showBatchDeleteConfirmation = false
    
    var body: some View {
        NavigationView {
            List {
                ForEach(appState.podcasts) { podcast in
                    if isEditing {
                        PodcastRow(podcast: podcast)
                            .overlay(alignment: .leading) {
                                Image(systemName: selectedPodcasts.contains(podcast.id) ? 
                                      "checkmark.circle.fill" : "circle")
                                    .foregroundColor(.blue)
                                    .offset(x: -30)
                            }
                            .onTapGesture {
                                if selectedPodcasts.contains(podcast.id) {
                                    selectedPodcasts.remove(podcast.id)
                                } else {
                                    selectedPodcasts.insert(podcast.id)
                                }
                            }
                    } else {
                        NavigationLink(destination: PodcastDetailView(podcast: podcast)) {
                            PodcastRow(podcast: podcast)
                        }
                    }
                }
                .onDelete { indexSet in
                    if let index = indexSet.first {
                        podcastToDelete = appState.podcasts[index]
                        showDeleteConfirmation = true
                    }
                }
            }
            .navigationTitle("播客库")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(isEditing ? "完成" : "编辑") {
                        isEditing.toggle()
                        if !isEditing {
                            selectedPodcasts.removeAll()
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if isEditing && !selectedPodcasts.isEmpty {
                            Button(role: .destructive) {
                                showBatchDeleteConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                        }
                        
                        Button(action: { showAddPodcast = true }) {
                            Image(systemName: "plus")
                        }
                        .disabled(isEditing)
                    }
                }
            }
            .sheet(isPresented: $showAddPodcast) {
                AddPodcastView { podcast in
                    appState.addPodcast(podcast)
                }
            }
            .alert("确认删除", isPresented: $showDeleteConfirmation) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    if let podcast = podcastToDelete {
                        appState.removePodcast(podcast)
                    }
                }
            } message: {
                Text("确定要删除播客「\(podcastToDelete?.title ?? "")」吗？")
            }
            .alert("确认批量删除", isPresented: $showBatchDeleteConfirmation) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    for id in selectedPodcasts {
                        if let podcast = appState.podcasts.first(where: { $0.id == id }) {
                            appState.removePodcast(podcast)
                        }
                    }
                    selectedPodcasts.removeAll()
                    isEditing = false
                }
            } message: {
                Text("确定要删除选中的 \(selectedPodcasts.count) 个播客吗？")
            }
            .task {

                
            }
        }
    }
}

struct PodcastRow: View {
    let podcast: PodcastFeed
    
    var body: some View {
        VStack(alignment: .leading) {
            Text(podcast.title)
                .font(.headline)
            Text("\(podcast.episodes.count) 集")
                .font(.subheadline)
                .foregroundColor(.gray)
        }
        .padding(.vertical, 4)
    }
}

struct AddPodcastView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rssUrl = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    let onAdd: (PodcastFeed) -> Void
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("RSS 地址", text: $rssUrl)
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
                
                Section {
                    Button(action: addPodcast) {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("添加")
                        }
                    }
                    .disabled(rssUrl.isEmpty || isLoading)
                }
            }
            .navigationTitle("添加播客")
            .navigationBarItems(trailing: Button("取消") {
                dismiss()
            })
        }
    }
    
    private func addPodcast() {
        guard !rssUrl.isEmpty else { return }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let podcast = try await RSSService.shared.fetchPodcast(url: rssUrl)
                
                await MainActor.run {
                    onAdd(podcast)
                    rssUrl = ""
                    isLoading = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

struct PodcastDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let podcast: PodcastFeed
    
    var body: some View {
        List(podcast.episodes) { episode in
            Button(action: {
                // 设置当前播放的节目
                appState.currentEpisode = episode
                // 切换到练习室标签
                appState.selectedTab = 0
                // 如果在 iPad 或其他支持多列视图的设备上，关闭当前视图
                dismiss()
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(episode.title)
                        .font(.headline)
                        .lineLimit(2)
                        .foregroundColor(.primary)
                    
                    HStack {
                        Text(formatDate(episode.publishDate))
                            .font(.caption)
                        Spacer()
                        Text(formatDuration(episode.duration))
                            .font(.caption)
                    }
                    .foregroundColor(.gray)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

#Preview {
    PodcastListView()
        .environmentObject(AppState())
}
