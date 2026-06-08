import SwiftUI
import AppKit

// MARK: - AI 助手浮动窗口管理器 (NSWindowController)

@MainActor
final class AIWindowManager: ObservableObject {
    static let shared = AIWindowManager()

    private var windowController: NSWindowController?
    private var hostingView: NSView?

    var isVisible: Bool { windowController?.window?.isVisible ?? false }

    func toggle(companyContext: @escaping () -> (name: String, summary: String)) {
        if isVisible {
            hide()
        } else {
            show(companyContext: companyContext)
        }
    }

    func show(companyContext: @escaping () -> (name: String, summary: String)) {
        if isVisible { return }

        let hostingView = AIChatWindow(companyContext: companyContext)

        let view = NSHostingView(rootView: hostingView)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 560)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AI 助手"
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.center()

        // 关键：设置窗口层级为 floating，使其始终在主窗口之上
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 设置窗口最小尺寸
        window.minSize = NSSize(width: 350, height: 400)

        // 保存上次关闭时的位置
        if let savedFrame = UserDefaults.standard.string(forKey: "finbooks_ai_window_frame") {
            let rect = NSRectFromString(savedFrame)
            if rect.origin.x != 0 || rect.origin.y != 0 {
                window.setFrame(rect, display: true)
            }
        }

        // 监听窗口关闭事件
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            if let frame = window?.frame {
                UserDefaults.standard.set(NSStringFromRect(frame), forKey: "finbooks_ai_window_frame")
            }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        windowController = NSWindowController(window: window)
        self.hostingView = view
    }

    func hide() {
        guard let window = windowController?.window else { return }
        // 保存位置
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "finbooks_ai_window_frame")
        window.close()
        windowController = nil
        hostingView = nil
    }
}

// MARK: - ContentView

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
        case cashFlow = "现金流量表"
        case bankAccount = "银行账户"
        case bankReconciliation = "银行对账"
        case invoiceManagement = "发票管理"
        case fixedAsset = "固定资产"
        case vatReport = "增值税申报"
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
            case .cashFlow: return "arrow.triangle.swap"
            case .bankAccount: return "building.columns"
            case .bankReconciliation: return "arrow.left.arrow.right"
            case .invoiceManagement: return "doc.text.magnifyingglass"
            case .fixedAsset: return "building.2"
            case .vatReport: return "doc.plaintext"
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
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        AIWindowManager.shared.toggle(companyContext: {
                            let name = selectedCompany?.name ?? ""
                            let summary = buildFinancialSummary(company: selectedCompany)
                            return (name, summary)
                        })
                    } label: {
                        Label("AI 助手", systemImage: "brain.head.profile")
                    }
                    .foregroundStyle(AIWindowManager.shared.isVisible ? .blue : .secondary)
                }
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
            .onAppear {
                // 初始化默认公司
                if selectedCompany == nil, let first = dataStore.companies.first {
                    selectedCompany = first
                }
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
                    if newValue != nil {
                        navigationItem = .dashboard
                        // 切换公司时重置 AI 会话上下文
                        AIAssistant.shared.resetSession()
                    }
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
            Group {
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
                case .cashFlow: CashFlowStatementView(company: company)
                case .bankAccount: BankAccountView(company: company)
                case .bankReconciliation: BankReconciliationView(company: company)
                case .invoiceManagement: InvoiceListView(company: company)
                case .fixedAsset: FixedAssetView(company: company)
                case .vatReport: VATReportView(company: company)
                case .periodClose: PeriodCloseView(company: company)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("选择公司", systemImage: "building.2",
                                   description: Text("请从侧边栏选择或创建一个公司"))
        }
    }

    /// 构建财务摘要（供 AI 上下文使用）
    private func buildFinancialSummary(company: Company?) -> String {
        guard let company = company else { return "" }
        let accounts = dataStore.accounts(for: company.id)
        let entries = dataStore.entries(for: company.id)
        let postedCount = entries.filter { $0.isPosted }.count
        let totalDebit = entries.reduce(Decimal.zero) { $0 + $1.debitTotal }
        let totalCredit = entries.reduce(Decimal.zero) { $0 + $1.creditTotal }
        let assetCount = accounts.filter { $0.isActive && $0.category == .asset }.count
        let expenseCount = accounts.filter { $0.isActive && $0.category == .expense }.count
        let totalAssets = accounts.filter { $0.isActive && $0.category == .asset }
            .reduce(Decimal.zero) { $0 + AccountingEngine.balance(for: $1) }

        return """
        公司: \(company.name) | 税号: \(company.taxId)
        科目数: \(accounts.filter(\.isActive).count) (资产\(assetCount) / 费用\(expenseCount))
        凭证数: \(entries.count) (已过账\(postedCount))
        借贷总计: 借¥\(FMT.amount(totalDebit)) / 贷¥\(FMT.amount(totalCredit))
        总资产: ¥\(FMT.amount(totalAssets))
        本位币: \(company.currency)
        """
    }
}