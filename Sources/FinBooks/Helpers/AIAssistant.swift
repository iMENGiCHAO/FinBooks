import Foundation
import SwiftUI

// MARK: - FinBooks AI 助手 v2 — SSE 流式客户端 + 丰富上下文

@MainActor
final class AIAssistant: ObservableObject {
    static let shared = AIAssistant()

    @Published var messages: [AIMessage] = []
    @Published var isThinking = false
    @Published var streamText = ""
    @Published var errorMessage: String?

    private var currentTask: Task<Void, Never>?
    private var bridgeURL: URL {
        // 支持从环境变量/UserDefaults 覆盖端口
        let savedPort = UserDefaults.standard.integer(forKey: "finbooks_bridge_port")
        let port = savedPort > 0 ? savedPort : 9090
        return URL(string: "http://127.0.0.1:\(port)/chat")!
    }
    private var healthURL: URL {
        let savedPort = UserDefaults.standard.integer(forKey: "finbooks_bridge_port")
        let port = savedPort > 0 ? savedPort : 9090
        return URL(string: "http://127.0.0.1:\(port)/health")!
    }
    private var sessionId: String = ""

    private init() {
        // 从 UserDefaults 恢复 sessionId（跨启动保持会话）
        sessionId = UserDefaults.standard.string(forKey: "finbooks.ai.sessionId") ?? UUID().uuidString
        UserDefaults.standard.set(sessionId, forKey: "finbooks.ai.sessionId")
        loadWelcome()
    }

    private func loadWelcome() {
        messages.append(AIMessage(
            role: .assistant,
            content: "👋 你好！我是 FinBooks AI 助手 v2（Hermes 驱动）。\n\n我可以：\n📊 **查询分析** — 问余额、查凭证、三大报表、总分类账、试算平衡\n📝 **凭证管理** — 描述业务自动生成分录，检查借贷平衡\n🧾 **税务申报** — 增值税申报、所得税预估、税局格式CSV导出\n🔒 **期末结账** — 智能期间检查、损益自动结转、反结账\n🔍 **异常检测** — 借贷不平、方向异常、大额交易、重复凭证\n📋 **审计合规** — 审计日志追踪、试算平衡表、账龄分析\n📤 **数据导出** — 审计CSV / 税局CSV 双格式导出\n\n💡 试试说：\n  • \"帮我执行期末结账\"\n  • \"导出本月增值税申报CSV\"\n  • \"检查财务异常\"\n  • \"本月利润多少？\""
        ))
    }

    func refreshWelcome() {
        if messages.count == 1, messages.first?.role == .assistant {
            messages.removeAll()
        }
        loadWelcome()
    }

    /// 生成新的 sessionId（切换公司时调用）
    func resetSession() {
        sessionId = UUID().uuidString
        UserDefaults.standard.set(sessionId, forKey: "finbooks.ai.sessionId")
        // 通知 Bridge 清除旧会话
        Task {
            await clearRemoteSession()
        }
    }

    private func clearRemoteSession() async {
        guard let url = URL(string: "http://localhost:9090/api/session/clear") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(sessionId, forHTTPHeaderField: "X-Session-Id")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// 发送消息 — 带完整财务上下文
    func send(_ text: String, company: Company? = nil, contextData: [String: Any]? = nil) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        currentTask?.cancel()

        let userMsg = AIMessage(role: .user, content: text)
        messages.append(userMsg)
        isThinking = true
        errorMessage = nil
        streamText = ""
        receivedContent = ""

        // 构建丰富的上下文
        var bodyDict: [String: Any] = [
            "message": text,
            "sessionId": sessionId,
        ]

        if let company = company {
            bodyDict["context"] = buildRichContext(company: company, extra: contextData)
        } else if let ctx = contextData {
            bodyDict["context"] = ctx
        }

        // 始终注入 Agent 配置（API Key / Model / BaseURL）
        let agentApiKey = AgentConfigManager.shared.effectiveAPIKey
        let agentModel = AgentConfigManager.shared.activeAgent?.model ?? "deepseek-chat"
        let agentBaseURL = AgentConfigManager.shared.effectiveBaseURL
        if var ctx = bodyDict["context"] as? [String: Any] {
            ctx["apiKey"] = agentApiKey
            ctx["model"] = agentModel
            ctx["baseURL"] = agentBaseURL
            bodyDict["context"] = ctx
        } else {
            bodyDict["context"] = ["apiKey": agentApiKey, "model": agentModel, "baseURL": agentBaseURL]
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            errorMessage = "内部错误"
            isThinking = false
            return
        }

        var request = URLRequest(url: bridgeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionId, forHTTPHeaderField: "X-Session-Id")
        request.httpBody = jsonData
        request.timeoutInterval = 300

        currentTask = Task {
            await doStream(request: request)
        }
    }

