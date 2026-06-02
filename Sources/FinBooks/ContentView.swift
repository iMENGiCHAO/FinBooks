import SwiftUI

struct ContentView: View {
    @EnvironmentObject var dataStore: DataStore
    @State private var selectedCompany: Company?
    @State private var navigationItem: NavigationItem = .dashboard
    @State private var showNewCompany = false
    @State private var showEditCompany = false
    @State private var showDeleteConfirm = false
    @State private var companyToDelete: Company?

    enum NavigationItem: String, CaseIterable, Identifiable {
        case dashboard = "总览"
        case chartOfAccounts = "科目表"
        case journalEntries = "凭证管理"
        case generalLedger = "总分类账"
        case balanceSheet = "资产负债表"
        case incomeStatement = "利润表"
        case periodClose = "期末结账"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .dashboard: return "house"
            case .chartOfAccounts: return "list.bullet.rectangle"
            case .journalEntries: return "doc.text"
            case .generalLedger: return "book"
            case .balanceSheet: return "chart.pie"
            case .incomeStatement: return "chart.bar"
            case .periodClose: return "lock"
            }
        }
    }

    var body: some View {
        if dataStore.companies.isEmpty {
            welcomeView
        } else {
            NavigationSplitView {
                sidebar
            } detail: {
                detailView
            }
            .sheet(isPresented: $showNewCompany) {
                CompanyEditView(company: nil) { company in
                    selectedCompany = company
                    showNewCompany = false
                }
            }
            .sheet(isPresented: $showEditCompany) {
                if let company = selectedCompany {
                    CompanyEditView(company: company) { _ in
                        showEditCompany = false
                    }
                }
            }
            .alert("确认删除公司", isPresented: $showDeleteConfirm, presenting: companyToDelete) { company in
                Button("取消", role: .cancel) { companyToDelete = nil }
                Button("删除", role: .destructive) {
                    if selectedCompany?.id == company.id {
                        selectedCompany = dataStore.companies.first { $0.id != company.id }
                    }
                    dataStore.deleteCompany(company)
                    companyToDelete = nil
                }
            } message: { company in
                Text("将永久删除「\(company.name)」及其所有科目、凭证数据。\n此操作不可恢复！")
            }
        }
    }

    // MARK: - Welcome
    private var welcomeView: some View {
        VStack(spacing: 24) {
            Image(systemName: "building.columns")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
            Text("FinBooks")
                .font(.largeTitle)
                .bold()
            Text("小规模公司财务管理")
                .foregroundStyle(.secondary)
            Button { showNewCompany = true } label: {
                Label("创建公司", systemImage: "plus")
                    .padding(.horizontal, 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sidebar
    private var sidebar: some View {
        VStack(spacing: 0) {
            // Company header with actions
            HStack {
                Picker("", selection: $selectedCompany) {
                    ForEach(dataStore.companies) { company in
                        HStack {
                            Image(systemName: "building.2")
                            Text(company.name)
                        }.tag(company as Company?)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedCompany) { _, newValue in
                    if newValue != nil { navigationItem = .dashboard }
                }

                if selectedCompany != nil {
                    Menu {
                        Button("编辑公司信息") { showEditCompany = true }
                        Divider()
                        Button("删除公司", role: .destructive) {
                            companyToDelete = selectedCompany
                            showDeleteConfirm = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List(NavigationItem.allCases, selection: $navigationItem) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)

            Spacer()

            Divider()
            Button {
                showNewCompany = true
            } label: {
                Label("新建公司", systemImage: "building.2.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 220)
        .onAppear {
            if selectedCompany == nil, let first = dataStore.companies.first {
                selectedCompany = first
            }
        }
    }

    // MARK: - Detail
    @ViewBuilder
    private var detailView: some View {
        if let company = selectedCompany {
            switch navigationItem {
            case .dashboard: DashboardView(company: company, onNavigate: { name in
                if let item = ContentView.NavigationItem(rawValue: name) {
                    navigationItem = item
                }
            })
            case .chartOfAccounts: ChartOfAccountsView(company: company)
            case .journalEntries: JournalEntriesView(company: company)
            case .generalLedger: GeneralLedgerView(company: company)
            case .balanceSheet: BalanceSheetView(company: company)
            case .incomeStatement: IncomeStatementView(company: company)
            case .periodClose: PeriodCloseView(company: company)
            }
        } else {
            ContentUnavailableView("选择公司", systemImage: "building.2",
                                   description: Text("请从侧边栏选择或创建一个公司"))
        }
    }
}
