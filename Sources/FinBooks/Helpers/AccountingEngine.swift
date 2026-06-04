import Foundation

// MARK: - 会计引擎
@MainActor
struct AccountingEngine {

    // MARK: - 凭证编号（单调递增，删除不补号）
    static func nextVoucherNumber(for company: Company) -> String {
        let year = Calendar.current.component(.year, from: Date())
        let prefix = "记-\(year)-"
        let entries = DataStore.shared.entries(for: company.id)
        let usedNumbers = entries
            .filter { $0.number.hasPrefix(prefix) }
            .compactMap { Int($0.number.dropFirst(prefix.count)) }
        let maxNumber = usedNumbers.max() ?? 0
        return "\(prefix)\(String(format: "%04d", maxNumber + 1))"
    }

    /// 余额（截止日期）
    static func balance(for account: Account, upTo date: Date = Date()) -> Decimal {
        let lines = allLines(for: account, upTo: date)
        let totalDebit = lines.reduce(Decimal.zero) { $0 + $1.debit }
        let totalCredit = lines.reduce(Decimal.zero) { $0 + $1.credit }
        switch account.category.nature {
        case .debit: return totalDebit - totalCredit
        case .credit: return totalCredit - totalDebit
        }
    }

    /// 年初余额（上一年12月31日截止）
    static func beginningBalance(for account: Account, asOf date: Date) -> Decimal {
        let cal = Calendar.current
        let year = cal.component(.year, from: date)
        guard let prevYearEnd = cal.date(from: DateComponents(year: year - 1, month: 12, day: 31, hour: 23, minute: 59, second: 59)) else {
            return balance(for: account, upTo: date)
        }
        return balance(for: account, upTo: prevYearEnd)
    }

    /// 本期发生额
    static func periodBalance(for account: Account, year: Int, month: Int) -> (debit: Decimal, credit: Decimal) {
        guard let start = date(year: year, month: month, day: 1),
              let end = Calendar.current.date(byAdding: DateComponents(month: 1, day: -1), to: start)?
                .endOfDay else { return (.zero, .zero) }
        let lines = allLines(for: account, from: start, to: end)
        return (lines.reduce(.zero) { $0 + $1.debit }, lines.reduce(.zero) { $0 + $1.credit })
    }

    /// 本年累计发生额（1月到指定月）
    static func cumulativePeriodBalance(for account: Account, year: Int, month: Int) -> (debit: Decimal, credit: Decimal) {
        guard let start = date(year: year, month: 1, day: 1),
              let end = Calendar.current.date(byAdding: DateComponents(month: 1, day: -1), to: date(year: year, month: month, day: 1)!)
                .map({ $0.endOfDay }) else { return (.zero, .zero) }
        let lines = allLines(for: account, from: start, to: end)
        return (lines.reduce(.zero) { $0 + $1.debit }, lines.reduce(.zero) { $0 + $1.credit })
    }