    // MARK: - 构建丰富上下文

    private func buildRichContext(company: Company, extra: [String: Any]? = nil) -> [String: Any] {
        var ctx: [String: Any] = [
            "companyName": company.name,
            "companyId": company.id.uuidString,
            "taxId": company.taxId,
            "currency": company.currency,
        ]

        // 注入完整财务摘要
        ctx["summary"] = buildFullFinancialSummary(company: company)

        // 合并额外上下文
        if let extra = extra {
            for (k, v) in extra { ctx[k] = v }
        }

        return ctx
    }

    /// 构建完整财务摘要（比之前丰富 10 倍的信息量）
    private func buildFullFinancialSummary(company: Company) -> String {
        let accounts = DataStore.shared.accounts(for: company.id).filter(\.isActive)
        let entries = DataStore.shared.entries(for: company.id)
        let postedEntries = entries.filter(\.isPosted)

        // 汇总各类科目
        let assetAccounts = accounts.filter { $0.category == .asset }
        let liabilityAccounts = accounts.filter { $0.category == .liability }
        let equityAccounts = accounts.filter { $0.category == .equity }
        let revenueAccounts = accounts.filter { $0.category == .revenue }
        let expenseAccounts = accounts.filter { $0.category == .expense }

        let totalAssets = assetAccounts.reduce(Decimal.zero) { $0 + AccountingEngine.balance(for: $1) }
        let totalLiabilities = liabilityAccounts.reduce(Decimal.zero) { $0 + AccountingEngine.balance(for: $1) }
        let totalEquity = equityAccounts.reduce(Decimal.zero) { $0 + AccountingEngine.balance(for: $1) }
        let totalRevenue = revenueAccounts.reduce(Decimal.zero) { $0 + AccountingEngine.balance(for: $1) }
        let totalExpense = expenseAccounts.reduce(Decimal.zero) { $0 + AccountingEngine.balance(for: $1) }

        // 关键科目余额
        let keyAccounts: [(String, String)] = [
            ("1001", "库存现金"), ("1002", "银行存款"), ("1122", "应收账款"),
            ("1601", "固定资产"), ("1602", "累计折旧"),
            ("2001", "短期借款"), ("2202", "应付账款"), ("2221", "应交税费"),
            ("4001", "实收资本"), ("4103", "本年利润"),
            ("5001", "主营业务收入"), ("6001", "主营业务成本"),
            ("6601", "销售费用"), ("6602", "管理费用"), ("6603", "财务费用"),
        ]
        var keyBals: [String] = []
        for (code, name) in keyAccounts {
            if let acct = accounts.first(where: { $0.code == code }) {
                let bal = AccountingEngine.balance(for: acct)
                keyBals.append("\(code) \(name): ¥\(FMT.amount(bal))")
            }
        }

        // 近期凭证
        let recent = postedEntries.sorted { ($0.date) > ($1.date) }.prefix(10)
        var recentLines: [String] = []
        for e in recent {
            let dateStr = e.date.formatted(.iso8601.dateSeparator(.dash))
            recentLines.append("[\(dateStr)] \(e.number) \(e.summary) 借¥\(FMT.amount(e.debitTotal)) 贷¥\(FMT.amount(e.creditTotal))")
        }

        return """
        公司: \(company.name) | 税号: \(company.taxId) | 本位币: \(company.currency)
        科目总数: \(accounts.count) | 凭证: \(entries.count) 张 (已过账 \(postedEntries.count))

        【资产负债表摘要】
        总资产: ¥\(FMT.amount(totalAssets))
        总负债: ¥\(FMT.amount(totalLiabilities))
        所有者权益: ¥\(FMT.amount(totalEquity))
        平衡: \(totalAssets == totalLiabilities + totalEquity ? "✓" : "✗ 不平!")

        【利润表摘要】
        收入合计: ¥\(FMT.amount(totalRevenue))
        费用合计: ¥\(FMT.amount(totalExpense))
        净利润: ¥\(FMT.amount(totalRevenue - totalExpense))

        【关键科目余额】
        \(keyBals.joined(separator: "\n"))

        【近期凭证 (最近10笔)】
        \(recentLines.joined(separator: "\n"))
        """
    }

