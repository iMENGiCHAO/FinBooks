import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 发票拖拽/上传自动录入

struct DropZoneView: View {
    let companyID: UUID
    var onInvoiceParsed: (InvoiceData) -> Void
    
    @State private var isTargeted = false
    @State private var showFilePicker = false
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 36))
                .foregroundStyle(isTargeted ? .blue : .secondary)
            
            Text("拖入发票 PDF 或图片")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Text("支持 PDF、PNG、JPG 格式")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            
            Button {
                showFilePicker = true
            } label: {
                Label("选择文件", systemImage: "folder")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isTargeted ? Color.blue : Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 2, dash: [6]))
                .background(isTargeted ? Color.blue.opacity(0.05) : Color.clear)
        )
        .onDrop(of: [.fileURL, .pdf, .image, .png, .jpeg], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.pdf, .image, .png, .jpeg]) { result in
            if case .success(let url) = result {
                processFile(url: url)
            }
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    self.processFile(url: url)
                }
            }
        }
    }
    
    private func processFile(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        
        // 读取文件内容，发送给 AI 解析
        // 目前先作为 demo 显示文件信息
        _ = url.lastPathComponent
        _ = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        
        // 调用 AI 解析发票
        InvoiceParser.shared.parse(fileURL: url) { result in
            switch result {
            case .success(let invoice):
                onInvoiceParsed(invoice)
            case .failure(let error):
                print("[Invoice] 解析失败: \(error)")
            }
        }
    }
}

// MARK: - 发票数据模型
struct InvoiceData {
    let invoiceNumber: String
    let date: Date
    let sellerName: String
    let sellerTaxId: String
    let buyerName: String
    let buyerTaxId: String
    let items: [InvoiceItem]
    let amount: Decimal      // 不含税金额
    let tax: Decimal         // 税额
    let total: Decimal       // 价税合计
    let taxRate: String      // 税率如 "13%"
}

struct InvoiceItem {
    let name: String       // 项目名称
    let specification: String // 规格型号
    let unit: String
    let quantity: Decimal
    let unitPrice: Decimal
    let amount: Decimal
    let taxRate: String
    let tax: Decimal
}

// MARK: - 发票解析器（调用 AI Gateway）
@MainActor
final class InvoiceParser: ObservableObject {
    static let shared = InvoiceParser()
    
    @Published var isParsing = false
    @Published var lastResult: InvoiceData?
    @Published var errorMessage: String?
    
    private var gatewayURL: URL? {
        URL(string: AgentConfigManager.shared.effectiveBaseURL)
    }
    
    private init() {}
    
    func parse(fileURL: URL, completion: @escaping (Result<InvoiceData, Error>) -> Void) {
        isParsing = true
        errorMessage = nil
        
        // 读取文件前几个字节判断类型
        guard let data = try? Data(contentsOf: fileURL) else {
            completion(.failure(NSError(domain: "InvoiceParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法读取文件"])))
            isParsing = false
            return
        }
        
        let base64 = data.base64EncodedString()
        let fileExt = fileURL.pathExtension.lowercased()
        let mimeType: String
        if fileExt == "pdf" {
            mimeType = "application/pdf"
        } else if ["png", "jpg", "jpeg"].contains(fileExt) {
            mimeType = "image/\(fileExt == "jpg" ? "jpeg" : fileExt)"
        } else {
            completion(.failure(NSError(domain: "InvoiceParser", code: -2, userInfo: [NSLocalizedDescriptionKey: "不支持的文件格式"])))
            isParsing = false
            return
        }
        
