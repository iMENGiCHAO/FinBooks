import SwiftUI


/// 动态解析 FinBooks 项目根目录（支持 .app 包和源码运行两种模式）

@MainActor

private func finbooksProjectDir() -> URL {

    if let root = BridgeManager.resolveProjectRoot() {
        return root

    }

    var path = URL(fileURLWithPath: #file)

    for _ in 0...5 { path.deleteLastPathComponent() }

    return path

}

/// 从 plugin.json 读取插件版本号（供导出插件包命名使用）
@MainActor
private func finbooksPluginVersion() -> String {
    let fm = FileManager.default
    let pluginJsonPath = finbooksProjectDir().appendingPathComponent(".codex-plugin/plugin.json")
    guard fm.fileExists(atPath: pluginJsonPath.path),
          let data = try? Data(contentsOf: pluginJsonPath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let version = json["version"] as? String, !version.isEmpty else {
        return "2.4.0"
    }
    return version
}


/// 查找 .app 包内嵌入的 Resources（桥接脚本、插件文件）

/// 优先返回 .app bundle 内的 Resources，其次回退到项目目录

@MainActor

private func finbooksBundleResourcesDir() -> URL {

    if let root = BridgeManager.resolveProjectRoot() {

        let fm = FileManager.default

        let scriptsTest = root.appendingPathComponent("scripts/finbooks_bridge.py")

        if fm.fileExists(atPath: scriptsTest.path) {

            return root

        }

        let directTest = root.appendingPathComponent("finbooks_bridge.py")

        if fm.fileExists(atPath: directTest.path) {

            return root.deletingLastPathComponent()

        }

        return root

    }

    return finbooksProjectDir()

}


// MARK: - AI 助手浮动窗口 — 纯聊天终端


struct AIChatWindow: View {

    @StateObject private var assistant = AIAssistant.shared
    @State private var inputText = ""
    @FocusState private var isFocused: Bool

    @State private var showSettings = false
    @State private var showPluginManager = false

    @State private var agentInstallStatus = AgentInstallStatus.checking
    @State private var hermesPluginStatus = AgentInstallStatus.checking
    @State private var openclawPluginStatus = AgentInstallStatus.checking
    @State private var codexInstalled = AgentInstallStatus.checking

    @State private var showInstallAlert = false
    @State private var installAlertMessage = ""
    @State private var installProgressStep = InstallProgressStep.idle
    @State private var exportSuccessAlert = false
    @State private var exportAlertMessage = ""

    enum InstallProgressStep {
        case idle, detecting, startingBridge, inspectingBridge, installingHermes, installingOpenclaw, installingCodex, done, error
        var isActive: Bool {
            switch self {
            case .idle, .done, .error: return false
            default: return true
            }
        }
        var label: String {
            switch self {
            case .idle: return "准备安装"
            case .detecting: return "检测本地代理"
            case .startingBridge: return "启动 Bridge 服务"
            case .inspectingBridge: return "检测 Bridge 连接"
            case .installingHermes: return "安装 Hermes 插件"
            case .installingOpenclaw: return "安装 OpenClaw 插件"
            case .installingCodex: return "安装 Codex 插件"
            case .done: return "安装完成"
            case .error: return "安装失败"
            }
        }
    }

    enum AgentInstallStatus {

        case checking, installed, notInstalled, installing, error

        var icon: String {
            switch self {
            case .checking: return "hourglass"
            case .installed: return "checkmark.seal.fill"
            case .notInstalled: return "exclamationmark.triangle"
            case .installing: return "gearshape.arrow.triangle.2.circlepath"
            case .error: return "xmark.octagon.fill"
            }
        }
        var color: Color {
            switch self {
            case .checking: return .secondary
            case .installed: return .green
            case .notInstalled: return .orange
            case .installing: return .blue
            case .error: return .red
            }
        }
        var label: String {
            switch self {
            case .checking: return "检测中"
            case .installed: return "已安装"
            case .notInstalled: return "未安装"
            case .installing: return "安装中"
            case .error: return "错误"
            }
        }
    }

    private func _makeBadge(_ status: AgentInstallStatus) -> some View {
        HStack(spacing: 3) {
            Image(systemName: status.icon)
                .font(.caption2)
            Text(status.label)
                .font(.caption2)
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(status.color.opacity(0.1))
        .cornerRadius(4)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar

            Divider()

            pluginStatusBar

            scrollMessages

            Divider()

            quickChips

            Divider()

            inputArea
        }
        .frame(width: 400, height: 560)
        .overlay(alignment: .bottom) {
            if installProgressStep.isActive || installProgressStep == .done {
                installProgressBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: installProgressStep)
            }
        }
        .alert("智能体插件", isPresented: $showInstallAlert) {
            Button("确定") { checkPluginDirectories() }
        } message: {
            Text(installAlertMessage)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showPluginManager) {
            PluginManagerView(
                bridgeStatus: $agentInstallStatus,
                hermesStatus: $hermesPluginStatus,
                openclawStatus: $openclawPluginStatus,
                codexStatus: $codexInstalled,
                onInstall: { installAgentPlugin() },
                onUninstall: { uninstallAgentPlugin() },
                onRefresh: { checkAgentStatus() },
                onInstallHermes: { installSingleAgentPlugin(agent: "hermes") },
                onInstallOpenclaw: { installSingleAgentPlugin(agent: "openclaw") },
                onInstallCodex: { installSingleAgentPlugin(agent: "codex") },
                onUninstallHermes: { uninstallSingleAgentPlugin(agent: "hermes") },
                onUninstallOpenclaw: { uninstallSingleAgentPlugin(agent: "openclaw") },
                onUninstallCodex: { uninstallSingleAgentPlugin(agent: "codex") }
            )
        }
        .onAppear { checkAgentStatus() }
    }

    // MARK: - 标题栏

    private var titleBar: some View {
        HStack {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            Text("AI 财务助手")
                .font(.headline)
            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - 插件状态栏

    private var pluginStatusBar: some View {
        HStack(spacing: 8) {
            _makeBadge(agentInstallStatus)
            _makeBadge(hermesPluginStatus)
            _makeBadge(openclawPluginStatus)
            _makeBadge(codexInstalled)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - 消息滚动区

    private var scrollMessages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(assistant.messages) { msg in
                        ChatBubble(message: msg)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onChange(of: assistant.messages.count) { _, _ in
                if let last = assistant.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - 快捷芯片

    private var quickChips: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                quickChip("总资产")
                quickChip("本月利润")
                quickChip("资产负债表")
                quickChip("银行对账")
                quickChip("企业所得税")
                quickChip("审计底稿")
                quickChip("税务导出")
                Spacer()
            }
            .padding(.horizontal, 12)
            HStack(spacing: 6) {
                installChip("安装插件", icon: "arrow.down.to.line.compact", action: installAgentPlugin)
                installChip("导出插件包", icon: "shippingbox", action: { showPluginManager = true })
                installChip("插件管理", icon: "puzzlepiece.extension.fill", action: { showPluginManager = true })
                Spacer()
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 输入区

    private var inputArea: some View {
        HStack(spacing: 6) {
            TextField("输入财务问题…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .lineLimit(1...4)
                .focused($isFocused)
                .onSubmit { send() }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - 安装进度条

    private var installProgressBar: some View {
        VStack(spacing: 2) {
            if installProgressStep == .done {
                Label("安装完成 ✓", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(installProgressStep.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - 发送消息

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        isFocused = true

        if let ctx = companyContext?() {
            assistant.send(text, contextData: [
                "companyName": ctx.name,
                "summary": ctx.summary,
                "apiKey": AgentConfigManager.shared.effectiveAPIKey,
                "model": AgentConfigManager.shared.activeAgent?.model ?? "deepseek-chat",
                "baseURL": AgentConfigManager.shared.effectiveBaseURL
            ])
        } else {
            assistant.send(text)
        }
    }

    @ViewBuilder
    private func quickChip(_ label: String) -> some View {
        Button(label) {
            inputText = label
            isFocused = true
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.1))
        .foregroundStyle(Color.accentColor)
        .cornerRadius(8)
        .buttonStyle(.plain)
    }

    private func installChip(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Label(label, systemImage: icon)
                .font(.caption2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.green.opacity(0.1))
        .foregroundStyle(.green)
        .cornerRadius(8)
        .buttonStyle(.plain)
    }

    // MARK: - 智能体检测

    private func checkAgentStatus() {
        agentInstallStatus = .checking
        hermesPluginStatus = .checking
        openclawPluginStatus = .checking
        codexInstalled = .checking
        checkPluginDirectories()
        Task { await checkBridgeHealth() }
    }

    private func checkBridgeHealth() async {
        let savedPort = UserDefaults.standard.integer(forKey: "finbooks_bridge_port")
        let port = savedPort > 0 ? savedPort : 9090
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                agentInstallStatus = .installed
            }
        } catch {
            agentInstallStatus = .notInstalled
        }
    }

    private func checkPluginDirectories() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        hermesPluginStatus = fm.fileExists(atPath: home.appendingPathComponent(".hermes/plugins/finbooks").path) ? .installed : .notInstalled
        openclawPluginStatus = fm.fileExists(atPath: home.appendingPathComponent(".openclaw/plugins/finbooks").path) ? .installed : .notInstalled
        codexInstalled = fm.fileExists(atPath: home.appendingPathComponent(".codex/plugins/finbooks").path) ? .installed : .notInstalled
    }

    // MARK: - 安装插件（全部智能体）

    private func installAgentPlugin() {
        installProgressStep = .detecting
        hermesPluginStatus = .installing
        openclawPluginStatus = .installing
        codexInstalled = .installing
        Task {
            let savedPort = UserDefaults.standard.integer(forKey: "finbooks_bridge_port")
            let port = savedPort > 0 ? savedPort : 9090
            guard let url = URL(string: "http://127.0.0.1:\(port)/api/plugin/install-to-agent") else {
                await fallbackInstallAgentPlugin()
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["agent": "all"])
            request.timeoutInterval = 30
            do {
                installProgressStep = .inspectingBridge
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                    await fallbackInstallAgentPlugin()
                    return
                }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let results = json["results"] as? [String: String] {
                    installAlertMessage = "🎉 安装成功!\n"
                    for (agent, status) in results {
                        installAlertMessage += "✅ \(agent): \(status)\n"
                    }
                    installAlertMessage += "\nBridge 运行在 localhost:\(port)\n现在可以在智能体对话中使用财务工具!"
                    agentInstallStatus = .installed
                    hermesPluginStatus = .installed
                    openclawPluginStatus = .installed
                    codexInstalled = .installed
                    installProgressStep = .done
                    showInstallAlert = true
                    checkPluginDirectories()
                    return
                }
            } catch {
                print("[FinBooks] Bridge API unavailable: \(error.localizedDescription)")
            }
            await fallbackInstallAgentPlugin()
        }
    }

    private func fallbackInstallAgentPlugin() async {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let projectRoot = finbooksProjectDir()
        let scriptPaths = [
            projectRoot.appendingPathComponent("scripts/install_finbooks_plugin.sh"),
            projectRoot.appendingPathComponent("../scripts/install_finbooks_plugin.sh"),
            projectRoot.appendingPathComponent("../../scripts/install_finbooks_plugin.sh"),
            home.appendingPathComponent(".hermes/scripts/install_finbooks_plugin.sh"),
        ]
        var installed = false
        for scriptPath in scriptPaths {
            if fm.fileExists(atPath: scriptPath.path) {
                installProgressStep = .inspectingBridge
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [scriptPath.path]
                process.environment = ProcessInfo.processInfo.environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                try? process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    installed = true
                    installAlertMessage = "🎉 安装成功!\n\nBridge 已启动在 localhost:9090\nHermes/OpenClaw/Codex 插件已安装\n开机自启动已设置"
                    break
                }
            }
        }
        if !installed {
            do {
                installProgressStep = .installingHermes
                try installPluginsDirectly()
                installAlertMessage = "✅ 插件文件已直接安装到本地智能体"
            } catch {
                installProgressStep = .error
                installAlertMessage = "安装失败: \(error.localizedDescription)\n手动安装: bash \(projectRoot.path)/scripts/install_finbooks_plugin.sh"
            }
        }
        if installProgressStep != .error {
            installProgressStep = .done
        }
        agentInstallStatus = .installed
        hermesPluginStatus = .installed
        openclawPluginStatus = .installed
        codexInstalled = .installed
        showInstallAlert = true
        checkPluginDirectories()
    }

    // MARK: - 单个智能体安装

    private func installSingleAgentPlugin(agent: String) {
        installProgressStep = .installingHermes
        if agent == "hermes" { hermesPluginStatus = .installing }
        else if agent == "openclaw" { openclawPluginStatus = .installing }
        else if agent == "codex" { codexInstalled = .installing }
        Task {
            let savedPort = UserDefaults.standard.integer(forKey: "finbooks_bridge_port")
            let port = savedPort > 0 ? savedPort : 9090
            guard let url = URL(string: "http://127.0.0.1:\(port)/api/plugin/install-to-agent") else {
                await fallbackInstallSingleAgentPlugin(agent: agent)
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["agent": agent])
            request.timeoutInterval = 15
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                    await fallbackInstallSingleAgentPlugin(agent: agent)
                    return
                }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let results = json["results"] as? [String: String],
                   let status = results[agent] {
                    installAlertMessage = "✅ \(agent): \(status)"
                    if agent == "hermes" { hermesPluginStatus = .installed }
                    else if agent == "openclaw" { openclawPluginStatus = .installed }
                    else if agent == "codex" { codexInstalled = .installed }
                    installProgressStep = .done
                    showInstallAlert = true
                    checkPluginDirectories()
                    return
                }
            } catch {
                print("[FinBooks] Bridge API unavailable for \(agent): \(error.localizedDescription)")
            }
            await fallbackInstallSingleAgentPlugin(agent: agent)
        }
    }

    private func fallbackInstallSingleAgentPlugin(agent: String) async {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let projectDir = finbooksBundleResourcesDir()
        let agentDir = home.appendingPathComponent(".\(agent)")
        guard fm.fileExists(atPath: agentDir.path) else {
            installAlertMessage = "⚠️ \(agent) 未安装，请先安装 \(agent) 智能体"
            showInstallAlert = true
            return
        }
        let pluginDest = agentDir.appendingPathComponent("plugins/finbooks")
        try? fm.createDirectory(at: pluginDest, withIntermediateDirectories: true)
        let pluginSrcDir: String
        switch agent {
        case "hermes": pluginSrcDir = ".hermes-plugin"
        case "openclaw": pluginSrcDir = ".openclaw-plugin"
        case "codex": pluginSrcDir = ".codex-plugin"
        default:
            installAlertMessage = "❌ 未知智能体: \(agent)"
            showInstallAlert = true
            return
        }
        let srcDir = projectDir.appendingPathComponent(pluginSrcDir)
        guard fm.fileExists(atPath: srcDir.path) else {
            installAlertMessage = "❌ 插件源目录不存在: \(srcDir.path)"
            showInstallAlert = true
            return
        }
        do {
            try? fm.removeItem(at: pluginDest)
            try fm.createDirectory(at: pluginDest, withIntermediateDirectories: true)
            let items = try fm.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil)
            for item in items {
                try fm.copyItem(at: item, to: pluginDest.appendingPathComponent(item.lastPathComponent))
            }
            if agent == "hermes" {
                let bridgeSrc = projectDir.appendingPathComponent("scripts/finbooks_bridge.py")
                let bridgeDst = agentDir.appendingPathComponent("scripts/finbooks_bridge.py")
                try? fm.createDirectory(at: agentDir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
                if fm.fileExists(atPath: bridgeSrc.path) {
                    try? fm.copyItem(at: bridgeSrc, to: bridgeDst)
                }
            }
            installAlertMessage = "✅ \(agent) 插件已安装成功！\n\n请重启 \(agent) 智能体以加载新工具。"
            if agent == "hermes" { hermesPluginStatus = .installed }
            else if agent == "openclaw" { openclawPluginStatus = .installed }
            else if agent == "codex" { codexInstalled = .installed }
        } catch {
            installAlertMessage = "❌ \(agent) 安装失败: \(error.localizedDescription)"
        }
        installProgressStep = .done
        showInstallAlert = true
        checkPluginDirectories()
    }

    private func uninstallSingleAgentPlugin(agent: String) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let agentDir = home.appendingPathComponent(".\(agent)")
        guard fm.fileExists(atPath: agentDir.path) else {
            installAlertMessage = "⚠️ \(agent) 未安装"
            showInstallAlert = true
            return
        }
        let pluginDest = agentDir.appendingPathComponent("plugins/finbooks")
        if fm.fileExists(atPath: pluginDest.path) {
            try? fm.removeItem(at: pluginDest)
            installAlertMessage = "✅ \(agent) 插件已卸载"
        } else {
            installAlertMessage = "\(agent) 插件未安装"
        }
        if agent == "hermes" { hermesPluginStatus = .notInstalled }
        else if agent == "openclaw" { openclawPluginStatus = .notInstalled }
        else if agent == "codex" { codexInstalled = .notInstalled }
        showInstallAlert = true
        checkPluginDirectories()
    }

    // MARK: - 直接复制插件文件

    private func installPluginsDirectly() throws {
        let fm = FileManager.default
        installProgressStep = .installingHermes
        let home = fm.homeDirectoryForCurrentUser
        let projectDir = finbooksBundleResourcesDir()

        let hermesPluginDir = home.appendingPathComponent(".hermes/plugins/finbooks")
        try fm.createDirectory(at: hermesPluginDir, withIntermediateDirectories: true)
        let hermesPluginSrc = projectDir.appendingPathComponent(".hermes-plugin")
        if fm.fileExists(atPath: hermesPluginSrc.path) {
            let items = try fm.contentsOfDirectory(at: hermesPluginSrc, includingPropertiesForKeys: nil)
            for item in items {
                try? fm.copyItem(at: item, to: hermesPluginDir.appendingPathComponent(item.lastPathComponent))
            }
        }

        installProgressStep = .installingOpenclaw
        let openclawPluginDir = home.appendingPathComponent(".openclaw/plugins/finbooks")
        try fm.createDirectory(at: openclawPluginDir, withIntermediateDirectories: true)
        let openclawPluginSrc = projectDir.appendingPathComponent(".openclaw-plugin")
        if fm.fileExists(atPath: openclawPluginSrc.path) {
            let items = try fm.contentsOfDirectory(at: openclawPluginSrc, includingPropertiesForKeys: nil)
            for item in items {
                try? fm.copyItem(at: item, to: openclawPluginDir.appendingPathComponent(item.lastPathComponent))
            }
        }

        installProgressStep = .installingCodex
        let codexPluginDir = home.appendingPathComponent(".codex/plugins/finbooks")
        try fm.createDirectory(at: codexPluginDir, withIntermediateDirectories: true)
        let codexPluginSrc = projectDir.appendingPathComponent(".codex-plugin")
        if fm.fileExists(atPath: codexPluginSrc.path) {
            let items = try fm.contentsOfDirectory(at: codexPluginSrc, includingPropertiesForKeys: nil)
            for item in items {
                try? fm.copyItem(at: item, to: codexPluginDir.appendingPathComponent(item.lastPathComponent))
            }
        }

        let bridgeSrc = projectDir.appendingPathComponent("scripts/finbooks_bridge.py")
        let bridgeDst = home.appendingPathComponent(".hermes/scripts/finbooks_bridge.py")
        try? fm.createDirectory(at: home.appendingPathComponent(".hermes/scripts"), withIntermediateDirectories: true)
        if fm.fileExists(atPath: bridgeSrc.path) {
            try? fm.copyItem(at: bridgeSrc, to: bridgeDst)
        }
        installProgressStep = .done
        // 安装完成后启动 Bridge 服务
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.startBridgeService()
        }
    }
    
    // MARK: - 启动 Bridge 服务（自动 + LaunchAgent 自启）
    
    private func startBridgeService() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let bridgePath = home.appendingPathComponent(".hermes/scripts/finbooks_bridge.py")
        
        // 1. 先检查是否已经在运行
        let savedPort = UserDefaults.standard.integer(forKey: "finbooks_bridge_port")
        let port = savedPort > 0 ? savedPort : 9090
        let checkURL = URL(string: "http://127.0.0.1:\(port)/health")!
        let semaphore = DispatchSemaphore(value: 0)
        var alreadyRunning = false
        let task = URLSession.shared.dataTask(with: checkURL) { _, resp, _ in
            if let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 {
                alreadyRunning = true
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 2.0)
        
        if alreadyRunning {
            print("[FinBooks] Bridge 已在运行 (localhost:\(port))")
            return
        }
        
        // 2. 启动 Bridge 进程
        guard fm.fileExists(atPath: bridgePath.path) else {
            print("[FinBooks] Bridge 脚本不存在: \(bridgePath.path)")
            return
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [bridgePath.path]
        process.environment = ProcessInfo.processInfo.environment
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            print("[FinBooks] Bridge 进程已启动 (PID: \(process.processIdentifier))")
            
            // 3. 设置 LaunchAgent 开机自启
            setupLaunchAgent()
        } catch {
            print("[FinBooks] 启动 Bridge 失败: \(error.localizedDescription)")
        }
    }
    
    private func setupLaunchAgent() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let launchAgentDir = home.appendingPathComponent("Library/LaunchAgents")
        try? fm.createDirectory(at: launchAgentDir, withIntermediateDirectories: true)
        
        let plistPath = launchAgentDir.appendingPathComponent("com.finbooks.bridge.plist")
        let bridgeScript = home.appendingPathComponent(".hermes/scripts/finbooks_bridge.py").path
        
        let plistContent = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.finbooks.bridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>\(bridgeScript)</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>\(home.appendingPathComponent(".hermes").path)</string>
    <key>StandardOutPath</key>
    <string>\(home.appendingPathComponent(".hermes/logs/bridge.stdout.log").path)</string>
    <key>StandardErrorPath</key>
    <string>\(home.appendingPathComponent(".hermes/logs/bridge.stderr.log").path)</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
        <key>PYTHONUNBUFFERED</key>
        <string>1</string>
    </dict>
</dict>
</plist>
"""
        do {
            try? fm.createDirectory(at: home.appendingPathComponent(".hermes/logs"), withIntermediateDirectories: true)
            try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
            
            // 加载 LaunchAgent
            let loadProcess = Process()
            loadProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            loadProcess.arguments = ["load", "-w", plistPath.path]
            try loadProcess.run()
            loadProcess.waitUntilExit()
            print("[FinBooks] LaunchAgent 已设置: \(plistPath.path)")
        } catch {
            print("[FinBooks] 设置 LaunchAgent 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 卸载插件（全部）

    private func uninstallAgentPlugin() {
        Task {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            var removed = false
            var messages: [String] = []
            let hermesPath = home.appendingPathComponent(".hermes/plugins/finbooks")
            if fm.fileExists(atPath: hermesPath.path) {
                try? fm.removeItem(at: hermesPath)
                removed = true
                messages.append("✅ Hermes 插件已删除")
            }
            let openclawPath = home.appendingPathComponent(".openclaw/plugins/finbooks")
            if fm.fileExists(atPath: openclawPath.path) {
                try? fm.removeItem(at: openclawPath)
                removed = true
                messages.append("✅ OpenClaw 插件已删除")
            }
            let codexPath = home.appendingPathComponent(".codex/plugins/finbooks")
            if fm.fileExists(atPath: codexPath.path) {
                try? fm.removeItem(at: codexPath)
                removed = true
                messages.append("✅ Codex 插件已删除")
            }
            let plistPath = home.appendingPathComponent("Library/LaunchAgents/com.finbooks.bridge.plist")
            if fm.fileExists(atPath: plistPath.path) {
                let unloadProcess = Process()
                unloadProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                unloadProcess.arguments = ["unload", plistPath.path]
                try? unloadProcess.run()
                unloadProcess.waitUntilExit()
                try? fm.removeItem(at: plistPath)
                messages.append("✅ 开机自启动已移除")
            }
            if removed {
                installAlertMessage = messages.joined(separator: "\n")
            } else {
                installAlertMessage = "插件尚未安装，无需卸载"
            }
            hermesPluginStatus = .notInstalled
            openclawPluginStatus = .notInstalled
            codexInstalled = .notInstalled
            showInstallAlert = true
            checkPluginDirectories()
        }
    }

    // MARK: - 格式化时间

    private func formattedTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm:ss"
        return f.string(from: date)
    }

    private var installProgressLabel: String {
        switch installProgressStep {
        case .idle: return ""
        case .detecting: return "检测智能体环境..."
        case .startingBridge: return "启动 Bridge 服务..."
        case .inspectingBridge: return "检查 Bridge 连接..."
        case .installingHermes: return "安装 Hermes 插件..."
        case .installingOpenclaw: return "安装 OpenClaw 插件..."
        case .installingCodex: return "安装 Codex 插件..."
        case .done: return "安装完成"
        case .error: return "安装失败"
        }
    }

        var companyContext: (() -> (name: String, summary: String))?

    }


#if DEBUG
struct AIChatWindow_Previews: PreviewProvider {
    static var previews: some View {
        AIChatWindow()
    }
}
#endif


// MARK: - 智能体插件管理面板

struct PluginManagerView: View {

    @Binding var bridgeStatus: AIChatWindow.AgentInstallStatus
    @Binding var hermesStatus: AIChatWindow.AgentInstallStatus
    @Binding var openclawStatus: AIChatWindow.AgentInstallStatus
    @Binding var codexStatus: AIChatWindow.AgentInstallStatus

    var onInstall: () -> Void
    var onUninstall: () -> Void
    var onRefresh: () -> Void
    var onInstallHermes: () -> Void
    var onInstallOpenclaw: () -> Void
    var onInstallCodex: () -> Void
    var onUninstallHermes: () -> Void
    var onUninstallOpenclaw: () -> Void
    var onUninstallCodex: () -> Void

    @State private var bridgeRunning = false
    @Environment(\.dismiss) private var dismiss
    @State private var exportSuccessAlert = false
    @State private var exportAlertMessage = ""
    @State private var downloadAlertMessage = ""
    @State private var downloadSuccessAlert = false

    private let hermesTools: [(String, String)] = [
        ("finbooks_query_balance", "查询科目余额"),
        ("finbooks_list_accounts", "列出所有科目"),
        ("finbooks_list_entries", "查询凭证列表"),
        ("finbooks_get_totals", "核心财务数据"),
        ("finbooks_income_statement", "利润表"),
        ("finbooks_balance_sheet", "资产负债表"),
        ("finbooks_cash_flow", "现金流量表"),
        ("finbooks_vat_report", "增值税申报"),
        ("finbooks_general_ledger", "总分类账"),
        ("finbooks_create_entry", "创建凭证"),
        ("finbooks_create_account", "创建科目"),
        ("finbooks_get_anomalies", "异常检测"),
        ("finbooks_get_audit_logs", "审计日志"),
        ("finbooks_trial_balance", "试算平衡表"),
        ("finbooks_aging_report", "账龄分析"),
        ("finbooks_export_csv", "CSV导出(税务/审计)"),
        ("finbooks_audit_export", "审计数据包导出(外部审计)"),
        ("finbooks_tax_export", "增值税申报导出(税务申报)"),
    ]

    private var openclawTools: [(String, String)] { hermesTools }
    private var codexTools: [(String, String)] { hermesTools }

    private func agentIsPresent(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath:
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".\(name)").path)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("智能体插件管理")
                    .font(.title3).bold()
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top, 16)
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    agentCard(title: "Bridge 服务", icon: "globe", status: bridgeStatus, detail: "HTTP 本地服务 (localhost:9090)\n所有智能体通过 Bridge 调用 FinBooks 数据", toolCount: nil, agentInstalled: true, agentName: nil)
                    agentCard(title: "Codex 插件", icon: "cube.box", status: codexStatus, detail: "Codex 桌面智能体 — MCP 工具集成", toolCount: codexTools.count, agentInstalled: agentIsPresent("codex"), agentName: "codex")
                    agentCard(title: "Hermes 插件", icon: "brain", status: hermesStatus, detail: "Hermes Agent — AI 财务助手工具集", toolCount: hermesTools.count, agentInstalled: agentIsPresent("hermes"), agentName: "hermes")
                    agentCard(title: "OpenClaw 插件", icon: "claw", status: openclawStatus, detail: "OpenClaw Agent — 财务工具集成", toolCount: openclawTools.count, agentInstalled: agentIsPresent("openclaw"), agentName: "openclaw")
                    toolListSection(title: "Hermes 工具列表", tools: hermesTools)
                    toolListSection(title: "OpenClaw 工具列表", tools: openclawTools)
                    toolListSection(title: "Codex 工具列表", tools: codexTools)
                    multiUserInstallSection
                }
                .padding(.horizontal)
            }
            .onAppear { checkBridgeRunning() }
            Divider()
            HStack(spacing: 12) {
                Button(action: onRefresh) { Label("刷新状态", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Button(role: .destructive, action: onUninstall) { Label("卸载全部", systemImage: "minus.circle") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(action: onInstall) { Label("安装全部", systemImage: "gearshape.arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .frame(width: 520, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func agentCard(title: String, icon: String, status: AIChatWindow.AgentInstallStatus, detail: String, toolCount: Int?, agentInstalled: Bool, agentName: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(status.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.headline)
                    Text(status.label).font(.caption).foregroundStyle(status.color).padding(.horizontal, 6).padding(.vertical, 1).background(status.color.opacity(0.1)).cornerRadius(4)
                    if let count = toolCount { Text("\(count) 个工具").font(.caption2).foregroundStyle(.secondary) }
                }
                HStack(spacing: 4) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                    if let name = agentName {
                        if agentInstalled { Text("✓ \(name) 已安装").font(.caption2).foregroundStyle(.green) }
                        else { Text("○ \(name) 未安装").font(.caption2).foregroundStyle(.orange) }
                    }
                }
            }
            Spacer()
            if let name = agentName, agentInstalled {
                if status == .installed {
                    Button {
                        switch name {
                        case "hermes": onUninstallHermes()
                        case "openclaw": onUninstallOpenclaw()
                        case "codex": onUninstallCodex()
                        default: break
                        }
                    } label: { Image(systemName: "minus.circle").foregroundStyle(.red) }
                    .buttonStyle(.plain).help("卸载 \(title)")
                } else {
                    Button {
                        switch name {
                        case "hermes": onInstallHermes()
                        case "openclaw": onInstallOpenclaw()
                        case "codex": onInstallCodex()
                        default: break
                        }
                    } label: { Image(systemName: "plus.circle").foregroundStyle(.green) }
                    .buttonStyle(.plain).help("安装 \(title)")
                }
            }
            Image(systemName: status.icon).foregroundStyle(status.color)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func toolListSection(title: String, tools: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).bold().padding(.top, 4)
            ForEach(tools, id: \.0) { name, desc in
                HStack(spacing: 6) {
                    Image(systemName: "wrench.fill").font(.caption2).foregroundStyle(.secondary)
                    Text(name).font(.caption).bold().foregroundStyle(.primary)
                    Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .padding(.vertical, 1)
            }
        }
    }

    private var multiUserInstallSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("跨机器安装 & 插件导出", systemImage: "square.and.arrow.down.on.square")
                .font(.subheadline).bold()
                .padding(.top, 4)
            HStack(spacing: 10) {
                Image(systemName: "1.circle.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("导出插件包").font(.caption).bold()
                    Text("导出后可分享给其他用户安装").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { exportPluginPackage() } label: { Label("导出插件包", systemImage: "square.and.arrow.up").font(.caption) }
                    .buttonStyle(.borderedProminent).controlSize(.small).help("导出插件包为 .zip 文件")
                if bridgeRunning {
                    Button { downloadPluginFromBridge() } label: { Label("从Bridge下载", systemImage: "arrow.down.circle").font(.caption) }
                        .buttonStyle(.bordered).controlSize(.small).help("从 Bridge 下载插件包")
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor)).cornerRadius(8)
            HStack(spacing: 10) {
                Image(systemName: "2.circle.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("本机安装 — 一键适配本地智能体").font(.caption).bold()
                    Text("自动检测 Hermes / OpenClaw / Codex 并安装 FinBooks 插件 + 启动 Bridge 服务").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { onInstall() } label: { Label("适配本地智能体", systemImage: "arrow.down.to.line.compact").font(.caption) }
                    .buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor)).cornerRadius(8)
            HStack(spacing: 10) {
                Image(systemName: "3.circle.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("终端手动安装（无需打开 FinBooks）").font(.caption).bold()
                    Text("在目标机器终端执行以下命令:").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor)).cornerRadius(8)
            HStack {
                Text("cd ") + Text(finbooksProjectDir().path).fontWeight(.medium).foregroundStyle(.secondary) + Text(" && bash scripts/install_finbooks_plugin.sh").fontWeight(.medium).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            .padding(6).background(Color.black.opacity(0.05)).cornerRadius(4)
            .padding(.leading, 28)
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill").font(.caption2).foregroundStyle(.blue)
                Text("安装完成后重启智能体即可在对话中使用财务工具").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.leading, 28)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor)).cornerRadius(8)
    }

    private func checkBridgeRunning() {
        let savedPort = UserDefaults.standard.integer(forKey: "finbooks_bridge_port")
        let checkPort = savedPort > 0 ? savedPort : 9090
        guard let url = URL(string: "http://127.0.0.1:\(checkPort)/health") else {
            DispatchQueue.main.async { self.bridgeRunning = false }
            return
        }
        let task = URLSession.shared.dataTask(with: url) { _, response, error in
            if error != nil { DispatchQueue.main.async { self.bridgeRunning = false }; return }
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                DispatchQueue.main.async { self.bridgeRunning = true }
            } else {
                DispatchQueue.main.async { self.bridgeRunning = false }
            }
        }
        task.resume()
    }

    private func downloadPluginFromBridge() {
        let savedPort = UserDefaults.standard.integer(forKey: "finbooks_bridge_port")
        let downloadPort = savedPort > 0 ? savedPort : 9090
        guard let url = URL(string: "http://127.0.0.1:\(downloadPort)/api/plugin/download") else {
            downloadAlertMessage = "Bridge 服务未运行，请先启动 Bridge"
            downloadSuccessAlert = true
            return
        }
        let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
            if let error = error {
                DispatchQueue.main.async { downloadAlertMessage = "下载失败: \(error.localizedDescription)"; downloadSuccessAlert = true }
                return
            }
            guard let tempURL = tempURL, let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                DispatchQueue.main.async { downloadAlertMessage = "下载失败: 无效响应"; downloadSuccessAlert = true }
                return
            }
            DispatchQueue.main.async {
                let savePanel = NSSavePanel()
                savePanel.title = "保存 FinBooks 插件包"
                savePanel.message = "从 Bridge 下载插件包到本地"
                savePanel.nameFieldStringValue = "finbooks-plugin-bridge.zip"
                savePanel.allowedContentTypes = [.zip]
                savePanel.begin { result in
                    if result == .OK, let saveURL = savePanel.url {
                        do {
                            let fm = FileManager.default
                            if fm.fileExists(atPath: saveURL.path) { try fm.removeItem(at: saveURL) }
                            try fm.moveItem(at: tempURL, to: saveURL)
                            self.downloadAlertMessage = "插件包已下载到:\n\(saveURL.path)\n\n解压后运行: bash install.sh"
                        } catch {
                            self.downloadAlertMessage = "保存失败: \(error.localizedDescription)"
                        }
                    } else {
                        self.downloadAlertMessage = "已取消下载"
                    }
                    self.downloadSuccessAlert = true
                }
            }
        }
        task.resume()
    }

    private func exportPluginPackage() {
        let fm = FileManager.default
        let projectDir = finbooksProjectDir()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("finbooks-plugin-export-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let pluginDir = tmpDir.appendingPathComponent("finbooks-plugin")
        try? fm.createDirectory(at: pluginDir.appendingPathComponent("hermes"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: pluginDir.appendingPathComponent("openclaw"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: pluginDir.appendingPathComponent("codex"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: pluginDir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        func copyIfExists(src: URL, dst: URL) {
            guard fm.fileExists(atPath: src.path) else { return }
            try? fm.copyItem(at: src, to: dst)
        }
        copyIfExists(src: projectDir.appendingPathComponent(".hermes-plugin/plugin.yaml"), dst: pluginDir.appendingPathComponent("hermes/plugin.yaml"))
        copyIfExists(src: projectDir.appendingPathComponent(".hermes-plugin/__init__.py"), dst: pluginDir.appendingPathComponent("hermes/__init__.py"))
        copyIfExists(src: projectDir.appendingPathComponent(".openclaw-plugin/plugin.yaml"), dst: pluginDir.appendingPathComponent("openclaw/plugin.yaml"))
        copyIfExists(src: projectDir.appendingPathComponent(".openclaw-plugin/__init__.py"), dst: pluginDir.appendingPathComponent("openclaw/__init__.py"))
        copyIfExists(src: projectDir.appendingPathComponent(".codex-plugin/plugin.json"), dst: pluginDir.appendingPathComponent("codex/plugin.json"))
        copyIfExists(src: projectDir.appendingPathComponent(".codex-plugin/SKILL.md"), dst: pluginDir.appendingPathComponent("codex/SKILL.md"))
        copyIfExists(src: projectDir.appendingPathComponent("scripts/finbooks_bridge.py"), dst: pluginDir.appendingPathComponent("scripts/finbooks_bridge.py"))
        copyIfExists(src: projectDir.appendingPathComponent("scripts/install_finbooks_plugin.sh"), dst: pluginDir.appendingPathComponent("install_finbooks_plugin.sh"))

        let installerSh = """
#!/bin/bash
set -euo pipefail
echo "FinBooks Plugin Package — 开箱即用安装器 v2.6.0"
echo ""
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 安装到所有已发现的智能体
declare -A AGENT_ICONS
AGENT_ICONS[hermes]="🔮"
AGENT_ICONS[openclaw]="🦞"
AGENT_ICONS[codex]="📘"

INSTALLED=0
for agent in hermes openclaw codex; do
    if [ -d "$HOME/.$agent" ]; then
        echo "  ${AGENT_ICONS[$agent]} 安装 $agent 插件..."
        mkdir -p "$HOME/.$agent/plugins/finbooks"
        cp -r "$PLUGIN_DIR/$agent/"* "$HOME/.$agent/plugins/finbooks/" 2>/dev/null || true
        echo "     ✅ $agent 插件 -> ~/.$agent/plugins/finbooks/"
        INSTALLED=$((INSTALLED+1))
    else
        echo "  ○ $agent: 未检测到 (跳过)"
    fi
done

# Hermes 专属: 安装 Bridge 脚本
if [ -d "$HOME/.hermes" ]; then
    mkdir -p "$HOME/.hermes/scripts"
    cp "$PLUGIN_DIR/scripts/finbooks_bridge.py" "$HOME/.hermes/scripts/" 2>/dev/null || true
    chmod +x "$HOME/.hermes/scripts/finbooks_bridge.py" 2>/dev/null || true
    echo "     ✅ Bridge 脚本 -> ~/.hermes/scripts/"
fi

# LaunchAgent 开机自启
echo ""
echo "  设置 Bridge 开机自启..."
LPLIST="$HOME/Library/LaunchAgents/com.finbooks.bridge.plist"
mkdir -p "$(dirname "$LPLIST")"
BRIDGE_SCRIPT="$HOME/.hermes/scripts/finbooks_bridge.py"
[ ! -f "$BRIDGE_SCRIPT" ] && BRIDGE_SCRIPT="$PLUGIN_DIR/scripts/finbooks_bridge.py"
cat > "$LPLIST" << EOFPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.finbooks.bridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>${BRIDGE_SCRIPT}</string>
        <string>--port</string>
        <string>9090</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/finbooks-bridge.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/finbooks-bridge.log</string>
</dict>
</plist>
EOFPLIST
chmod 644 "$LPLIST"
launchctl load "$LPLIST" 2>/dev/null && echo "     ✅ Bridge 开机自启已设置" || echo "     ⚠️ 请手动执行: launchctl load $LPLIST"

# 立即启动 Bridge
echo ""
echo "  启动 Bridge 服务..."
if curl -sf http://127.0.0.1:9090/health >/dev/null 2>&1; then
    echo "     ✅ Bridge 已在运行"
else
    nohup python3 "$BRIDGE_SCRIPT" --port 9090 > /tmp/finbooks-bridge.log 2>&1 &
    echo "     🚀 Bridge 已启动 (PID: $!)"
fi

echo ""
echo "✅ 安装完成! 共安装到 $INSTALLED 个智能体"
echo ""
echo "Bridge URL: http://127.0.0.1:9090"
echo "验证: curl http://127.0.0.1:9090/health"
"""
        try? installerSh.write(to: pluginDir.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pluginDir.appendingPathComponent("install.sh").path)

        let readme = """
# FinBooks Plugin Package

AI 财务管理系统插件包

## 安装
```bash
bash install.sh
```
"""
        try? readme.write(to: pluginDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let zipPath = tmpDir.appendingPathComponent("finbooks-plugin.zip")
        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProcess.arguments = ["-r", zipPath.path, "finbooks-plugin"]
        zipProcess.currentDirectoryURL = tmpDir
        do {
            try zipProcess.run()
            zipProcess.waitUntilExit()
        } catch {
            exportAlertMessage = "打包失败: \(error.localizedDescription)"
            exportSuccessAlert = true
            return
        }
        let savePanel = NSSavePanel()
        savePanel.title = "导出 FinBooks 插件包"
        savePanel.message = "选择位置保存插件包，可分享给其他用户安装"
        let pluginVersion = finbooksPluginVersion()
        savePanel.nameFieldStringValue = "finbooks-plugin-v\(pluginVersion).zip"
        savePanel.allowedContentTypes = [.zip]
        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                do {
                    if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                    try fm.copyItem(at: zipPath, to: url)
                    self.exportAlertMessage = "插件包已导出到:\n\(url.path)\n\n解压后运行: bash install.sh"
                } catch {
                    self.exportAlertMessage = "保存失败: \(error.localizedDescription)"
                }
            } else {
                self.exportAlertMessage = "已取消导出"
            }
            self.exportSuccessAlert = true
        }
    }
}

// MARK: - 对话气泡

struct ChatBubble: View {
    let message: AIMessage
    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(message.role == .user ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(10)
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if message.role == .assistant { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 4)
    }
}


