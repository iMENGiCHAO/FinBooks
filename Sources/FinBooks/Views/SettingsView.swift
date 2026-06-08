import SwiftUI

// MARK: - FinBooks 设置面板

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var apiKeySaved = false
    @State private var bridgePort = "9090"
    @State private var showBackupAlert = false
    @State private var backupMessage = ""
    @State private var showRestoreAlert = false
    @State private var restoreMessage = ""
    @State private var lastBackupDate = ""
    @State private var backupCount = 0
    @State private var recoveryMode = false
    @State private var recoveryPath = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("FinBooks 设置")
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
            
            Divider().padding(.vertical, 8)
            
            ScrollView {
                VStack(spacing: 16) {
                    // AI API Key 配置
                    apiKeySection
                    
                    // Bridge 配置
                    bridgeSettingsSection
                    
                    // 数据备份与恢复
                    backupSection
                    
                    // 恢复模式
                    recoverySection
                    
                    // 关于
                    aboutSection
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
            
            Divider().padding(.vertical, 8)
            
            HStack {
                Text("v\(bridgeVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 480, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadSettings()
        }
        .alert("操作结果", isPresented: $showBackupAlert) {
            Button("确定") { }
        } message: {
            Text(backupMessage)
        }
        .alert("数据恢复", isPresented: $showRestoreAlert) {
            Button("取消", role: .cancel) { }
            Button("确定恢复", role: .destructive) {
                performRestore()
            }
        } message: {
            Text(restoreMessage)
        }
    }
    
    private var bridgeVersion: String {
        // 尝试从 Bridge 获取版本
        "2.4.1"
    }
    
    // MARK: - API Key 配置
    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI API 密钥配置", systemImage: "key.fill")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("配置后 AI 助手将使用在线大模型（支持 DeepSeek / OpenAI 兼容 API）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("未配置时自动使用离线模式（内置基础财务回复）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            SecureField("API Key (DeepSeek / OpenAI 兼容)", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            
            HStack {
                Text("配置将保存在 ~/.finbooks/config.json")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if apiKeySaved {
                    Text("✅ 已保存")
                        .font(.caption).foregroundStyle(.green)
                }
                Button(apiKey.isEmpty ? "从剪贴板粘贴" : "保存密钥") {
                    if apiKey.isEmpty {
                        if let pb = NSPasteboard.general.string(forType: .string) {
                            apiKey = pb
                        }
                    } else {
                        saveApiKey()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(apiKey.isEmpty && apiKeySaved)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - Bridge 设置
    private var bridgeSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Bridge 服务配置", systemImage: "globe")
                .font(.headline)
            
            HStack {
                Text("端口:")
                    .font(.caption)
                TextField("9090", text: $bridgePort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .font(.body.monospaced())
                Spacer()
                Button("保存端口") {
                    if let port = Int(bridgePort), port > 0, port < 65536 {
                        UserDefaults.standard.set(port, forKey: "finbooks_bridge_port")
                        // 重启 Bridge 服务
                        BridgeManager.shared.stop()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            BridgeManager.shared.start()
                        }
                        backupMessage = "Bridge 端口已更新为 \(port)，服务已重启"
                        showBackupAlert = true
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            Text("更改端口后需要重启 Bridge 服务生效")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - 备份与恢复
    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("数据备份与恢复", systemImage: "externaldrive.badge.timemachine")
                .font(.headline)
            
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动备份: 每天一次")
                        .font(.caption)
                    Text(lastBackupDate.isEmpty ? "暂无备份" : "上次备份: \(lastBackupDate)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(backupCount > 0 ? "可用备份: \(backupCount) 个" : "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    performBackup()
                } label: {
                    Label("立即备份", systemImage: "arrow.up.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                
                Button {
                    selectAndRestoreBackup()
                } label: {
                    Label("恢复", systemImage: "arrow.down.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - 恢复模式
    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("应急恢复模式", systemImage: "wrench.adjustable.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            
            if recoveryMode {
                HStack {
                    Text("恢复路径:")
                        .font(.caption)
                    TextField("备份文件(.zip)或目录路径", text: $recoveryPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    Button("选择...") {
                        let panel = NSOpenPanel()
                        panel.title = "选择备份文件"
                        panel.allowedContentTypes = [.zip, .archive]
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.begin { result in
                            if result == .OK, let url = panel.url {
                                recoveryPath = url.path
                                restoreMessage = "将从以下备份恢复数据:\n\(url.lastPathComponent)\n\n⚠️ 当前数据将被覆盖，不可撤销！"
                                showRestoreAlert = true
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.05))
                .cornerRadius(6)
            } else {
                HStack {
                    Text("数据损坏或 Bridge 无法启动时，从备份 ZIP 恢复")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("进入恢复模式") {
                        recoveryMode = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.orange)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - 关于
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("关于 FinBooks", systemImage: "info.circle")
                .font(.headline)
            Text("FinBooks AI 智能财务管理 | 会计凭证 · 三大报表 · 增值税申报 · 固定资产 · 银行对账")
                .font(.caption).foregroundStyle(.secondary)
            Text("支持 Hermes / OpenClaw / Codex 智能体联动 | 数据本地存储，保护隐私")
                .font(.caption2).foregroundStyle(.secondary)
            Text("数据目录: ~/Library/Application Support/com.finbooks.app/")
                .font(.caption2).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - 操作实现
    
    private func loadSettings() {
        // 从 UserDefaults 读取已保存的 API Key
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "finbooks_ai_api_key") {
            apiKey = saved
            apiKeySaved = !saved.isEmpty
        }
        bridgePort = String(defaults.integer(forKey: "finbooks_bridge_port").nonzero ?? 9090)
        
        // 检查备份状态
        checkBackupStatus()
    }
    
    private func saveApiKey() {
        guard !apiKey.isEmpty else { return }
        // 保存到 UserDefaults（给 Bridge 读取）
        UserDefaults.standard.set(apiKey, forKey: "finbooks_ai_api_key")
        apiKeySaved = true
        
        // 也写入 ~/.finbooks/config.json
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configDir = home.appendingPathComponent(".finbooks")
        let configPath = configDir.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        
        var config: [String: Any] = [:]
        if let existing = try? Data(contentsOf: configPath),
           let existingConfig = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            config = existingConfig
        }
        config["api_key"] = apiKey
        config["model"] = config["model"] ?? "deepseek-chat"
        config["base_url"] = config["base_url"] ?? "https://api.deepseek.com/v1"
        
        if let data = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted) {
            try? data.write(to: configPath)
        }
        
        backupMessage = "API Key 已保存。重新打开 AI 助手或重启 Bridge 后生效。"
        showBackupAlert = true
    }
    
    private func checkBackupStatus() {
        let backupDir = getBackupDir()
        guard let items = try? FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [URLResourceKey.creationDateKey]) else {
            return
        }
        let backups = items.filter { $0.pathExtension == "zip" || $0.lastPathComponent.hasSuffix(".zip") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [URLResourceKey.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [URLResourceKey.creationDateKey]).creationDate) ?? .distantPast
                return da > db
            }
        backupCount = backups.count
        if let newest = backups.first,
           let date = try? newest.resourceValues(forKeys: [URLResourceKey.creationDateKey]).creationDate {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm"
            lastBackupDate = fmt.string(from: date)
        }
    }
    
    private func getBackupDir() -> URL {
        let dataDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.finbooks.app")
        let backupDir = dataDir.appendingPathComponent("backups")
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        return backupDir
    }
    
    private func performBackup() {
        let backupDir = getBackupDir()
        let dataDir = backupDir.deletingLastPathComponent()
        let ts = DateFormatter()
        ts.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = ts.string(from: Date())
        let archivePath = backupDir.appendingPathComponent("finbooks_manual_backup_\(stamp).zip")
        
        let fm = FileManager.default
        guard let jsonFiles = try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }) else {
            backupMessage = "❌ 未找到数据文件"
            showBackupAlert = true
            return
        }
        
        // 使用 Python 的 zipfile 或系统 zip
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-j", archivePath.path] + jsonFiles.map { $0.path }
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                backupMessage = "✅ 备份成功!\n\(jsonFiles.count) 个数据文件已备份到:\n\(archivePath.path)"
                checkBackupStatus()
            } else {
                backupMessage = "❌ 备份失败 (exit code \(process.terminationStatus))"
            }
        } catch {
            backupMessage = "❌ 备份失败: \(error.localizedDescription)"
        }
        showBackupAlert = true
    }
    
    private func selectAndRestoreBackup() {
        let panel = NSOpenPanel()
        panel.title = "选择备份文件恢复"
        panel.message = "选择一个 FinBooks 备份 ZIP 文件恢复数据"
        panel.allowedContentTypes = [.zip, .archive]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { result in
            if result == .OK, let url = panel.url {
                restoreMessage = """
                将从以下备份恢复全部数据:
                \(url.lastPathComponent)
                
                ⚠️ 当前所有数据将被覆盖！
                此操作不可撤销。
                
                建议先手动备份当前数据。
                """
                recoveryPath = url.path
                showRestoreAlert = true
            }
        }
    }
    
    private func performRestore() {
        guard !recoveryPath.isEmpty else {
            restoreMessage = "未选择备份文件"
            showRestoreAlert = true
            return
        }
        
        let dataDir = getBackupDir().deletingLastPathComponent()
        let backupURL = URL(fileURLWithPath: recoveryPath)
        
        // 先备份当前数据
        let ts = DateFormatter()
        ts.dateFormat = "yyyyMMdd_HHmmss"
        let preBackupName = "pre_restore_backup_\(ts.string(from: Date())).zip"
        let preBackupPath = getBackupDir().appendingPathComponent(preBackupName)
        
        let fm = FileManager.default
        guard let jsonFiles = try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }) else {
            backupMessage = "❌ 无法读取数据目录"
            showBackupAlert = true
            return
        }
        
        // Pre-restore backup
        let preProc = Process()
        preProc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        preProc.arguments = ["-j", preBackupPath.path] + jsonFiles.map { $0.path }
        try? preProc.run()
        preProc.waitUntilExit()
        
        // 解压恢复
        let unzipProc = Process()
        unzipProc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzipProc.arguments = ["-o", backupURL.path, "-d", dataDir.path]
        do {
            try unzipProc.run()
            unzipProc.waitUntilExit()
            if unzipProc.terminationStatus == 0 {
                // 强制重载数据
                DataStore.shared.refreshFromDisk()
                backupMessage = "✅ 数据已恢复！\n原数据已备份到: \(preBackupPath.path)"
            } else {
                backupMessage = "❌ 恢复失败 (exit code \(unzipProc.terminationStatus))"
            }
        } catch {
            backupMessage = "❌ 恢复失败: \(error.localizedDescription)"
        }
        showBackupAlert = true
        recoveryMode = false
        recoveryPath = ""
        checkBackupStatus()
    }
}

// MARK: - Int 扩展
extension Int {
    var nonzero: Int? { self == 0 ? nil : self }
}