    // MARK: - SSE 流处理

    private var receivedContent = ""

    private func doStream(request: URLRequest) async {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                handleError("无法连接 Hermes Bridge")
                return
            }

            guard httpResponse.statusCode == 200 else {
                handleError("Hermes Bridge 返回错误 (HTTP \(httpResponse.statusCode))")
                return
            }

            for try await line in bytes.lines {
                if Task.isCancelled { return }

                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data: ") else { continue }

                let payload = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty else { continue }

                if payload == "[DONE]" {
                    finishStream()
                    return
                }

                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                if let content = json["content"] as? String {
                    appendContent(content)
                } else if let error = json["error"] as? String {
                    handleError(error)
                    return
                }

                // Bridge v2 会返回 sessionId（用于后续对话）
                if let sid = json["sessionId"] as? String, !sid.isEmpty {
                    sessionId = sid
                    UserDefaults.standard.set(sid, forKey: "finbooks.ai.sessionId")
                }
            }

            if !Task.isCancelled {
                finishStream()
            }
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain {
                switch nsErr.code {
                case NSURLErrorCannotConnectToHost:
                    handleError("⚠️ 无法连接 Hermes Bridge。\n请先启动: python3 ~/.hermes/scripts/finbooks_bridge.py")
                case NSURLErrorTimedOut:
                    handleError("⚠️ Hermes 响应超时，请重试。")
                case NSURLErrorNotConnectedToInternet:
                    handleError("⚠️ 网络未连接。")
                case NSURLErrorCancelled:
                    return
                default:
                    handleError("⚠️ 连接错误：\(error.localizedDescription)")
                }
            } else {
                handleError("⚠️ 请求失败：\(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func appendContent(_ content: String) {
        receivedContent += content
        streamText = receivedContent
    }

    @MainActor
    private func finishStream() {
        isThinking = false
        streamText = ""
        if !receivedContent.isEmpty {
            addAssistantMessage(receivedContent)
        } else {
            addAssistantMessage("🤔 Hermes 没有返回内容。请确认 Hermes 模型配置正确。")
        }
        receivedContent = ""
    }

    @MainActor
    private func handleError(_ message: String) {
        isThinking = false
        streamText = ""
        receivedContent = ""
        addAssistantMessage(message)
    }

    private func addAssistantMessage(_ content: String) {
        messages.append(AIMessage(role: .assistant, content: content))
    }

    func clearMessages() {
        currentTask?.cancel()
        currentTask = nil
        messages.removeAll()
        streamText = ""
        errorMessage = ""
        receivedContent = ""
        loadWelcome()
    }

    func cancelRequest() {
        currentTask?.cancel()
        currentTask = nil
        isThinking = false
        streamText = ""

        receivedContent = ""
    }
}

// MARK: - 导出工具 (Bridge 调用)
@MainActor
extension AIAssistant {