    // MARK: - 期末结转
    static func closePeriod(for company: Company, year: Int, month: Int) throws {
        let store = DataStore.shared
        // 检查是否已结账
        guard !store.isPeriodClosed(companyID: company.id, year: year, month: month) else {
            throw AccountingError.periodAlreadyClosed
        }
        let accounts = store.accounts(for: company.id)
        guard let profitAccount = accounts.first(where: { $0.code == "4103" }) else {
            throw AccountingError.noProfitAccount
        }
        let closeDate = endOfMonth(year: year, month: month)

        // 结转收入
        let revenueAccounts = accounts.filter { $0.category == .revenue && $0.isActive }
        var revenueLines: [JournalLine] = []
        for acc in revenueAccounts {
            let bal = balance(for: acc, upTo: closeDate)
            if bal != 0 {
                revenueLines.append(makeLine(summary: "结转\(acc.name)", debit: bal, credit: 0, account: acc))
                revenueLines.append(makeLine(summary: "结转收入", debit: 0, credit: bal, account: profitAccount))
            }
        }
        if !revenueLines.isEmpty {
            let entry = JournalEntry(number: "结-\(year)-\(String(format: "%02d", month))-1", date: closeDate, summary: "结转收入类科目", isPosted: true)
            entry.companyID = company.id
            for line in revenueLines { line.entryID = entry.id }
            entry.lines = revenueLines
            store.addEntry(entry)
        }

        // 结转费用
        let expenseAccounts = accounts.filter { $0.category == .expense && $0.isActive }
        var expenseLines: [JournalLine] = []
        for acc in expenseAccounts {
            let bal = balance(for: acc, upTo: closeDate)
            if bal != 0 {
                expenseLines.append(makeLine(summary: "结转\(acc.name)", debit: 0, credit: bal, account: acc))
                expenseLines.append(makeLine(summary: "结转费用", debit: bal, credit: 0, account: profitAccount))
            }
        }
        if !expenseLines.isEmpty {
            let entry = JournalEntry(number: "结-\(year)-\(String(format: "%02d", month))-2", date: closeDate, summary: "结转费用类科目", isPosted: true)
            entry.companyID = company.id
            for line in expenseLines { line.entryID = entry.id }
            entry.lines = expenseLines
            store.addEntry(entry)
        }
    }

    // MARK: - 报表

    static func balanceSheet(for company: Company, asOf date: Date) -> BalanceSheetReport {
        let accts = DataStore.shared.accounts(for: company.id)
        let allActive = accts.filter { $0.isActive }

        let assetLines = allActive.filter { $0.category == .asset }.sorted { $0.code < $1.code }
            .map { BalanceLine(code: $0.code, name: $0.name, balance: balance(for: $0, upTo: date), beginningBalance: beginningBalance(for: $0, asOf: date)) }
        let liabilityLines = allActive.filter { $0.category == .liability }.sorted { $0.code < $1.code }
            .map { BalanceLine(code: $0.code, name: $0.name, balance: balance(for: $0, upTo: date), beginningBalance: beginningBalance(for: $0, asOf: date)) }
        let equityLines = allActive.filter { $0.category == .equity }.sorted { $0.code < $1.code }
            .map { BalanceLine(code: $0.code, name: $0.name, balance: balance(for: $0, upTo: date), beginningBalance: beginningBalance(for: $0, asOf: date)) }

        let currentAssetCodes: Set<String> = ["1001","1002","1101","1121","1122","1123","1131","1132","1133","1221","1401","1402","1403","1404","1405","1406","1407","1408","1411","1421","1431","1441","1451","1461","1471"]
        let currentAssets = assetLines.filter { currentAssetCodes.contains($0.code) }
        let nonCurrentAssets = assetLines.filter { !currentAssetCodes.contains($0.code) }

        let currentLiabilityCodes: Set<String> = ["2001","2101","2201","2202","2203","2211","2221","2231","2232","2241"]
        let currentLiabilities = liabilityLines.filter { currentLiabilityCodes.contains($0.code) }
        let nonCurrentLiabilities = liabilityLines.filter { !currentLiabilityCodes.contains($0.code) }

        return BalanceSheetReport(
            companyName: company.name,
            date: date,
            currency: company.currency,
            currentAssets: currentAssets,
            nonCurrentAssets: nonCurrentAssets,
            currentLiabilities: currentLiabilities,
            nonCurrentLiabilities: nonCurrentLiabilities,
            equities: equityLines
        )
    }

