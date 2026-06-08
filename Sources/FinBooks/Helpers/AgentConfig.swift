import Foundation

// MARK: - 智能体配置 — 简化版，开箱即用

/// 预置的智能体模板，用户只需填 API Key
struct AgentPreset: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var provider: String
    var defaultModel: String
    var defaultBaseURL: String
    var apiKeyPlaceholder: String
    var needsAPIKey: Bool

    init(name: String, provider: String, defaultModel: String,
         defaultBaseURL: String, apiKeyPlaceholder: String, needsAPIKey: Bool = true) {
        self.id = UUID()
        self.name = name
        self.provider = provider
        self.defaultModel = defaultModel
        self.defaultBaseURL = defaultBaseURL
        self.apiKeyPlaceholder = apiKeyPlaceholder
        self.needsAPIKey = needsAPIKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static let presets: [AgentPreset] = [
        AgentPreset(name: "DeepSeek V4",
                   provider: "deepseek",
                   defaultModel: "deepseek-chat",
                   defaultBaseURL: "https://api.deepseek.com/v1",
                   apiKeyPlaceholder: "sk-..."),
        AgentPreset(name: "OpenAI GPT-4o",
                   provider: "openai",
                   defaultModel: "gpt-4o",
                   defaultBaseURL: "https://api.openai.com/v1",
                   apiKeyPlaceholder: "sk-..."),
        AgentPreset(name: "Claude Sonnet",
                   provider: "anthropic",
                   defaultModel: "claude-sonnet-4",
                   defaultBaseURL: "https://api.anthropic.com/v1",
                   apiKeyPlaceholder: "sk-ant-..."),
        AgentPreset(name: "OpenRouter (多模型)",
                   provider: "openrouter",
                   defaultModel: "deepseek-ai/deepseek-v4-flash",
                   defaultBaseURL: "https://openrouter.ai/api/v1",
                   apiKeyPlaceholder: "sk-or-..."),
    ]
}

// MARK: - 用户配置的智能体

struct AgentConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var provider: String
    var model: String
    var baseURL: String
    var apiKey: String
    var temperature: Double
    var maxTokens: Int
    var isDefault: Bool

    init(name: String, provider: String, model: String,
         baseURL: String, apiKey: String = "",
         temperature: Double = 0.3, maxTokens: Int = 2048,
         isDefault: Bool = false) {
        self.id = UUID()
        self.name = name
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.isDefault = isDefault
    }

    /// 从预设创建
    init(from preset: AgentPreset, apiKey: String = "") {
        self.id = UUID()
        self.name = preset.name
        self.provider = preset.provider
        self.model = preset.defaultModel
        self.baseURL = preset.defaultBaseURL
        self.apiKey = apiKey
        self.temperature = 0.3
        self.maxTokens = 2048
        self.isDefault = false
    }

    static func == (lhs: AgentConfig, rhs: AgentConfig) -> Bool { lhs.id == rhs.id }
}

// MARK: - 连接模式

enum ConnectionMode: String, Codable {
    /// 通过本地 Hermes Gateway 代理（默认自动检测）
    case localGateway
    /// 直接连 API provider
    case directAPI
}

// MARK: - 配置管理器

@MainActor
final class AgentConfigManager: ObservableObject {
    static let shared = AgentConfigManager()

    @Published var agents: [AgentConfig] = []
    @Published var activeAgentID: UUID?
    @Published var connectionMode: ConnectionMode = .directAPI

    var activeAgent: AgentConfig? {
        guard let id = activeAgentID else { return nil }
        return agents.first { $0.id == id }
    }

    /// 获取最终请求 URL
    var effectiveBaseURL: String {
        activeAgent?.baseURL ?? ""
    }

    /// 获取最终 API Key
    var effectiveAPIKey: String {
        activeAgent?.apiKey ?? ""
    }

    private let agentsKey = "finbooks_agent_configs"
    private let modeKey = "finbooks_connection_mode"
    private let activeKey = "finbooks_active_agent"

    private init() {
        load()
        if agents.isEmpty {
            createDefaults()
        } else {
            // 已有保存的智能体：补上 Hermes 配置里的 API Key
            fillHermesAPIKeys()
        }
        if activeAgentID == nil, let first = agents.first {
            activeAgentID = first.id
        }
    }

