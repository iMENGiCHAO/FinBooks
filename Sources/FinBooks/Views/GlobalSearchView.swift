import SwiftUI

// MARK: - 全局搜索（Cmd+K）

struct GlobalSearchView: View {
    let company: Company
    @EnvironmentObject var dataStore: DataStore
    @Binding var isPresented: Bool
    @State private var searchText = ""
    @State private var selectedTab = "凭证"
    
    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏（macOS 风格）
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索凭证号、摘要、科目、金额…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .controlSize(.large)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            
            if !searchText.isEmpty {
                Divider()
                
                // 分类标签
                HStack(spacing: 6) {
                    searchChip("凭证", count: entryResults.count)
                    searchChip("科目", count: accountResults.count)
                    searchChip("公司", count: companyResults.count)
                    Spacer()
                    Text("\(entryResults.count + accountResults.count + companyResults.count) 个结果")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                
                Divider()
                
                // 结果
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if selectedTab == "凭证" {
                            if entryResults.isEmpty {
                                emptyResult("未找到匹配凭证")
                            }
                            ForEach(entryResults, id: \.id) { entry in
                                SearchResultRow(
                                    icon: "doc.text",
                                    title: "#\(entry.number) \(entry.summary)",
                                    subtitle: "\(FMT.date(entry.date)) | 借¥\(FMT.amount(entry.debitTotal)) / 贷¥\(FMT.amount(entry.creditTotal))"
                                )
                            }
                        } else if selectedTab == "科目" {
                            if accountResults.isEmpty {
                                emptyResult("未找到匹配科目")
                            }
                            ForEach(accountResults, id: \.id) { acct in
                                SearchResultRow(
                                    icon: "list.bullet.rectangle",
                                    title: "\(acct.code) \(acct.name)",
                                    subtitle: acct.category.rawValue
                                )
                            }
                        } else {
                            if companyResults.isEmpty {
                                emptyResult("未找到匹配公司")
                            }
                            ForEach(companyResults, id: \.id) { co in
                                SearchResultRow(
                                    icon: "building.2",
                                    title: co.name,
                                    subtitle: co.taxId
                                )
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                // 搜索提示
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("输入凭证号、摘要、科目名称或金额进行搜索")
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 480, height: 400)
    }
    
    private var entryResults: [JournalEntry] {
        guard !searchText.isEmpty else { return [] }
        let q = searchText.lowercased()
        return dataStore.entries(for: company.id).filter {
            $0.number.lowercased().contains(q) ||
            $0.summary.lowercased().contains(q) ||
            FMT.amount($0.debitTotal).contains(q) ||
            FMT.amount($0.creditTotal).contains(q) ||
            $0.lines.contains { $0.resolvedAccountName.localizedCaseInsensitiveContains(q) }
        }
    }
    
    private var accountResults: [Account] {
        guard !searchText.isEmpty else { return [] }
        let q = searchText.lowercased()
        return dataStore.accounts(for: company.id).filter {
            $0.code.contains(q) || $0.name.lowercased().contains(q)
        }
    }
    
    private var companyResults: [Company] {
        guard !searchText.isEmpty else { return [] }
        let q = searchText.lowercased()
        return dataStore.companies.filter {
            $0.name.lowercased().contains(q) || $0.taxId.lowercased().contains(q)
        }
    }
    
    private func searchChip(_ label: String, count: Int) -> some View {
        Button(label + (count > 0 ? " (\(count))" : "")) {
            selectedTab = label
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(selectedTab == label ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
        .foregroundStyle(selectedTab == label ? .white : .primary)
        .cornerRadius(8)
        .buttonStyle(.plain)
    }
    
    private func emptyResult(_ msg: String) -> some View {
        Text(msg).foregroundStyle(.tertiary).padding(24).frame(maxWidth: .infinity)
    }
}

struct SearchResultRow: View {
    let icon: String
    let title: String
    let subtitle: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline)
                    .textSelection(.enabled)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }
}