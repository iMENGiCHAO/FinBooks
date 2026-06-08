import SwiftUI
import AppKit

// MARK: - Bridge 服务管理器
@MainActor
final class BridgeManager: ObservableObject {
    static let shared = BridgeManager()

    /// 可靠解析项目根目录（支持 .app 包、源码、已安装三种模式）
    static func resolveProjectRoot() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        if let res = Bundle.main.resourceURL,
           fm.fileExists(atPath: res.appendingPathComponent("scripts/finbooks_bridge.py").path) {
            return res
        }
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        if fm.fileExists(atPath: bundleParent.appendingPathComponent("scripts/finbooks_bridge.py").path) {
            return bundleParent
        }
        let installed = home.appendingPathComponent(".hermes/scripts")
        if fm.fileExists(atPath: installed.appendingPathComponent("finbooks_bridge.py").path) {
            return installed.deletingLastPathComponent()
        }
        let alt = home.appendingPathComponent(".finbooks")
        if fm.fileExists(atPath: alt.appendingPathComponent("scripts/finbooks_bridge.py").path) {
            return alt
        }
        var dev = URL(fileURLWithPath: #file)
        for _ in 0..<4 { dev.deleteLastPathComponent() }
        return fm.fileExists(atPath: dev.appendingPathComponent("scripts/finbooks_bridge.py").path) ? dev : nil
    }
    
    @Published var isRunning = false
    @Published var lastError: String?
    private var bridgeProcess: Process?
    private var healthCheckTimer: Timer?
    
    /// 启动 Bridge 服务（自动检测端口，带重试）
    func start(retries: Int = 3) {
        guard bridgeProcess == nil else { return }
        
        let savedPort = UserDefaults.standard.integer(forKey: "finbooks_bridge_port")
        let port = savedPort > 0 ? savedPort : 9090
        
        // 检查是否已经在运行（带重试）
        checkHealthWithRetry(port: port, retries: retries)
    }
    
    /// 带指数退避的健康检查重试
    private func checkHealthWithRetry(port: Int, retries: Int, attempt: Int = 1) {
        checkHealth(port: port) { [weak self] running in
            DispatchQueue.main.async {
                if running {
                    print("[Bridge] 已在运行 port=\(port)")
                    self?.isRunning = true
                    return
                }
                if attempt >= retries {
                    self?.launchBridgeProcess(port: port)
                    return
                }
                let delay = min(Double(attempt) * 0.5, 2.0)
                print("[Bridge] 等待重启 (attempt \(attempt)/\(retries), delay \(delay)s)")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self?.checkHealthWithRetry(port: port, retries: retries, attempt: attempt + 1)
                }
            }
        }
    }
    
    
    private func checkHealth(port: Int, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            completion(false); return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["status"] as? String == "ok" {
                Task { @MainActor in self.isRunning = true }
                completion(true)
            } else {
                completion(false)
            }
        }.resume()
    }
    
    private func startHealthCheck(port: Int) {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            Task { @MainActor in
                self.checkHealth(port: port) { _ in }
            }
        }
    }
    
    func stop() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        bridgeProcess?.terminate()
        bridgeProcess = nil
        isRunning = false
        lastError = nil
    }

    
    /// 启动 Bridge 进程（Python 后端服务）
    func launchBridgeProcess(port: Int) {
        let fm = FileManager.default
        guard let projectRoot = Self.resolveProjectRoot() else {
            lastError = "无法定位项目根目录，请确认 FinBooks 安装完整"
            print("[Bridge] ❌ 无法定位 Bridge 脚本")
            return
        }
        let candidates = [
            projectRoot.appendingPathComponent("scripts/finbooks_bridge.py"),
            projectRoot.appendingPathComponent("finbooks_bridge.py"),
            Bundle.main.resourceURL?.appendingPathComponent("scripts/finbooks_bridge.py"),
        ].compactMap { $0 }
        for bridgePath in candidates where fm.fileExists(atPath: bridgePath.path) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [bridgePath.path, "--port", "\(port)"]
            do {
                try proc.run()
                bridgeProcess = proc
                isRunning = true
                startHealthCheck(port: port)
                print("[Bridge] ✅ 已启动 port=\(port) script=\(bridgePath.path)")
            } catch {
                lastError = "启动 Bridge 失败: \(error.localizedDescription)"
                print("[Bridge] ❌ 启动失败: \(error)")
            }
            return
        }
        lastError = "未找到 finbooks_bridge.py"
        print("[Bridge] ❌ 未找到 Bridge 脚本")
    }}