    static func incomeStatement(for company: Company, year: Int, month: Int) -> IncomeStatementReport {
        let accts = DataStore.shared.accounts(for: company.id)
        let allActive = accts.filter { $0.isActive }

        // 收入：基于 category == .revenue，不再硬编码 code
        let revenueLines = allActive.filter { $0.category == .revenue }.sorted { $0.code < $1.code }
            .map { a -> IncomeLine in
                let p = periodBalance(for: a, year: year, month: month)
                let c = cumulativePeriodBalance(for: a, year: year, month: month)
                return IncomeLine(code: a.code, name: a.name, amount: p.credit - p.debit, cumulativeAmount: c.credit - c.debit)
            }

        // 费用：基于 category == .expense，动态分组
        let expenseAccounts = allActive.filter { $0.category == .expense }.sorted { $0.code < $1.code }
        var expenseLines: [IncomeLine] = []
        for a in expenseAccounts {
            let p = periodBalance(for: a, year: year, month: month)
            let c = cumulativePeriodBalance(for: a, year: year, month: month)
            let amt = p.debit - p.credit
            let cum = c.debit - c.credit
            if amt != 0 || cum != 0 {
                expenseLines.append(IncomeLine(code: a.code, name: a.name, amount: amt, cumulativeAmount: cum))
            }
        }

        let totalRevenue = revenueLines.reduce(Decimal.zero) { $0 + $1.amount }
        let revenueCum = revenueLines.reduce(Decimal.zero) { $0 + $1.cumulativeAmount }
        let opExpenseItems = expenseLines.filter { $0.code != "6801" }
        let totalOperatingCost = opExpenseItems.reduce(Decimal.zero) { $0 + $1.amount }
        let costCum = opExpenseItems.reduce(Decimal.zero) { $0 + $1.cumulativeAmount }
        let operatingProfit = totalRevenue - totalOperatingCost
        let operatingCum = revenueCum - costCum
        let incomeTaxAmt = expenseLines.first(where: { $0.code == "6801" })?.amount ?? 0
        let incomeTaxCum = expenseLines.first(where: { $0.code == "6801" })?.cumulativeAmount ?? 0

        return IncomeStatementReport(
            companyName: company.name,
            year: year,
            month: month,
            currency: company.currency,
            revenues: revenueLines,
            expenses: expenseLines,
            operatingProfit: operatingProfit,
            operatingProfitCumulative: operatingCum,
            incomeTax: incomeTaxAmt,
            incomeTaxCumulative: incomeTaxCum
        )
    }

    /// 总分类账 — 按凭证号分组，同凭证号下同科目的分录合并
    static func generalLedger(for account: Account, year: Int, month: Int) -> GeneralLedgerReport {
        guard let start = date(year: year, month: month, day: 1),
              let end = Calendar.current.date(byAdding: DateComponents(month: 1, day: -1), to: start)?.endOfDay else {
            return GeneralLedgerReport(account: account, year: year, month: month, openingBalance: .zero, lines: [])
        }
        let dayBeforeStart = Calendar.current.date(byAdding: .day, value: -1, to: start)!.endOfDay
        let openingBalance = balance(for: account, upTo: dayBeforeStart)
        let lines = allLines(for: account, from: start, to: end)

        // 按 entryID 分组，每个凭证生成一条 GLLine
        var perEntry: [UUID: (debit: Decimal, credit: Decimal, entry: JournalEntry?)] = [:]
        for line in lines {
            guard let eid = line.entryID else { continue }
            if perEntry[eid] == nil {
                let entry = DataStore.shared.journalEntries.first(where: { $0.id == eid })
                perEntry[eid] = (.zero, .zero, entry)
            }
            perEntry[eid]!.debit += line.debit
            perEntry[eid]!.credit += line.credit
        }

        var glLines: [GLLine] = []
        for (_, data) in perEntry {
            guard let entry = data.entry else { continue }
            glLines.append(GLLine(
                date: entry.date,
                voucherNumber: entry.number,
                summary: entry.summary,
                debit: data.debit,
                credit: data.credit
            ))
        }
        glLines.sort { a, b in
            if a.date != b.date { return a.date < b.date }
            return a.voucherNumber < b.voucherNumber
        }

        // 计算累计余额
        var running = openingBalance
        for i in glLines.indices {
            switch account.category.nature {
            case .debit: running += glLines[i].debit - glLines[i].credit
            case .credit: running += glLines[i].credit - glLines[i].debit
            }
            glLines[i].runningBalance = abs(running)
            glLines[i].direction = running >= 0 ? "借" : "贷"
        }

        return GeneralLedgerReport(account: account, year: year, month: month, openingBalance: openingBalance, lines: glLines)
    }

