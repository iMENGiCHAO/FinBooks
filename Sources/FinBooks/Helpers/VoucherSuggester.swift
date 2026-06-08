import Foundation
import SwiftUI

// MARK: - 智能凭证推荐引擎

@MainActor
final class VoucherSuggester: ObservableObject {
    static let shared = VoucherSuggester()
    
    @Published var suggestions: [VoucherSuggestion] = []
    @Published var isSuggesting = false
    @Published var errorMessage: String?
    
    private var gatewayURL: URL? {
        URL(string: AgentConfigManager.shared.effectiveBaseURL)
    }
    
    private init() {}
    
    /// 根据摘要和可用科目，AI 推荐分录
    func suggest(for summary: String, accounts: [Account], companyName: String) {
        guard !summary.trimmingCharacters(in: .whitespaces).isEmpty else {
            suggestions = []
            return
        }
        
        isSuggesting = true
        errorMessage = nil
        suggestions = []
        
        let accountsJSON = accounts.map { a in
            "  {\"code\": \"\(a.code)\", \"name\": \"\(a.name)\", \"category\": \"\(a.category.rawValue)\"}"
        }.joined(separator: ",\n")
        
        let prompt = """
        你是一个会计专家。请根据用户输入的摘要和可用科目表，推荐最合适的会计分录。
        
        公司: \(companyName)
        
        可用科目:
        [
        \(accountsJSON)
        ]
        
        用户输入: 「\(summary)」
        
        请返回 JSON 格式的分录推荐，格式如下（不要有任何额外文字）：
        [
          {"accountCode": "1002", "debit": 0, "credit": 5000, "lineSummary": "支付房租"},
          {"accountCode": "6602", "debit": 5000, "credit": 0, "lineSummary": "办公室房租"}
        ]
        
        要求：
        - 借方合计 == 贷方合计
        - 只使用上面提供的科目编码
        - 金额只填数字（单位为元）
        - 最少两行（一借一贷）
        - 如果无法判断，返回空数组 []
        """
        
        let body: [String: Any] = [
            "model": AgentConfigManager.shared.activeAgent?.model ?? "deepseek-ai/deepseek-v4-flash",
            "messages": [
                ["role": "system", "content": "你是一个会计知识丰富的财务专家，精通中国企业会计准则。"],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 1024,
            "temperature": 0.1
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let url = gatewayURL else {
            isSuggesting = false
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !AgentConfigManager.shared.effectiveAPIKey.isEmpty {
            request.setValue("Bearer \(AgentConfigManager.shared.effectiveAPIKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = jsonData
        request.timeoutInterval = 30
        
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let dataStr = String(data: data, encoding: .utf8) else {
                    self.isSuggesting = false
                    return
                }
                
                // 从 SSE 响应中提取 content
                var fullContent = ""
                let lines = dataStr.components(separatedBy: "\n")
                for line in lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let jsonStr = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    guard !jsonStr.isEmpty, jsonStr != "[DONE]" else { continue }
                    guard let jsonData = jsonStr.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let delta = choices.first?["delta"] as? [String: Any],
                          let content = delta["content"] as? String else { continue }
                    fullContent += content
                }
                
                // 解析 JSON
                await MainActor.run {
                    self.parseAndSetSuggestions(fullContent, accounts: accounts)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isSuggesting = false
                }
            }
        }
    }
    
    private func parseAndSetSuggestions(_ content: String, accounts: [Account]) {
        // 尝试提取 JSON 数组
        guard let jsonData = extractJSON(from: content)?.data(using: .utf8) else {
            isSuggesting = false
            return
        }
        
        guard let items = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
            isSuggesting = false
            return
        }
        
        var result: [VoucherSuggestion] = []
        for item in items {
            guard let code = item["accountCode"] as? String,
                  let debit = item["debit"] as? Double,
                  let credit = item["credit"] as? Double,
                  let summary = item["lineSummary"] as? String,
                  let account = accounts.first(where: { $0.code == code }) else { continue }
            
            result.append(VoucherSuggestion(
                accountID: account.id,
                accountCode: account.code,
                accountName: account.name,
                debit: Decimal(debit),
                credit: Decimal(credit),
                lineSummary: summary
            ))
        }
        
        // 校验借贷平衡
        let totalDebit = result.reduce(Decimal.zero) { $0 + $1.debit }
        let totalCredit = result.reduce(Decimal.zero) { $0 + $1.credit }
        
        if totalDebit == totalCredit && totalDebit > 0 {
            suggestions = result
        }
        
        isSuggesting = false
    }
    
    private func extractJSON(from text: String) -> String? {
        // 找到第一个 [ 和最后一个 ]
        guard let startIdx = text.firstIndex(of: "["),
              let endIdx = text.lastIndex(of: "]") else { return nil }
        return String(text[startIdx...endIdx])
    }
    
    func clear() {
        suggestions = []
        errorMessage = nil
    }
}

// MARK: - 推荐模型
struct VoucherSuggestion: Identifiable {
    let id = UUID()
    let accountID: UUID
    let accountCode: String
    let accountName: String
    let debit: Decimal
    let credit: Decimal
    let lineSummary: String
}

// MARK: - 智能推荐 UI 组件

struct SmartSuggestionBar: View {
    let suggestions: [VoucherSuggestion]
    let onApply: ([VoucherSuggestion]) -> Void
    @State private var showDetail = false
    
    var body: some View {
        Button {
            showDetail = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("AI 推荐分录")
                    .font(.caption.bold())
                if let first = suggestions.first {
                    Text("\(first.accountName) ¥\(FMT.amount(first.debit > 0 ? first.debit : first.credit))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if suggestions.count > 1 {
                    Text("+\(suggestions.count - 1)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.08))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDetail) {
            VStack(alignment: .leading, spacing: 8) {
                Text("AI 推荐分录")
                    .font(.headline)
                Divider()
                ForEach(Array(suggestions.enumerated()), id: \.offset) { _, s in
                    HStack {
                        Text(s.accountCode)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .leading)
                        Text(s.accountName)
                            .font(.subheadline)
                        Spacer()
                        if s.debit > 0 {
                            Text("借 ¥\(FMT.amount(s.debit))")
                                .foregroundStyle(.blue)
                                .font(.caption.monospacedDigit())
                        } else {
                            Text("贷 ¥\(FMT.amount(s.credit))")
                                .foregroundStyle(.red)
                                .font(.caption.monospacedDigit())
                        }
                    }
                    Text(s.lineSummary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 54)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("取消") { showDetail = false }
                        .buttonStyle(.bordered)
                    Button("应用推荐") {
                        showDetail = false
                        onApply(suggestions)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(width: 360)
        }
    }
}