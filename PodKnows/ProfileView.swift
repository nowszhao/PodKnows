import SwiftUI
import WhisperKit

struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showAdvancedSettings = false
    @State private var showErrorInfo = ""
    
    var body: some View {
        NavigationView {
            List {
                // 模型选择和状态部分
                Section(header: Text("模型管理")) {
                    modelStatusView
                    modelSelectorView
                    if appState.modelState == .unloaded {
                        loadModelButton
                    }
                    
                    Text(showErrorInfo)
                    
                }
                
                // 版本信息部分
                Section(header: Text("关于")) {
                    appInfoView
                }
            }
            .navigationTitle("我的")
        }
        .onAppear {
            fetchModels()
        }
    }
    
    // MARK: - Subviews
    
    private var modelStatusView: some View {
        HStack {
            Image(systemName: "circle.fill")
                .foregroundStyle(modelStateColor)
                .symbolEffect(.variableColor, 
                            isActive: ![.loaded, .unloaded].contains(appState.modelState))
            Text(appState.modelState.description)
            Spacer()
        }
    }
    
    private var modelSelectorView: some View {
        HStack {
            if !appState.availableModels.isEmpty {
                Picker("选择模型", selection: $appState.selectedModel) {
                    // 先显示本地模型
                    ForEach(appState.availableModels.filter { appState.localModels.contains($0) }, id: \.self) { model in
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(model)
                                .foregroundColor(.primary)
                            Spacer()
                            Text("已下载")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .tag(model)
                    }
                    
                    // 如果有本地模型和远程模型，添加分隔线
                    if !appState.localModels.isEmpty && 
                       appState.availableModels.count > appState.localModels.count {
                        Divider()
                    }
                    
                    // 显示未下载的远程模型
                    ForEach(appState.availableModels.filter { !appState.localModels.contains($0) }, id: \.self) { model in
                        HStack {
                            Image(systemName: "arrow.down.circle")
                                .foregroundColor(.blue)
                            Text(model)
                                .foregroundColor(.primary)
                        }
                        .tag(model)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .onChange(of: appState.selectedModel) { _, _ in
                    appState.modelState = .unloaded
                }
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            }
        }
    }
    
    private var loadModelButton: some View {
        Button {
            Task {
                do {
                    try await appState.downloadAndLoadModel(appState.selectedModel)
                } catch {
                    AppState.log("模型加载失败: \(error)")
                    showErrorInfo = "模型加载失败: \(error)"
                }
            }
        } label: {
            if case .downloading(let progress) = appState.modelState {
                HStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.8)
                    Text("下载中 \(Int(progress * 100))%")
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
            } else {
                Text("加载模型")
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isButtonDisabled)
    }
    
    
    private var appInfoView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
               let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                Text("Knowsense Version-\(version) (\(build))")
                Text("changhongzhao@foxmail.com")
            }
        }
        .font(.system(.caption, design: .monospaced))
    }
    
    // MARK: - Methods
    
    private func fetchModels() {
        AppState.log("开始获取模型列表")
        
        // 检查本地已下载的模型
        if FileManager.default.fileExists(atPath: appState.localModelPath) {
            do {
                let downloadedModels = try FileManager.default.contentsOfDirectory(
                    atPath: appState.localModelPath
                )
                appState.localModels = downloadedModels
                AppState.log("发现本地模型: \(downloadedModels)")
            } catch {
                AppState.log("获取本地模型出错: \(error)")
                showErrorInfo = "获取本地模型出���:\(error)"
            }
        }
        
        // 获取推荐的远程模型
        Task {
            let remoteModelSupport = await WhisperKit.recommendedRemoteModels()
            await MainActor.run {
                var models = remoteModelSupport.supported
                
                // 确保默认模型在列表中
                if !models.contains("openai_whisper-tiny.en") {
                    models.insert("openai_whisper-tiny.en", at: 0)  // 插入到列表开头
                }
                
                appState.availableModels = models
                
                // 如果当前没有选择模型，设置默认模型
                if appState.selectedModel.isEmpty {
                    appState.selectedModel = "openai_whisper-tiny.en"
                }
                
                AppState.log("获取到可用模型: \(models)")
            }
        }
    }
    
    private func loadModel() {
        AppState.log("开始加载模型: \(appState.selectedModel)")
        appState.modelState = .loading
        
        Task {
            do {
                // 创建 WhisperKit 实例
                let config = WhisperKitConfig(
                    computeOptions: nil,
                    verbose: true,
                    logLevel: .debug,
                    prewarm: false,
                    load: false,
                    download: false
                )
                appState.whisperKit = try await WhisperKit(config)
                
                var modelFolder: URL?
                
                // 检查模型是否已经下载
                if appState.localModels.contains(appState.selectedModel) {
                    // 使用本地模型路径
                    modelFolder = URL(fileURLWithPath: appState.localModelPath)
                        .appendingPathComponent(appState.selectedModel)
                    AppState.log("使用本地模型路径: \(modelFolder?.path ?? "")")
                } else {
                    // 下载模型
                    AppState.log("模型未下载,开始下载")
                    modelFolder = try await WhisperKit.download(
                        variant: appState.selectedModel,
                        progressCallback: { progress in
                            DispatchQueue.main.async {
                                appState.loadingProgress = Float(progress.fractionCompleted)
                                appState.modelState = .downloading(progress: Float(progress.fractionCompleted))
                            }
                        }
                    )
                }
                
                // 设置模型文件夹路径
                if let folder = modelFolder {
                    appState.whisperKit?.modelFolder = folder
                    AppState.log("设置模型文件夹: \(folder.path)")
                    
                    // 加载模型
                    try await appState.whisperKit?.loadModels()
                    
                    await MainActor.run {
                        if !appState.localModels.contains(appState.selectedModel) {
                            appState.localModels.append(appState.selectedModel)
                        }
                        appState.modelState = .loaded
                        AppState.log("模型加载完成")
                    }
                } else {
                    showErrorInfo = "无法获取模型文件夹路径"
                    throw WhisperError.modelsUnavailable("无法获取模型文件夹路径")
                }
            } catch {
                AppState.log("模型加载失败: \(error)")
                await MainActor.run {
                    appState.modelState = .unloaded
                    showErrorInfo = "模型加载失败:\(error)"
                }
            }
        }
    }
    
    // 添加计算属性来处理状态颜色
    private var modelStateColor: Color {
        switch appState.modelState {
        case .loaded:
            return .green
        case .unloaded:
            return .red
        case .downloading:
            return .yellow
        case .loading:
            return .orange
        }
    }
    
    // 添加计算属性来处理按钮禁用状态
    private var isButtonDisabled: Bool {
        if case .downloading = appState.modelState { return true }
        return appState.modelState == .loading
    }
}

#Preview {
    ProfileView()
        .environmentObject(AppState())
} 