        let body: [String: Any] = [
            "model": AgentConfigManager.shared.activeAgent?.model ?? "deepseek-ai/deepseek-v4-flash",
            "messages": [
                ["role": "system", "content": "你是一个发票 OCR 专家。根据用户提供的文件（PDF/图片），提取全部发票信息并以 JSON 格式返回。只返回 JSON，不要有其他文字。"],
                ["role": "user", "content": """
                请解析这张发票，提取以下字段的 JSON 格式：
                {
                  "invoiceNumber": "发票号码",
                  "date": "YYYY-MM-DD",
                  "sellerName": "销售方名称",
                  "sellerTaxId": "销售方税号",
                  "buyerName": "购买方名称",
                  "buyerTaxId": "购买方税号",
                  "amount": 不含税金额（数字）,
                  "tax": 税额（数字）,
                  "total": 价税合计（数字）,
                  "taxRate": "税率如13%",
                  "items": [
                    {"name": "项目名称", "specification": "规格型号", "unit": "单位", "quantity": 数量, "unitPrice": 单价, "amount": 金额, "taxRate": "税率", "tax": 税额}
                  ]
                }
                
                文件类型: \(mimeType)
                文件名: \(fileURL.lastPathComponent)
                文件大小: \(data.count) bytes
                文件内容(Base64前100字符): \(String(base64.prefix(100)))...
                """]
            ],
            "max_tokens": 2048,
            "temperature": 0.1
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let url = gatewayURL else {
            completion(.failure(NSError(domain: "InvoiceParser", code: -3, userInfo: [NSLocalizedDescriptionKey: "配置错误"])))
            isParsing = false
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !AgentConfigManager.shared.effectiveAPIKey.isEmpty {
            request.setValue("Bearer \(AgentConfigManager.shared.effectiveAPIKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = jsonData
        request.timeoutInterval = 60
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            Task { @MainActor in
                self.isParsing = false
                
                if let error = error {
                    completion(.failure(error))
                    return
                }
                
                guard let data = data, let dataStr = String(data: data, encoding: .utf8) else {
                    completion(.failure(NSError(domain: "InvoiceParser", code: -4, userInfo: [NSLocalizedDescriptionKey: "空响应"])))
                    return
                }
                
                // 提取 content
                var fullContent = ""
                for line in dataStr.components(separatedBy: "\n") {
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
                
                guard let resultJSON = self.extractJSON(from: fullContent),
                      let resultData = resultJSON.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
                    completion(.failure(NSError(domain: "InvoiceParser", code: -5, userInfo: [NSLocalizedDescriptionKey: "解析结果格式错误"])))
                    return
                }
                
                do {
                    let invoice = try self.parseInvoiceDict(dict)
                    self.lastResult = invoice
                    completion(.success(invoice))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }
    
    private func extractJSON(from text: String) -> String? {
        guard let startIdx = text.firstIndex(of: "{"),
              let endIdx = text.lastIndex(of: "}") else { return nil }
        return String(text[startIdx...endIdx])
    }
    
    private func parseInvoiceDict(_ dict: [String: Any]) throws -> InvoiceData {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        guard let invoiceNumber = dict["invoiceNumber"] as? String,
              let dateStr = dict["date"] as? String,
              let date = dateFormatter.date(from: dateStr),
              let sellerName = dict["sellerName"] as? String,
              let sellerTaxId = dict["sellerTaxId"] as? String,
              let buyerName = dict["buyerName"] as? String,
              let buyerTaxId = dict["buyerTaxId"] as? String,
              let amount = dict["amount"] as? Double,
              let tax = dict["tax"] as? Double,
              let total = dict["total"] as? Double else {
            throw NSError(domain: "InvoiceParser", code: -6, userInfo: [NSLocalizedDescriptionKey: "缺少必要字段"])
        }
        
        let taxRate = dict["taxRate"] as? String ?? "13%"
        var items: [InvoiceItem] = []
        if let itemsArr = dict["items"] as? [[String: Any]] {
            for item in itemsArr {
                let name = item["name"] as? String ?? ""
                let specification = item["specification"] as? String ?? ""
                let unit = item["unit"] as? String ?? ""
                let quantity = (item["quantity"] as? Double) ?? 0
                let unitPrice = (item["unitPrice"] as? Double) ?? 0
                let itemAmount = (item["amount"] as? Double) ?? 0
                let itemTaxRate = item["taxRate"] as? String ?? ""
                let itemTax = (item["tax"] as? Double) ?? 0
                items.append(InvoiceItem(name: name, specification: specification, unit: unit, quantity: Decimal(quantity), unitPrice: Decimal(unitPrice), amount: Decimal(itemAmount), taxRate: itemTaxRate, tax: Decimal(itemTax)))
            }
        }
        
        return InvoiceData(
            invoiceNumber: invoiceNumber,
            date: date,
            sellerName: sellerName,
            sellerTaxId: sellerTaxId,
            buyerName: buyerName,
            buyerTaxId: buyerTaxId,
            items: items,
            amount: Decimal(amount),
            tax: Decimal(tax),
            total: Decimal(total),
            taxRate: taxRate
        )
    }
}

// MARK: - 发票预览 & 转凭证 UI

struct InvoicePreviewSheet: View {
    let invoice: InvoiceData
    let companyID: UUID
    var onCreateVoucher: ((InvoiceData) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var dataStore: DataStore
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 发票头
                    GroupBox("发票信息") {
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: "发票号码", value: invoice.invoiceNumber)
                            InfoRow(label: "开票日期", value: FMT.date(invoice.date))
                            InfoRow(label: "销售方", value: "\(invoice.sellerName)（\(invoice.sellerTaxId)）")
                            InfoRow(label: "购买方", value: "\(invoice.buyerName)（\(invoice.buyerTaxId)）")
                            Divider()
                            InfoRow(label: "金额", value: "¥\(FMT.amount(invoice.amount))")
                            InfoRow(label: "税率", value: invoice.taxRate)
                            InfoRow(label: "税额", value: "¥\(FMT.amount(invoice.tax))")
                            InfoRow(label: "价税合计", value: "¥\(FMT.amount(invoice.total))", isBold: true)
                        }
                    }
                    
                    if !invoice.items.isEmpty {
                        GroupBox("项目明细") {
                            ForEach(Array(invoice.items.enumerated()), id: \.offset) { _, item in
                                HStack {
                                    Text(item.name).font(.subheadline)
                                    Spacer()
                                    Text("¥\(FMT.amount(item.amount))")
                                        .font(.caption.monospacedDigit())
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    
                    // 推荐分录
                    GroupBox("推荐分录") {
                        VStack(alignment: .leading, spacing: 6) {
                            let accounts = dataStore.accounts(for: companyID)
                            let expenseCode = guessExpenseAccount(for: invoice)
                            let expenseName = accounts.first(where: { $0.code == expenseCode })?.name ?? "管理费用"
                            let taxCode = "2221.01.01"
                            let taxName = accounts.first(where: { $0.code == taxCode })?.name ?? "进项税额"
                            let payableCode = "2202"
                            let payableName = accounts.first(where: { $0.code == payableCode })?.name ?? "应付账款"
                            
                            VoucherSuggestionRow(code: expenseCode, name: expenseName, debit: invoice.amount, credit: 0, summary: "\(invoice.items.first?.name ?? "服务费")")
                            VoucherSuggestionRow(code: taxCode, name: taxName, debit: invoice.tax, credit: 0, summary: "增值税进项税额")
                            VoucherSuggestionRow(code: payableCode, name: payableName, debit: 0, credit: invoice.total, summary: "应付\(invoice.sellerName)")
                            
                            Divider()
                            HStack {
                                Spacer()
                                Text("借: ¥\(FMT.amount(invoice.amount + invoice.tax))")
                                    .foregroundStyle(.blue)
                                    .font(.caption.monospacedDigit())
                                Text("贷: ¥\(FMT.amount(invoice.total))")
                                    .foregroundStyle(.red)
                                    .font(.caption.monospacedDigit())
                                if invoice.amount + invoice.tax == invoice.total {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("取消") { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("生成凭证") {
                        onCreateVoucher?(invoice)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .navigationTitle("发票预览")
        }
        .frame(width: 500, height: 600)
    }
    
    private func guessExpenseAccount(for invoice: InvoiceData) -> String {
        // 根据项目名称推断费用科目
        let name = invoice.items.first?.name ?? ""
        if name.contains("清洁") || name.contains("物业") || name.contains("维修") {
            return "6602" // 管理费用
        }
        if name.contains("销售") || name.contains("广告") || name.contains("推广") {
            return "6601" // 销售费用
        }
        if name.contains("材料") || name.contains("商品") || name.contains("采购") {
            return "6001" // 主营业务成本
        }
        return "6602" // 默认管理费用
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var isBold: Bool = false
    
    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
                .font(.caption)
            Text(value)
                .font(isBold ? .subheadline.bold() : .subheadline)
                .textSelection(.enabled)
            Spacer()
        }
    }
}

struct VoucherSuggestionRow: View {
    let code: String
    let name: String
    let debit: Decimal
    let credit: Decimal
    let summary: String
    
    var body: some View {
        HStack {
            Text(code).font(.caption).foregroundStyle(.secondary).frame(width: 40)
            Text(name).font(.subheadline).frame(width: 80, alignment: .leading)
            Text(summary).font(.caption).foregroundStyle(.tertiary)
            Spacer()
            if debit > 0 {
                Text("借 ¥\(FMT.amount(debit))")
                    .foregroundStyle(.blue).font(.caption.monospacedDigit())
            } else {
                Text("贷 ¥\(FMT.amount(credit))")
                    .foregroundStyle(.red).font(.caption.monospacedDigit())
            }
        }
    }
}