// MARK: - 首次运行检测
private func isFirstRun() -> Bool {
    !UserDefaults.standard.bool(forKey: "finbooks_first_run_complete")
}

private func detectInstalledAgents() -> [String] {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    var agents: [String] = []
    if fm.fileExists(atPath: home.appendingPathComponent(".hermes").path) { agents.append("Hermes") }
    if fm.fileExists(atPath: home.appendingPathComponent(".openclaw").path) { agents.append("OpenClaw") }
    if fm.fileExists(atPath: home.appendingPathComponent(".codex").path) { agents.append("Codex") }
    return agents
}

private func checkPluginInstalled(_ agentName: String) -> Bool {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    switch agentName {
    case "Hermes": return fm.fileExists(atPath: home.appendingPathComponent(".hermes/plugins/finbooks/plugin.yaml").path)
    case "OpenClaw": return fm.fileExists(atPath: home.appendingPathComponent(".openclaw/plugins/finbooks/plugin.yaml").path)
    case "Codex": return fm.fileExists(atPath: home.appendingPathComponent(".codex/plugins/finbooks/plugin.json").path)
    default: return false
    }
}

/// 用户确认后注入 Demo 数据（纯 Swift，不依赖外部 Python 脚本）
@MainActor
private func injectDemoDataIfNeeded() {
    let injected = UserDefaults.standard.bool(forKey: "finbooks_demo_data_injected")
    guard !injected, DataStore.shared.companies.isEmpty else { return }
    DataStore.shared.createDemoData()
    UserDefaults.standard.set(true, forKey: "finbooks_demo_data_injected")
    print("[Demo] 示例数据已注入")
}

