import Foundation
import SwiftUI

// MARK: - 凭证模板

struct VoucherTemplate: Codable, Identifiable {
    let id: UUID
    var name: String
    var summary: String
    var lines: [TemplateLine]
    var group: String  // "common", "expense", "revenue", "asset"
    var sortOrder: Int
    
    struct TemplateLine: Codable {
        var accountCode: String
        var debit: Bool  // true=借方, false=贷方
        var lineSummary: String
    }
}

/// 凭证模板管理器
@MainActor
final class TemplateManager: ObservableObject {
    static let shared = TemplateManager()
    
    @Published var templates: [VoucherTemplate] = []
    
    private init() {
        load()
        if templates.isEmpty { loadDefaults() }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: "voucher_templates"),
           let saved = try? JSONDecoder().decode([VoucherTemplate].self, from: data) {
            templates = saved
        }
    }
    
    private func save() {
        if let data = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(data, forKey: "voucher_templates")
        }
    }
    
    private func loadDefaults() {
        templates = [
            VoucherTemplate(id: UUID(), name: "支付房租", summary: "支付办公室房租", lines: [
                .init(accountCode: "6602", debit: true, lineSummary: "办公室房租"),
                .init(accountCode: "1002", debit: false, lineSummary: "银行存款"),
            ], group: "expense", sortOrder: 1),
            VoucherTemplate(id: UUID(), name: "购买办公用品", summary: "购买办公用品", lines: [
                .init(accountCode: "6602", debit: true, lineSummary: "办公用品"),
                .init(accountCode: "1002", debit: false, lineSummary: "银行存款"),
            ], group: "expense", sortOrder: 2),
            VoucherTemplate(id: UUID(), name: "收到销售收入", summary: "销售商品收入", lines: [
                .init(accountCode: "1002", debit: true, lineSummary: "银行存款"),
                .init(accountCode: "6001", debit: false, lineSummary: "主营业务收入"),
                .init(accountCode: "2221", debit: false, lineSummary: "应交增值税销项税额"),
            ], group: "revenue", sortOrder: 3),
            VoucherTemplate(id: UUID(), name: "计提工资", summary: "计提本月工资", lines: [
                .init(accountCode: "6602", debit: true, lineSummary: "管理费用-工资"),
                .init(accountCode: "2211", debit: false, lineSummary: "应付职工薪酬"),
            ], group: "expense", sortOrder: 4),
            VoucherTemplate(id: UUID(), name: "提取备用金", summary: "提取备用金", lines: [
                .init(accountCode: "1001", debit: true, lineSummary: "库存现金"),
                .init(accountCode: "1002", debit: false, lineSummary: "银行存款"),
            ], group: "common", sortOrder: 5),
            VoucherTemplate(id: UUID(), name: "购入固定资产", summary: "购入固定资产", lines: [
                .init(accountCode: "1601", debit: true, lineSummary: "固定资产"),
                .init(accountCode: "2221", debit: true, lineSummary: "应交增值税进项税额"),
                .init(accountCode: "1002", debit: false, lineSummary: "银行存款"),
            ], group: "asset", sortOrder: 6),
        ]
        save()
    }
    
    func saveTemplate(_ template: VoucherTemplate) {
        if let idx = templates.firstIndex(where: { $0.id == template.id }) {
            templates[idx] = template
        } else {
            templates.append(template)
        }
        save()
    }
    
    func deleteTemplate(_ id: UUID) {
        templates.removeAll { $0.id == id }
        save()
    }
    
    var groups: [(String, String)] {
        [
            ("common", "常用"),
            ("expense", "费用"),
            ("revenue", "收入"),
            ("asset", "资产"),
        ]
    }
}

// MARK: - 模板选择 UI

struct TemplatePickerView: View {
    let accounts: [Account]
    var onSelect: (String, String, [(accountCode: String, accountName: String, debit: Bool, lineSummary: String)]) -> Void
    @State private var selectedGroup = "common"
    @StateObject private var manager = TemplateManager.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 8) {
            Text("凭证模板").font(.headline)
            
            // 分组
            HStack(spacing: 4) {
                ForEach(manager.groups, id: \.0) { (key, label) in
                    Button(label) {
                        selectedGroup = key
                    }
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(selectedGroup == key ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                    .foregroundStyle(selectedGroup == key ? .white : .primary)
                    .cornerRadius(10)
                    .buttonStyle(.plain)
                }
            }
            
            let filtered = manager.templates.filter { $0.group == selectedGroup }.sorted { $0.sortOrder < $1.sortOrder }
            if filtered.isEmpty {
                Text("此分类暂无模板").foregroundStyle(.tertiary).padding()
            } else {
                List(filtered) { tpl in
                    Button {
                        let resolved = tpl.lines.map { line -> (String, String, Bool, String) in
                            let account = accounts.first { $0.code == line.accountCode }
                            return (line.accountCode, account?.name ?? line.accountCode, line.debit, line.lineSummary)
                        }
                        onSelect(tpl.summary, tpl.name, resolved)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tpl.name).font(.subheadline.bold())
                            Text(tpl.summary).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .padding()
        .frame(width: 300, height: 350)
    }
}