    /// 给所有 DeepSeek provider 且 apiKey 为空的智能体填上 Hermes 配置里的 Key
    private func fillHermesAPIKeys() {
        let hermesKey = Self.readHermesAPIKey()
        guard !hermesKey.isEmpty else { return }

        var changed = false
        for i in agents.indices {
            if agents[i].provider == "deepseek" && agents[i].apiKey.isEmpty {
                agents[i].apiKey = hermesKey
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    private func createDefaults() {
        let hermesKey = Self.readHermesAPIKey()
        agents = [
            AgentConfig(name: "DeepSeek V4 (快速)",
                       provider: "deepseek",
                       model: "deepseek-chat",
                       baseURL: "https://api.deepseek.com/v1",
                       apiKey: hermesKey,
                       temperature: 0.3,
                       maxTokens: 2048,
                       isDefault: true),
            AgentConfig(name: "DeepSeek V4 (精准)",
                       provider: "deepseek",
                       model: "deepseek-chat",
                       baseURL: "https://api.deepseek.com/v1",
                       apiKey: hermesKey,
                       temperature: 0.1,
                       maxTokens: 4096),
        ]
        activeAgentID = agents.first?.id
        connectionMode = .directAPI
        save()
    }

    /// 从 Hermes config.yaml 读取 DeepSeek API Key
    private static func readHermesAPIKey() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configPath = home.appendingPathComponent(".hermes/config.yaml")
        guard let content = try? String(contentsOf: configPath, encoding: .utf8) else { return "" }

        var inDeepseekSection = false
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("deepseek-official:") {
                inDeepseekSection = true
                continue
            }
            if inDeepseekSection {
                if trimmed.hasPrefix("api_key:") {
                    let key = trimmed.replacingOccurrences(of: "api_key:", with: "").trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { return key }
                }
                if !trimmed.isEmpty && !trimmed.hasPrefix(" ") && !trimmed.hasPrefix("\t") && trimmed != "deepseek-official:" {
                    inDeepseekSection = false
                }
            }
        }
        return ""
    }

    /// 从预设创建新智能体
    func addFromPreset(_ preset: AgentPreset, apiKey: String) {
        var cfg = AgentConfig(from: preset, apiKey: apiKey)
        cfg.name = preset.name
        agents.append(cfg)
        if activeAgentID == nil { activeAgentID = cfg.id }
        save()
    }

    func addAgent(_ agent: AgentConfig) {
        agents.append(agent)
        if activeAgentID == nil { activeAgentID = agent.id }
        save()
    }

    func updateAgent(_ agent: AgentConfig) {
        guard let idx = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[idx] = agent
        save()
    }

    func deleteAgent(_ agent: AgentConfig) {
        agents.removeAll { $0.id == agent.id }
        if activeAgentID == agent.id {
            activeAgentID = agents.first?.id
        }
        save()
    }

    func setActive(_ agent: AgentConfig) {
        activeAgentID = agent.id
        save()
    }

    func setConnectionMode(_ mode: ConnectionMode) {
        connectionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(agents) {
            UserDefaults.standard.set(data, forKey: agentsKey)
        }
        if let id = activeAgentID {
            UserDefaults.standard.set(id.uuidString, forKey: activeKey)
        }
        UserDefaults.standard.set(connectionMode.rawValue, forKey: modeKey)
    }

    private func load() {
        if let modeRaw = UserDefaults.standard.string(forKey: modeKey),
           let mode = ConnectionMode(rawValue: modeRaw) {
            connectionMode = mode
        }

        if let data = UserDefaults.standard.data(forKey: agentsKey),
           let decoded = try? JSONDecoder().decode([AgentConfig].self, from: data) {
            agents = decoded
        }

        if let idStr = UserDefaults.standard.string(forKey: activeKey),
           let id = UUID(uuidString: idStr),
           agents.contains(where: { $0.id == id }) {
            activeAgentID = id
        } else if let defaultAgent = agents.first(where: { $0.isDefault }) {
            activeAgentID = defaultAgent.id
        }
    }
}