// MARK: - 首次运行设置视图
struct FirstRunSetupView: View {
    @State private var step = 1
    @State private var detectedAgents: [String] = []
    @State private var installing = false
    @State private var installComplete = false
    @State private var createDemo = true
    var onComplete: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "building.columns.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("欢迎使用 FinBooks")
                        .font(.title2).bold()
                    Text("AI 智能财务管理 — 开箱即用")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 24)
            
            if step == 1 {
                welcomeStep
            } else if step == 2 {
                agentDetectionStep
            } else if step == 3 {
                installStep
            } else {
                completeStep
            }
        }
        .frame(width: 480, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // Step 1: Welcome + Demo data
    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 48))
                .foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            
            Text("一站式财务管理")
                .font(.headline)
            Text("会计凭证 · 三大报表 · 增值税申报 · 固定资产 · 银行对账\n支持 Hermes / OpenClaw / Codex 智能体联动")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Toggle(isOn: $createDemo) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("创建示例数据")
                        .font(.subheadline).bold()
                    Text("预置公司、科目、凭证和报表，方便快速体验完整功能")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 40)
            
            Button("开始设置 →") {
                detectedAgents = detectInstalledAgents()
                if createDemo { /* Demo in final step */ }
                step = 2
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
    
    // Step 2: Agent detection
    private var agentDetectionStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.blue)
            Text("检测到以下智能体环境")
                .font(.headline)
            
            if detectedAgents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2).foregroundStyle(.orange)
                    Text("未检测到本地智能体")
                        .font(.subheadline)
                    Text("请先安装 Hermes/OpenClaw/Codex，或直接使用 FinBooks AI 助手")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                
                Button("跳过安装 →") { step = 3 }
                    .buttonStyle(.borderedProminent)
            } else {
                ForEach(detectedAgents, id: \.self) { agent in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(checkPluginInstalled(agent) ? .green : .orange)
                        Text(agent)
                            .font(.subheadline).bold()
                        Spacer()
                        Text(checkPluginInstalled(agent) ? "已安装" : "待安装")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 4)
                }
                
                HStack(spacing: 12) {
                    Button("跳过安装") { step = 3 }
                        .buttonStyle(.bordered)
                    Button("安装到所有智能体") {
                        installing = true
                        Task {
                            let fm = FileManager.default
                            let home = fm.homeDirectoryForCurrentUser
                            // 查找安装脚本
                            let scriptCandidates: [URL?] = [
                                Bundle.main.resourceURL?.appendingPathComponent("scripts/install_finbooks_plugin.sh"),
                                home.appendingPathComponent(".hermes/scripts/install_finbooks_plugin.sh"),
                                URL(fileURLWithPath: #file).deletingLastPathComponent()
                                    .appendingPathComponent("../../scripts/install_finbooks_plugin.sh"),
                            ]
                            @Sendable func runInstall(at url: URL) async -> Bool {
                                return await withCheckedContinuation { continuation in
                                    let proc = Process()
                                    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
                                    proc.arguments = [url.path]
                                    proc.qualityOfService = .utility
                                    proc.terminationHandler = { process in
                                        continuation.resume(returning: process.terminationStatus == 0)
                                    }
                                    try? proc.run()
                                }
                            }
                            var installed = false
                            for scriptURL in scriptCandidates {
                                guard let path = scriptURL, fm.fileExists(atPath: path.path) else { continue }
                                if await runInstall(at: path) { installed = true; break }
                            }
                            // Fallback: 从 .app Resource 内直接复制 plugin 文件
                            if !installed, let res = Bundle.main.resourceURL {
                                let agents: [(String, String, String)] = [
                                    ("hermes", "\(home.path)/.hermes/plugins/finbooks", "\(res.path)/.hermes-plugin"),
                                    ("openclaw", "\(home.path)/.openclaw/plugins/finbooks", "\(res.path)/.openclaw-plugin"),
                                    ("codex", "\(home.path)/.codex/plugins/finbooks", "\(res.path)/.codex-plugin"),
                                ]
                                for (_, dest, src) in agents where fm.fileExists(atPath: src) {
                                    try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
                                    for item in (try? fm.contentsOfDirectory(atPath: src)) ?? [] {
                                        guard !item.hasPrefix(".") else { continue }
                                        try? fm.copyItem(atPath: "\(src)/\(item)", toPath: "\(dest)/\(item)")
                                    }
                                }
                                installed = true
                            }
                            installComplete = installed
                            installing = false
                            step = 3
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(installing)
                }
            }
        }
    }
    
    // Step 3: Install progress / complete
    private var installStep: some View {
        VStack(spacing: 20) {
            Image(systemName: installComplete ? "checkmark.circle.fill" : "gearshape.2.fill")
                .font(.system(size: 48))
                .foregroundStyle(installComplete ? .green : .blue)
            
            Text(installComplete ? "设置完成" : "准备就绪")
                .font(.headline)
            
            if installComplete {
                Text(detectedAgents.isEmpty
                     ? "FinBooks 已就绪，可随时通过 AI 助手体验财务功能"
                     : "已为检测到的智能体安装 FinBooks 插件，重启智能体后生效")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                
                Text("💡 提示：后续随时可在 AI 助手中点击「适配本地智能体」安装或更新插件")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            
            Button("开始使用 FinBooks") {
                // 用户确认后才注入 Demo 数据
                if createDemo { injectDemoDataIfNeeded() }
                UserDefaults.standard.set(true, forKey: "finbooks_first_run_complete")
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
    
    // Step 4: Already complete
    private var completeStep: some View {
        installStep
    }
}

// MARK: - App Entry
@main
struct FinBooksApp: App {
    @StateObject private var dataStore = DataStore.shared
    @StateObject private var bridgeManager = BridgeManager.shared
    @State private var showFirstRunSetup = isFirstRun()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dataStore)
                .environmentObject(bridgeManager)
                .onAppear {
                    // 延迟一秒后自动启动 Bridge
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        bridgeManager.start()
                    }
                }
                .sheet(isPresented: $showFirstRunSetup) {
                    FirstRunSetupView {
                        showFirstRunSetup = false
                    }
                }
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            // 文件菜单 — 刷新数据
            CommandGroup(after: .saveItem) {
                Button("从磁盘刷新数据") {
                    DataStore.shared.refreshFromDisk()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                
                Divider()
                
                Button(bridgeManager.isRunning ? "Bridge 运行中" : "启动 Bridge") {
                    if bridgeManager.isRunning {
                        bridgeManager.stop()
                    } else {
                        bridgeManager.start()
                    }
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }
    }
}
