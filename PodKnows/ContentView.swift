import SwiftUI

// 添加 LazyView 结构体
private struct LazyView<Content: View>: View {
    let build: () -> Content
    
    init(_ build: @autoclosure @escaping () -> Content) {
        self.build = build
    }
    
    var body: some View {
        build()
    }
}

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    
    var body: some View {
        TabView(selection: $appState.selectedTab) {
            LazyView(PracticeRoomView())  // 使用 LazyView 包装
                .tabItem {
                    Label("练习室", systemImage: "book")
                }
                .tag(0)
            
            PodcastListView()
                .tabItem {
                    Label("播客库", systemImage: "square.stack")
                }
                .tag(1)
            
            ProfileView()
                .tabItem {
                    Label("我的", systemImage: "person")
                }
                .tag(2)
        }
        .onChange(of: appState.selectedTab) { oldValue, newValue in
            AppState.log("切换到标签: \(newValue)")
        }
        .onAppear {
            appState.selectedTab = 2
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
} 
