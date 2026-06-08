import SwiftUI
import UniformTypeIdentifiers

// MARK: - 银行账户管理

struct BankAccountView: View {
    let company: Company
    @EnvironmentObject var dataStore: DataStore
    @State private var showAddAccount = false
    @State private var selectedAccount: BankAccount?
    @State private var showTransactions = false
    @State private var showImportCSV = false
    @State private var autoMatchResult: String?
    @State private var deleteConfirm: BankAccount?
    @State private var bankSearchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索账户…", text: $bankSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Spacer()
                Button {
                    showAddAccount = true
                } label: {
                    Label("新增账户", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            if myAccounts.isEmpty {
                ContentUnavailableView("暂无银行账户", systemImage: "banknote",
                                       description: Text("点击「新增账户」添加第一个银行账户"))
            } else {
                accountsTable
            }
        }
        .sheet(isPresented: $showAddAccount) {
            BankAccountEditView(company: company)
        }
        .sheet(isPresented: $showTransactions) {
            if let acct = selectedAccount {
                BankTransactionListView(bankAccount: acct, company: company)
            }
        }
        .alert("自动匹配结果", isPresented: .init(
            get: { autoMatchResult != nil },
            set: { if !$0 { autoMatchResult = nil } }
        ), presenting: autoMatchResult) { _ in
            Button("确定") { autoMatchResult = nil }
        } message: { msg in
            Text(msg)
        }
        .alert("删除账户", isPresented: .init(
            get: { deleteConfirm != nil },
            set: { if !$0 { deleteConfirm = nil } }
        ), presenting: deleteConfirm) { acct in
            Button("取消", role: .cancel) { deleteConfirm = nil }
            Button("删除", role: .destructive) {
                dataStore.deleteBankAccount(acct)
                deleteConfirm = nil
            }
        } message: { acct in
            Text("确定删除账户「\(acct.name)」？\\n该账户下的所有流水记录也将被删除。")
        }
    }

    private var myAccounts: [BankAccount] {
        let accounts = dataStore.bankAccounts.filter { $0.companyID == company.id }
        if bankSearchText.isEmpty { return accounts }
        return accounts.filter {
            $0.name.localizedCaseInsensitiveContains(bankSearchText) ||
            $0.bankName.localizedCaseInsensitiveContains(bankSearchText) ||
            $0.accountNumber.localizedCaseInsensitiveContains(bankSearchText)
        }
    }

    private func transactions(for account: BankAccount) -> [BankTransaction] {
        dataStore.bankTransactions.filter { $0.bankAccountID == account.id }
    }

    private func currentBalance(for account: BankAccount) -> Decimal {
        let txs = transactions(for: account)
        let net = txs.reduce(Decimal.zero) { $0 + $1.amount }
        return account.openingBalance + net
    }

