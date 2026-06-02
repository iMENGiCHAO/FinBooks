import SwiftUI

struct DashboardView: View {
    let company: Company
    var onNavigate: ((String) -> Void)? = nil
    @EnvironmentObject var dataStore: DataStore
    @State private var currentPeriod = (year: Calendar.current.component(.year, from: Date()),
                                        month: Calendar.current.component(.month, from: Date()))
    @State private var showNewEntry = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 公司名称 + 期间
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(company.name)
                            .font(.largeTitle)
                            .bold()
                        Text("\(currentPeriod.year)年\(currentPeriod.month)月")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("本位币: \(company.currency)")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                // 财务指标卡片
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    StatCard(title: "总资产", value: totalAssets, color: .blue)
                    StatCard(title: "总负债", value: totalLiabilities, color: .orange)
                    StatCard(title: "所有者权益", value: totalEquity, color: .green)
                    StatCard(title: "本月净利润", value: netProfit, color: netProfit >= 0 ? .green : .red)
                }
                .padding(.horizontal)

                // 快速操作
                GroupBox("快速操作") {
                    HStack(spacing: 20) {
                        Button(action: {
                            showNewEntry = true
                        }) {
                            QuickActionButton(icon: "doc.text", title: "新增凭证", color: .blue)
                        }
                        .buttonStyle(.plain)

                        Button { onNavigate?("凭证管理") } label: {
                            QuickActionButton(icon: "list.bullet.rectangle", title: "凭证管理", color: .indigo)
                        }.buttonStyle(.plain)

                        Button { onNavigate?("利润表") } label: {
                            QuickActionButton(icon: "chart.bar", title: "利润表", color: .green)
                        }.buttonStyle(.plain)

                        Button { onNavigate?("资产负债表") } label: {
                            QuickActionButton(icon: "chart.pie", title: "资产负债表", color: .orange)
                        }.buttonStyle(.plain)

                        Button { onNavigate?("期末结账") } label: {
                            QuickActionButton(icon: "lock", title: "期末结账", color: .red)
                        }.buttonStyle(.plain)
                    }
                    .padding(.vertical, 8)
                }
                .padding(.horizontal)

                // 科目余额概览
                GroupBox("科目余额概览") {
                    AccountBalanceList(company: company)
                        .frame(minHeight: 200)
                }
                .padding(.horizontal)

                // 最近凭证
                GroupBox("最近凭证") {
                    RecentEntriesList(company: company)
                        .frame(minHeight: 120)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .sheet(isPresented: $showNewEntry) {
            EntryEditor(company: company, entry: nil)
        }
    }

    private var accounts: [Account] {
        dataStore.accounts(for: company.id)
    }

    private var totalAssets: Decimal {
        accounts.filter { $0.isActive && $0.category == .asset }
            .reduce(Decimal.zero) { $0 + AccountingEngine.balance(for: $1) }
    }

    private var totalLiabilities: Decimal {
        accounts.filter { $0.isActive && $0.category == .liability }
            .reduce(Decimal.zero) { $0 + AccountingEngine.balance(for: $1) }
    }

    private var totalEquity: Decimal {
        accounts.filter { $0.isActive && $0.category == .equity }
            .reduce(Decimal.zero) { $0 + AccountingEngine.balance(for: $1) }
    }

    private var netProfit: Decimal {
        let revenue = accounts.filter { $0.isActive && $0.category == .revenue }
            .reduce(Decimal.zero) { $0 + AccountingEngine.balance(for: $1) }
        let expense = accounts.filter { $0.isActive && $0.category == .expense }
            .reduce(Decimal.zero) { $0 + AccountingEngine.balance(for: $1) }
        return revenue - expense
    }
}

struct StatCard: View {
    let title: String
    let value: Decimal
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("¥\(FMT.amount(value))")
                .font(.title2)
                .bold()
                .foregroundStyle(color)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

struct QuickActionButton: View {
    let icon: String
    let title: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

struct AccountBalanceList: View {
    let company: Company
    @EnvironmentObject var dataStore: DataStore

    var body: some View {
        let accounts = dataStore.accounts(for: company.id).filter { $0.isActive }.sorted { $0.code < $1.code }
        Table(accounts) {
            TableColumn("科目编码", value: \.code).width(80)
            TableColumn("科目名称", value: \.name).width(160)
            TableColumn("类别") { account in
                Text(account.category.rawValue).foregroundStyle(.secondary)
            }.width(80)
            TableColumn("余额") { account in
                let bal = AccountingEngine.balance(for: account)
                Text("¥\(FMT.amount(bal))")
                    .foregroundStyle(bal > 0 ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(120)
            .alignment(.trailing)
        }
        .tableStyle(.bordered)
    }
}

struct RecentEntriesList: View {
    let company: Company
    @EnvironmentObject var dataStore: DataStore

    var body: some View {
        let entries = dataStore.entries(for: company.id)
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(8)

        if entries.isEmpty {
            ContentUnavailableView("暂无凭证", systemImage: "doc.text",
                                   description: Text("点击「新增凭证」创建第一张凭证"))
        } else {
            Table(Array(entries)) {
                TableColumn("凭证号", value: \.number).width(130)
                TableColumn("日期") { e in Text(FMT.date(e.date)) }.width(90)
                TableColumn("摘要", value: \.summary).width(180)
                TableColumn("金额") { e in
                    if e.debitTotal > 0 {
                        Text("¥\(FMT.amount(e.debitTotal))")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .font(.caption).monospacedDigit()
                    }
                }.width(100).alignment(.trailing)
                TableColumn("状态") { e in
                    HStack(spacing: 4) {
                        Circle().fill(e.isPosted ? Color.green : Color.orange).frame(width: 6)
                        Text(e.isPosted ? "已过账" : "未过账").font(.caption2)
                    }
                }.width(65)
            }
            .tableStyle(.bordered)
        }
    }
}