    /// 导出审计数据包（调用 Bridge /api/audit/export）
    func auditExport(year: Int, month: Int, format: String = "json") async -> String {
        let port = UserDefaults.standard.integer(forKey: "finbooks_bridge_port")
        let bridgePort = port > 0 ? port : 9090
        guard let url = URL(string: "http://127.0.0.1:\(bridgePort)/api/audit/export") else {
            return "Error: invalid Bridge URL"
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["year": year, "month": month, "format": format]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 else {
                return "Error: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let file = json["file"] as? String {
                    return "✅ 审计数据包已导出: \(file)\n共 \(json["rows"] ?? 0) 行记录"
                }
                if let message = json["message"] as? String {
                    return message
                }
                // JSON 格式返回
                if let trialBalance = json["trialBalance"] as? [[String: Any]] {
                    return "✅ 审计数据就绪 (\(trialBalance.count) 个科目)\n请通过 FinBooks App 导出 CSV 文件"
                }
            }
            return String(data: data, encoding: .utf8) ?? "导出完成"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    /// 导出税务申报数据（调用 Bridge /api/tax/export）
    func taxExport(year: Int, month: Int, format: String = "json") async -> String {
        let port = UserDefaults.standard.integer(forKey: "finbooks_bridge_port")
        let bridgePort = port > 0 ? port : 9090
        guard let url = URL(string: "http://127.0.0.1:\(bridgePort)/api/tax/export") else {
            return "Error: invalid Bridge URL"
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["year": year, "month": month, "format": format]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 else {
                return "Error: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let file = json["file"] as? String {
                    return "✅ 税务申报数据已导出到: \(file)"
                }
                if let message = json["message"] as? String {
                    return message
                }
                if let output = json["output"] as? String {
                    return output
                }
            }
            return String(data: data, encoding: .utf8) ?? "税务导出完成"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    /// 获取试算平衡表（本地计算）
    func getTrialBalance(year: Int, month: Int) -> String {
        let results = AccountingEngine.trialBalance(year: year, month: month)
        guard !results.isEmpty else { return "暂无科目数据" }

        var lines: [String] = ["📊 **试算平衡表** (\(year)年\(month)月)", "", "| 科目编码 | 科目名称 | 借方期末余额 | 贷方期末余额 |"]
        lines.append("|---|---|---|---|")
        var totalDebit: Decimal = 0
        var totalCredit: Decimal = 0
        for (account, debit, credit) in results {
            let fmtDebit = FMT.amount(debit)
            let fmtCredit = FMT.amount(credit)
            lines.append("| \(account.code) | \(account.name) | ¥\(fmtDebit) | ¥\(fmtCredit) |")
            totalDebit += debit
            totalCredit += credit
        }
        lines.append("")
        lines.append("**合计** | 借方: ¥\(FMT.amount(totalDebit)) | 贷方: ¥\(FMT.amount(totalCredit))")
        let balanced = abs(totalDebit - totalCredit) < 0.01
        lines.append(balanced ? "✅ **试算平衡!**" : "⚠️ **试算不平!** 差额: ¥\(FMT.amount(abs(totalDebit - totalCredit)))")
        return lines.joined(separator: "\n")
    }

    /// 获取账龄分析报告（本地计算）
    func getAgingReport(type: String, asOf date: Date = Date()) -> String {
        let agingType: AccountingEngine.AgingType = type == "payable" ? .payable : .receivable
        let label = type == "payable" ? "应付账款" : "应收账款"
        let results = AccountingEngine.agingReport(type: agingType, asOf: date)

        guard !results.isEmpty, results.contains(where: { $0.amount > 0 }) else {
            return "📋 **\(label)账龄分析**\n\n当前没有未结清的\(label)。"
        }

        var lines: [String] = ["📋 **\(label)账龄分析**", ""]
        let dateStr = date.formatted(.iso8601.dateSeparator(.dash))
        lines.append("截至日期: \(dateStr)")
        lines.append("")
        lines.append("| 账龄区间 | 金额 | 占比 |")
        lines.append("|---|---|---|")
        for r in results {
            lines.append("| \(r.period) | ¥\(FMT.amount(r.amount)) | \(String(format: "%.1f", r.percentage))% |")
        }
        return lines.joined(separator: "\n")
    }
}