    private func importCSV(for account: BankAccount) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "选择银行流水 CSV 文件"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let transactions = parseCSV(csv: content, bankAccountID: account.id, companyID: company.id)
                guard !transactions.isEmpty else {
                    autoMatchResult = "未解析到有效流水数据，请检查CSV格式。\\n格式：日期,摘要,金额,余额,参考号"
                    return
                }
                dataStore.importBankTransactions(transactions)
                autoMatchResult = "成功导入 \(transactions.count) 条流水记录"
            } catch {
                autoMatchResult = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    private func parseCSV(csv: String, bankAccountID: UUID, companyID: UUID) -> [BankTransaction] {
        var results: [BankTransaction] = []
        let rows = csv.components(separatedBy: .newlines)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        // 尝试常见日期格式
        let altFormatters = [
            "yyyy/MM/dd",
            "yyyyMMdd",
            "dd/MM/yyyy",
        ]

        for row in rows {
            let cols = row.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 2 else { continue }
            // 跳过表头行
            let first = cols[0].lowercased()
            if first == "date" || first == "日期" || first == "交易日期" { continue }

            var date: Date?
            if let d = dateFormatter.date(from: cols[0]) { date = d }
            if date == nil {
                for fmt in altFormatters {
                    let f = DateFormatter()
                    f.dateFormat = fmt
                    if let d = f.date(from: cols[0]) { date = d; break }
                }
            }
            guard let transactionDate = date else { continue }

            let description = cols.count > 1 ? cols[1] : ""
            let amount: Decimal
            if cols.count > 2, let val = Decimal(string: cols[2]) {
                amount = val
            } else { continue }

            let balance: Decimal
            if cols.count > 3, let val = Decimal(string: cols[3]) {
                balance = val
            } else { balance = 0 }

            let reference = cols.count > 4 ? cols[4] : ""

            var tx = BankTransaction(
                date: transactionDate,
                description: description,
                amount: amount,
                balance: balance,
                reference: reference,
                bankAccountID: bankAccountID
            )
            tx.companyID = companyID
            results.append(tx)
        }
        return results
    }

    private func autoMatch(for account: BankAccount) {
        let count = dataStore.autoMatchTransactions(for: account, daysWindow: 3)
        if count > 0 {
            autoMatchResult = "自动匹配成功：\(count) 条流水已匹配到凭证"
        } else {
            autoMatchResult = "未找到可匹配的流水（金额+3天内日期匹配）"
        }
    }
    
    private var accountsTable: some View {
        Table(myAccounts) {
            TableColumn("账户名称", value: \.name).width(140)
            TableColumn("银行", value: \.bankName).width(120)
            TableColumn("账号") { a in
                Text(a.accountNumber).font(.caption.monospaced()).foregroundStyle(.secondary)
            }.width(150)
            TableColumn("币种", value: \.currency).width(60)
            TableColumn("期初余额") { a in
                Text("¥\(FMT.amount(a.openingBalance))").monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.width(120).alignment(.trailing)
            TableColumn("当前余额") { a in
                Text("¥\(FMT.amount(currentBalance(for: a)))").monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundColor(currentBalance(for: a) >= 0 ? .primary : .red)
            }.width(120).alignment(.trailing)
            TableColumn("流水数") { a in
                Text("\(transactions(for: a).count)").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.width(70).alignment(.trailing)
            TableColumn("操作") { a in
                HStack(spacing: 8) {
                    Button { selectedAccount = a; showTransactions = true } label: {
                        Image(systemName: "list.bullet.rectangle").font(.caption)
                    }.buttonStyle(.plain).help("查看流水")
                    Button { importCSV(for: a) } label: {
                        Image(systemName: "square.and.arrow.down").font(.caption)
                    }.buttonStyle(.plain).help("导入CSV")
                    Button { autoMatch(for: a) } label: {
                        Image(systemName: "link.circle").font(.caption)
                    }.buttonStyle(.plain).help("自动匹配")
                    Button { deleteConfirm = a } label: {
                        Image(systemName: "trash").font(.caption).foregroundColor(.red)
                    }.buttonStyle(.plain).help("删除")
                }
            }.width(140)
        }
        .tableStyle(.bordered)
    }
}

// MARK: - 新增银行账户

struct BankAccountEditView: View {
    @EnvironmentObject var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss

    let company: Company

    @State private var name: String = ""
    @State private var bankName: String = ""
    @State private var accountNumber: String = ""
    @State private var openingBalance: Decimal = 0
    @State private var currency: String = "CNY"
    @State private var selectedAccountID: UUID?
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("账户名称（如：基本户-工行）", text: $name)
                TextField("银行名称", text: $bankName)
                TextField("账号", text: $accountNumber)
                HStack {
                    Text("期初余额")
                    TextField("期初余额", value: $openingBalance, format: .number.precision(.fractionLength(2)))
                        .multilineTextAlignment(.trailing)
                }
                TextField("币种", text: $currency)
                Picker("关联科目", selection: $selectedAccountID) {
                    Text("不关联").tag(nil as UUID?)
                    ForEach(availableAccounts) { acct in
                        Text("\(acct.code) \(acct.name)").tag(acct.id as UUID?)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("新增银行账户")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("错误", isPresented: $showError) {
                Button("确定") {}
            } message: {
                Text(errorMessage)
            }
            .frame(minWidth: 400, minHeight: 300)
        }
    }

    private var availableAccounts: [Account] {
        dataStore.accounts(for: company.id)
            .filter { $0.isActive && $0.category == .asset }
            .sorted { $0.code < $1.code }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "账户名称不能为空"
            showError = true
            return
        }
        guard !bankName.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "银行名称不能为空"
            showError = true
            return
        }
        guard !accountNumber.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "账号不能为空"
            showError = true
            return
        }

        let account = BankAccount(
            name: name, bankName: bankName, accountNumber: accountNumber,
            openingBalance: openingBalance, currency: currency, accountID: selectedAccountID
        )
        account.companyID = company.id
        dataStore.addBankAccount(account)
        dismiss()
    }
}

// MARK: - 银行流水列表

struct BankTransactionListView: View {
    let bankAccount: BankAccount
    let company: Company
    @EnvironmentObject var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 账户信息头
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bankAccount.name).font(.headline)
                        Text("\(bankAccount.bankName) | \(bankAccount.accountNumber)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("余额: ¥\(FMT.amount(currentBalance))")
                        .font(.title3.monospacedDigit())
                        .foregroundColor(currentBalance >= 0 ? .primary : .red)
                }
                .padding()

                Divider()

                if txs.isEmpty {
                    ContentUnavailableView("暂无流水", systemImage: "tray",
                                           description: Text("点击「导入CSV」导入银行流水"))
                } else {
                    Table(txs) {
                        TableColumn("日期") { tx in
                            Text(FMT.date(tx.date)).font(.caption)
                        }.width(90)
                        TableColumn("摘要", value: \.description).width(160)
                        TableColumn("金额") { tx in
                            Text("¥\(FMT.amount(abs(tx.amount)))")
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .foregroundStyle(tx.amount >= 0 ? Color.blue : Color.red)
                                .monospacedDigit()
                        }.width(100).alignment(.trailing)
                        TableColumn("余额") { tx in
                            Text("¥\(FMT.amount(tx.balance))")
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .monospacedDigit()
                        }.width(100).alignment(.trailing)
                        TableColumn("参考号", value: \.reference).width(120)
                        TableColumn("状态") { tx in
                            HStack(spacing: 4) {
                                Circle().fill(tx.isMatched ? Color.green : Color.orange).frame(width: 7)
                                Text(tx.isMatched ? "已匹配" : "未匹配")
                                    .font(.caption)
                                    .foregroundStyle(tx.isMatched ? .green : .orange)
                            }
                        }.width(80)
                    }
                    .tableStyle(.bordered)
                }
            }
            .navigationTitle("银行流水")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }.keyboardShortcut(.escape)
                }
            }
            .frame(minWidth: 800, minHeight: 400)
        }
    }

    private var txs: [BankTransaction] {
        dataStore.bankTransactions
            .filter { $0.bankAccountID == bankAccount.id }
            .sorted { $0.date > $1.date }
    }

    private var currentBalance: Decimal {
        let net = txs.reduce(Decimal.zero) { $0 + $1.amount }
        return bankAccount.openingBalance + net
    }
}