    /// 默认科目表（已存在则不重复创建）
        static func createDefaultAccounts(for companyID: UUID) {
            let store = DataStore.shared
            // BUG-1: 多公司隔离 — 检查该公司已有科目不再重复创建
            let existing = store.accounts(for: companyID)
            guard existing.isEmpty else {
                print("公司 \(companyID) 已有 \(existing.count) 个科目，跳过默认创建")
                return
            }
            let defaultAccounts: [(String, String, AccountCategory)] = [
            ("1001", "库存现金", .asset), ("1002", "银行存款", .asset),
            ("1122", "应收账款", .asset), ("1123", "预付账款", .asset),
            ("1221", "其他应收款", .asset), ("1403", "原材料", .asset),
            ("1405", "库存商品", .asset), ("1601", "固定资产", .asset),
            ("1602", "累计折旧", .asset),
            ("2001", "短期借款", .liability), ("2202", "应付账款", .liability),
            ("2203", "预收账款", .liability), ("2211", "应付职工薪酬", .liability),
            ("2221", "应交税费", .liability), ("2241", "其他应付款", .liability),
            ("2501", "长期借款", .liability),
            ("4001", "实收资本", .equity), ("4103", "本年利润", .equity),
            ("4104", "利润分配", .equity),
            ("5001", "主营业务收入", .revenue), ("5051", "其他业务收入", .revenue),
            ("5111", "投资收益", .revenue),
            ("6001", "主营业务成本", .expense), ("6401", "税金及附加", .expense),
            ("6601", "销售费用", .expense), ("6602", "管理费用", .expense),
            ("6603", "财务费用", .expense), ("6801", "所得税费用", .expense),
        ]
        for (idx, (code, name, cat)) in defaultAccounts.enumerated() {
            let a = Account(code: code, name: name, category: cat, sortOrder: idx)
            a.companyID = companyID
            store.accounts.append(a)
        }
        store.saveAll()
        store.objectWillChange.send()
    }

    // MARK: - BUG-4: 过账/反过账时同步余额
    static func syncBalances(for entry: JournalEntry) {
        // 余额依赖 $0.isPosted 即时计算，此处触发 UI 刷新
        let store = DataStore.shared
        store.objectWillChange.send()
    }

    // MARK: - Private

    private static func allLines(for account: Account, upTo date: Date) -> [JournalLine] {
        DataStore.shared.journalEntries
            .filter { $0.isPosted && $0.date <= date }
            .flatMap { $0.lines }.filter { $0.accountID == account.id }
    }

    private static func allLines(for account: Account, from: Date, to: Date) -> [JournalLine] {
        DataStore.shared.journalEntries
            .filter { $0.isPosted && $0.date >= from && $0.date <= to }
            .flatMap { $0.lines }.filter { $0.accountID == account.id }
    }

    private static func date(year: Int, month: Int, day: Int) -> Date? {
        var c = DateComponents(); c.year = year; c.month = month; c.day = day; return Calendar.current.date(from: c)
    }

    private static func endOfMonth(year: Int, month: Int) -> Date {
        guard let start = date(year: year, month: month, day: 1),
              let end = Calendar.current.date(byAdding: DateComponents(month: 1, day: -1), to: start)?.endOfDay else { return Date() }
        return end
    }

    private static func makeLine(summary: String, debit: Decimal, credit: Decimal, account: Account) -> JournalLine {
        let l = JournalLine(summary: summary, debit: debit, credit: credit)
        l.accountID = account.id
        // 保留 accountCode/accountName 供旧数据兼容，新代码通过 resolvedAccount* 取值
        l.accountCode = account.code; l.accountName = account.name
        return l
    }
}

