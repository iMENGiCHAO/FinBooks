import SwiftUI

// MARK: - 银行对账

struct BankReconciliationView: View {
    let company: Company
    @EnvironmentObject var dataStore: DataStore
    @State private var selectedAccount: BankAccount?
    @State private var reconciliationDate: Date = Date()
    @State private var statementBalance: Decimal = 0
    @State private var bookBalance: Decimal = 0
    @State private var matchedCount: Int = 0
    @State private var showReconciliation = false
    @State private var activeReconciliation: Reconciliation?
    @State private var showCompleteConfirm = false
    @State private var reconResult: String?

    var body: some View {
        VStack(spacing: 0) {
            // 选择参数
            HStack {
                Picker("银行账户", selection: $selectedAccount) {
                    Text("请选择").tag(nil as BankAccount?)
                    ForEach(myAccounts) { acct in
                        Text(acct.name).tag(acct as BankAccount?)
                    }
                }
                .frame(width: 260)
                .onChange(of: selectedAccount) { _, _ in
                    refreshBalances()
                }

                DatePicker("对账日期", selection: $reconciliationDate, displayedComponents: .date)
                    .frame(width: 200)

                Spacer()

                if selectedAccount != nil {
                    Button {
                        startReconciliation()
                    } label: {
                        Label("新建对账", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("自动匹配") {
                        autoMatch()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()

            Divider()

            if let account = selectedAccount {
                if let recon = activeReconciliation {
                    reconciliationContent(account: account, recon: recon)
                } else {
                    reconciliationHistory(account: account)
                }
            } else {
                ContentUnavailableView("选择银行账户", systemImage: "building.columns",
                                       description: Text("请先选择一个银行账户进行对账"))
            }
        }
        .alert("对账结果", isPresented: .init(
            get: { reconResult != nil },
            set: { if !$0 { reconResult = nil } }
        ), presenting: reconResult) { _ in
            Button("确定") { reconResult = nil }
        } message: { Text($0) }
        .alert("完成对账", isPresented: $showCompleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认完成", action: completeReconciliation)
        } message: {
            Text("对账完成后不可修改，确定要完成本次对账吗？")
        }
    }

    private var myAccounts: [BankAccount] {
        dataStore.bankAccounts.filter { $0.companyID == company.id }
            .sorted { $0.name < $1.name }
    }

    private func txs(for account: BankAccount) -> [BankTransaction] {
        dataStore.bankTransactions.filter { $0.bankAccountID == account.id }
    }

    private func currentBalance(for account: BankAccount) -> Decimal {
        let net = txs(for: account).reduce(Decimal.zero) { $0 + $1.amount }
        return account.openingBalance + net
    }

    private func refreshBalances() {
        guard let acct = selectedAccount else { return }
        bookBalance = currentBalance(for: acct)
        matchedCount = txs(for: acct).filter(\.isMatched).count
    }

    private func startReconciliation() {
        guard let acct = selectedAccount else { return }
        bookBalance = currentBalance(for: acct)
        let recon = Reconciliation(
            bankAccountID: acct.id,
            reconciliationDate: reconciliationDate,
            bookBalance: bookBalance,
            statementBalance: statementBalance
        )
        recon.companyID = company.id
        dataStore.addReconciliation(recon)
        activeReconciliation = recon
        showReconciliation = true
    }

    private func autoMatch() {
        guard let acct = selectedAccount else { return }
        let count = dataStore.autoMatchTransactions(for: acct, daysWindow: 3)
        refreshBalances()
        reconResult = "自动匹配完成：\(count) 条流水匹配成功"
    }

    @ViewBuilder
    private func reconciliationContent(account: BankAccount, recon: Reconciliation) -> some View {
        let unmatchedTxs = txs(for: account).filter { !$0.isMatched }
        let entries = dataStore.entries(for: company.id).filter { $0.isPosted }
            .sorted { $0.date > $1.date }

        VStack(spacing: 0) {
            // 余额概览卡片
            HStack(spacing: 24) {
                balanceCard(title: "账面余额", amount: bookBalance, color: .blue)
                balanceCard(title: "对账单余额", amount: $statementBalance, editable: true, color: .orange)
                balanceCard(title: "差额", amount: bookBalance - statementBalance,
                           color: bookBalance == statementBalance ? .green : .red)
            }
            .padding()

            Divider()

            HStack {
                Text("未匹配流水 (\(unmatchedTxs.count) 条)")
                    .font(.headline)
                Spacer()
                if !unmatchedTxs.isEmpty {
                    Button {
                        autoMatch()
                    } label: {
                        Label("自动匹配", systemImage: "link")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if unmatchedTxs.isEmpty {
                ContentUnavailableView("全部已匹配", systemImage: "checkmark.circle.fill",
                                       description: Text("所有流水均已匹配完成"))
            } else {
                List {
                    ForEach(unmatchedTxs.prefix(50)) { tx in
                        UnmatchedTransactionRow(
                            transaction: tx,
                            entries: entries,
                            onMatch: { entry in
                                dataStore.matchTransaction(tx, to: entry)
                                refreshBalances()
                            },
                            onSkip: {}
                        )
                    }
                }
                .listStyle(.bordered)
            }

            Divider()

            HStack {
                Spacer()
                Button("取消对账") {
                    activeReconciliation = nil
                }
                .buttonStyle(.bordered)

                Button("完成对账") {
                    guard let recon = activeReconciliation else { return }
                    let unmatched = txs(for: account).filter { !$0.isMatched }
                    recon.matchedCount = txs(for: account).filter(\.isMatched).count
                    recon.unmatchedCount = unmatched.count
                    recon.statementBalance = statementBalance
                    recon.difference = bookBalance - statementBalance
                    dataStore.completeReconciliation(recon)
                    showCompleteConfirm = false
                    activeReconciliation = nil
                    reconResult = "对账完成！\n匹配：\(recon.matchedCount) 条\n未匹配：\(recon.unmatchedCount) 条\n差额：¥\(FMT.amount(recon.difference))"
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private func completeReconciliation() {
        guard let recon = activeReconciliation, let acct = selectedAccount else { return }
        let allTxs = txs(for: acct)
        recon.matchedCount = allTxs.filter(\.isMatched).count
        recon.unmatchedCount = allTxs.filter { !$0.isMatched }.count
        recon.statementBalance = statementBalance
        recon.difference = bookBalance - statementBalance
        dataStore.completeReconciliation(recon)
        activeReconciliation = nil
        reconResult = "对账完成！\n匹配：\(recon.matchedCount) 条\n未匹配：\(recon.unmatchedCount) 条\n差额：¥\(FMT.amount(recon.difference))"
    }

    @ViewBuilder
    private func reconciliationHistory(account: BankAccount) -> some View {
        let history = dataStore.reconciliations
            .filter { $0.bankAccountID == account.id }
            .sorted { $0.reconciliationDate > $1.reconciliationDate }

        if history.isEmpty {
            ContentUnavailableView("暂无对账记录", systemImage: "doc.text.magnifyingglass",
                                   description: Text("点击「新建对账」开始对账"))
        } else {
            Table(history) {
                TableColumn("对账日期") { r in Text(FMT.date(r.reconciliationDate)) }.width(110)
                TableColumn("账面余额") { r in
                    Text("¥\(FMT.amount(r.bookBalance))").monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.width(120).alignment(.trailing)
                TableColumn("对账单余额") { r in
                    Text("¥\(FMT.amount(r.statementBalance))").monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.width(120).alignment(.trailing)
                TableColumn("差额") { r in
                    Text("¥\(FMT.amount(r.difference))").monospacedDigit()
                        .foregroundStyle(r.difference == 0 ? .green : .red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.width(100).alignment(.trailing)
                TableColumn("状态") { r in
                    HStack(spacing: 4) {
                        Circle().fill(r.isComplete ? Color.green : Color.orange).frame(width: 7)
                        Text(r.isComplete ? "已完成" : "进行中")
                            .font(.caption)
                            .foregroundStyle(r.isComplete ? .green : .orange)
                    }
                }.width(90)
                TableColumn("匹配") { r in
                    Text("\(r.matchedCount)/\(r.matchedCount + r.unmatchedCount)")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }.width(80).alignment(.trailing)
            }
            .tableStyle(.bordered)
        }
    }

    @ViewBuilder
    private func balanceCard(title: String, amount: Decimal, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("¥\(FMT.amount(amount))")
                .font(.title3.monospacedDigit().bold())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func balanceCard(title: String, amount: Binding<Decimal>, editable: Bool, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("", value: amount, format: .number.precision(.fractionLength(2)))
                .multilineTextAlignment(.center)
                .font(.title3.monospacedDigit().bold())
                .foregroundStyle(color)
                .textFieldStyle(.plain)
                .frame(width: 140)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }
}

// MARK: - 未匹配流水行

struct UnmatchedTransactionRow: View {
    let transaction: BankTransaction
    let entries: [JournalEntry]
    let onMatch: (JournalEntry) -> Void
    let onSkip: () -> Void

    @State private var showPicker = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(FMT.date(transaction.date)).font(.caption).foregroundStyle(.secondary)
                Text(transaction.description).font(.body)
                Text("参考: \(transaction.reference)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("¥\(FMT.amount(abs(transaction.amount)))")
                .font(.title3.monospacedDigit())
                .foregroundStyle(transaction.amount >= 0 ? .blue : .red)
            Spacer().frame(width: 16)
            Menu {
                ForEach(entries.prefix(20)) { entry in
                    Button("\(entry.number) - \(entry.summary.prefix(20))") {
                        onMatch(entry)
                    }
                }
                if entries.count > 20 {
                    Text("更多结果请使用搜索…")
                }
                Divider()
                Button("跳过本次", action: onSkip)
            } label: {
                Label("匹配", systemImage: "link.badge.plus")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 60)
        }
        .padding(.vertical, 4)
    }
}