// MARK: - Extensions
extension Date {
    var endOfDay: Date {
        Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: self) ?? self
    }
}

// MARK: - Report Models
struct BalanceLine: Identifiable {
    let id = UUID()
    let code: String
    let name: String
    let balance: Decimal
    let beginningBalance: Decimal
}

struct BalanceSheetReport {
    let companyName: String
    let date: Date
    let currency: String
    let currentAssets: [BalanceLine]
    let nonCurrentAssets: [BalanceLine]
    let currentLiabilities: [BalanceLine]
    let nonCurrentLiabilities: [BalanceLine]
    let equities: [BalanceLine]

    var allAssets: [BalanceLine] { currentAssets + nonCurrentAssets }
    var allLiabilities: [BalanceLine] { currentLiabilities + nonCurrentLiabilities }

    var totalAssets: Decimal { allAssets.reduce(.zero) { $0 + $1.balance } }
    var totalLiabilities: Decimal { allLiabilities.reduce(.zero) { $0 + $1.balance } }
    var totalEquities: Decimal { equities.reduce(.zero) { $0 + $1.balance } }
    var totalAssetsBeginning: Decimal { allAssets.reduce(.zero) { $0 + $1.beginningBalance } }
    var totalLiabilitiesBeginning: Decimal { allLiabilities.reduce(.zero) { $0 + $1.beginningBalance } }
    var totalEquitiesBeginning: Decimal { equities.reduce(.zero) { $0 + $1.beginningBalance } }
    var totalLE: Decimal { totalLiabilities + totalEquities }
    var totalLEBeginning: Decimal { totalLiabilitiesBeginning + totalEquitiesBeginning }
}

struct IncomeLine: Identifiable {
    let id = UUID()
    let code: String
    let name: String
    let amount: Decimal
    let cumulativeAmount: Decimal
}

struct IncomeStatementReport {
    let companyName: String
    let year: Int
    let month: Int
    let currency: String
    let revenues: [IncomeLine]
    let expenses: [IncomeLine]
    let operatingProfit: Decimal
    let operatingProfitCumulative: Decimal
    let incomeTax: Decimal
    let incomeTaxCumulative: Decimal

    var totalRevenue: Decimal { revenues.reduce(.zero) { $0 + $1.amount } }
    var totalRevenueCumulative: Decimal { revenues.reduce(.zero) { $0 + $1.cumulativeAmount } }
    var totalExpense: Decimal { expenses.reduce(.zero) { $0 + $1.amount } }
    var totalExpenseCumulative: Decimal { expenses.reduce(.zero) { $0 + $1.cumulativeAmount } }
    var netProfit: Decimal { totalRevenue - totalExpense }
    var netProfitCumulative: Decimal { totalRevenueCumulative - totalExpenseCumulative }
}

struct GLLine: Identifiable {
    let id = UUID()
    let date: Date
    let voucherNumber: String
    let summary: String
    var debit: Decimal
    var credit: Decimal
    var runningBalance: Decimal = 0
    var direction: String = "借"
}

struct GeneralLedgerReport {
    let account: Account
    let year: Int
    let month: Int
    let openingBalance: Decimal
    let lines: [GLLine]
    var closingBalance: Decimal {
        lines.last.map { $0.runningBalance } ?? openingBalance
    }
}

enum AccountingError: Error, LocalizedError {
    case noProfitAccount
    case notBalanced
    case alreadyPosted
    case periodAlreadyClosed
    var errorDescription: String? {
        switch self {
        case .noProfitAccount: return "未找到本年利润科目(4103)"
        case .notBalanced: return "借贷不平"
        case .alreadyPosted: return "凭证已过账"
        case .periodAlreadyClosed: return "该期间已结账，不可重复结转"
        }
    }
}
