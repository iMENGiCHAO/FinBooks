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
        // 优先使用余额缓存（如果 date 是月末）
        let cal = Calendar.current
        let ym = cal.component(.year, from: date)
        let mm = cal.component(.month, from: date)
        if let cached = cachedBalance(for: account, year: ym, month: mm) {
            // 返回余额绝对值（确保正数 = 正常方向余额）
            return cached.closing
        }
        // 回退：全量遍历
        let lines = allLines(for: account, upTo: date)
        let totalDebit = lines.reduce(Decimal.zero) { $0 + $1.debit }
        let totalCredit = lines.reduce(Decimal.zero) { $0 + $1.credit }
        switch account.effectiveBalanceDirection {
        case .debit: return totalDebit - totalCredit
        case .credit: return totalCredit - totalDebit
        }
    }

    /// 从余额缓存中获取科目余额（速度 O(1)）
    static func cachedBalance(for account: Account, year: Int, month: Int) -> (opening: Decimal, debit: Decimal, credit: Decimal, closing: Decimal)? {
        guard let cached = DataStore.shared.balanceCache.first(where: {
            $0.accountID == account.id && $0.year == year && $0.month == month
        }) else { return nil }
        return (cached.openingBalance, cached.debitTotal, cached.creditTotal, cached.closingBalance)
    }

    /// 年初余额（上一年12月31日截止）
    static func beginningBalance(for account: Account, asOf date: Date) -> Decimal {
        let cal = Calendar.current
        let year = cal.component(.year, from: date)
        // 优先使用缓存：当年第1个月的期初 = 上年末余额
        if let cached = cachedBalance(for: account, year: year, month: 1) {
            return cached.opening
        }
        guard let prevYearEnd = cal.date(from: DateComponents(year: year - 1, month: 12, day: 31, hour: 23, minute: 59, second: 59)) else {
            return balance(for: account, upTo: date)
        }
        return balance(for: account, upTo: prevYearEnd)
    }

    /// 本期发生额
    static func periodBalance(for account: Account, year: Int, month: Int) -> (debit: Decimal, credit: Decimal) {
        // 优先使用余额缓存
        if let cached = cachedBalance(for: account, year: year, month: month) {
            return (cached.debit, cached.credit)
        }
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
        // 检查前期是否已结账（1月跳过）
        if month > 1 {
            let prevMonth = month - 1
            let prevYear = year
            if !store.isPeriodClosed(companyID: company.id, year: prevYear, month: prevMonth) {
                throw AccountingError.previousPeriodNotClosed
            }
        }
        // BUGFIX: 检查期间内所有凭证是否已过账
        let cal_check = Calendar.current
        guard let periodStart = date(year: year, month: month, day: 1),
              let periodEnd = cal_check.date(byAdding: DateComponents(month: 1, day: -1), to: periodStart)?.endOfDay else {
            throw AccountingError.previousPeriodNotClosed
        }
        let unpostedInPeriod = store.entries(for: company.id).filter {
            $0.date >= periodStart && $0.date <= periodEnd && !$0.isPosted
        }
        guard unpostedInPeriod.isEmpty else {
            throw AccountingError.unpostedEntriesExist(unpostedInPeriod.map(\.number))
        }
        let accounts = store.accounts(for: company.id)
        guard let profitAccount = accounts.first(where: { $0.code == "4103" }) else {
            throw AccountingError.noProfitAccount
        }
        let closeDate = endOfMonth(year: year, month: month)

        // 安全生成结账凭证编号（防编号冲突）
        func safeClosingNumber(seq: Int) -> String {
            let base = "结-\(year)-\(String(format: "%02d", month))-\(seq)"
            let existing = store.journalEntries.filter { $0.number == base }
            if existing.isEmpty { return base }
            var counter = 2
            while store.journalEntries.contains(where: { $0.number == "\(base)-\(counter)" }) {
                counter += 1
            }
            return "\(base)-\(counter)"
        }

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
            let entry = JournalEntry(number: safeClosingNumber(seq: 1), date: closeDate, summary: "结转收入类科目", isPosted: true)
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
            let entry = JournalEntry(number: safeClosingNumber(seq: 2), date: closeDate, summary: "结转费用类科目", isPosted: true)
            entry.companyID = company.id
            for line in expenseLines { line.entryID = entry.id }
            entry.lines = expenseLines
            store.addEntry(entry)
        }

        // 标记期间已结账
        let pc = PeriodClose(year: year, month: month, closedBy: "system", companyID: company.id)
        pc.isClosed = true
        pc.closedAt = Date()
        store.addPeriodClose(pc)

        // 重建余额缓存，确保报表反映结转后的数据
        store.rebuildBalanceCache(for: company.id, year: year, month: month)
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

        let currentLiabilityCodes: Set<String> = ["2001","2101","2201","2202","2203","2211","2221","2221.01","2221.01.01","2221.01.02","2221.01.03","2221.01.04","2231","2232","2241"]
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
            switch account.effectiveBalanceDirection {
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
            ("2221.01", "应交增值税", .liability),
            ("2221.01.01", "进项税额", .liability),
            ("2221.01.02", "销项税额", .liability),
            ("2221.01.03", "进项税额转出", .liability),
            ("2221.01.04", "已交税金", .liability),
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
            if code == "1602" { a.balanceDirection = .credit }
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
    
    // MARK: - 现金流量表（间接法）
    
    /// 生成现金流量表
    static func cashFlowStatement(for company: Company, year: Int, month: Int) -> CashFlowReport {
        let accts = DataStore.shared.accounts(for: company.id)
        let cal = Calendar.current
        guard let startDate = date(year: year, month: month, day: 1),
              let endDate = cal.date(byAdding: DateComponents(month: 1, day: -1), to: startDate)?.endOfDay else {
            return CashFlowReport(companyName: company.name, year: year, period: "\(month)", currency: company.currency,
                                  operatingInflows: [], operatingOutflows: [], investingInflows: [], investingOutflows: [],
                                  financingInflows: [], financingOutflows: [], beginningCash: .zero)
        }
        
        let entries = DataStore.shared.entries(for: company.id)
            .filter { $0.isPosted && $0.date >= startDate && $0.date <= endDate }
        
        // 获取现金科目
        let cashCodes = Set(["1001", "1002"])
        let cashAccounts = accts.filter { cashCodes.contains($0.code) }
        let cashIDs = Set(cashAccounts.map { $0.id })
        
        // 经营活动 — 通过利润表项目倒推
        let revenueCodes = Set(accts.filter { $0.category == .revenue && $0.isActive }.map { $0.id })
        _ = Set(accts.filter { $0.category == .expense && $0.code != "6801" && $0.isActive }.map { $0.id }) // 保留供后续扩展
        
        var operatingIn: [CashFlowLine] = []
        var operatingOut: [CashFlowLine] = []
        var investingIn: [CashFlowLine] = []
        var investingOut: [CashFlowLine] = []
        var financingIn: [CashFlowLine] = []
        var financingOut: [CashFlowLine] = []
        
        /// 根据科目编码前缀判断现金流量分类
        func classifyAccount(_ code: String) -> CashFlowCategory {
            // 投资活动相关科目
            if code.hasPrefix("16") { return .investing }          // 固定资产/累计折旧/在建工程
            if code.hasPrefix("1511") { return .investing }        // 长期股权投资
            if code.hasPrefix("5111") { return .investing }        // 投资收益（实际收到现金时）
            // 筹资活动相关科目
            if code.hasPrefix("2001") { return .financing }        // 短期借款
            if code.hasPrefix("2501") { return .financing }        // 长期借款
            if code.hasPrefix("4001") { return .financing }        // 实收资本
            if code.hasPrefix("4104") { return .financing }        // 利润分配（分红支付）
            if code.hasPrefix("2701") { return .financing }        // 长期应付款
            // 经营活动（包括：应收/应付/收入/成本/费用/税费/存货变动）
            return .operating
        }
        
        for entry in entries {
            var opIn: Decimal = 0
            var opOut: Decimal = 0
            var invIn: Decimal = 0
            var invOut: Decimal = 0
            var finIn: Decimal = 0
            var finOut: Decimal = 0
            
            for line in entry.lines {
                guard let aid = line.accountID else { continue }
                if cashIDs.contains(aid) {
                    if line.debit > 0 { // 现金流入（借方=收到现金）
                        let otherLines = entry.lines.filter { $0.accountID != aid && $0.accountID != nil }
                        // 聚合对方科目分类
                        var categoryScores: [CashFlowCategory: Decimal] = [:]
                        for ol in otherLines {
                            guard let oid = ol.accountID, let oacct = accts.first(where: { $0.id == oid }) else { continue }
                            let cat = classifyAccount(oacct.code)
                            let amount = max(ol.credit, ol.debit)
                            categoryScores[cat, default: 0] += amount
                        }
                        // 选择得分最高的类别
                        let best = categoryScores.max(by: { $0.value < $1.value })
                        switch best?.key {
                        case .investing: invIn += line.debit
                        case .financing: finIn += line.debit
                        default: opIn += line.debit
                        }
                    } else if line.credit > 0 { // 现金流出（贷方=支付现金）
                        let otherLines = entry.lines.filter { $0.accountID != aid && $0.accountID != nil }
                        var categoryScores: [CashFlowCategory: Decimal] = [:]
                        for ol in otherLines {
                            guard let oid = ol.accountID, let oacct = accts.first(where: { $0.id == oid }) else { continue }
                            let cat = classifyAccount(oacct.code)
                            let amount = max(ol.credit, ol.debit)
                            categoryScores[cat, default: 0] += amount
                        }
                        let best = categoryScores.max(by: { $0.value < $1.value })
                        switch best?.key {
                        case .investing: invOut += line.credit
                        case .financing: finOut += line.credit
                        default: opOut += line.credit
                        }
                    }
                } else if revenueCodes.contains(aid) && line.debit > 0 {
                    // 销售收入没收到现金（应收账款增加 = 经营现金占用）
                    opOut += line.debit
                }
            }
            
            if opIn > 0 { operatingIn.append(CashFlowLine(name: entry.summary, amount: opIn)) }
            if opOut > 0 { operatingOut.append(CashFlowLine(name: entry.summary, amount: opOut)) }
            if invIn > 0 { investingIn.append(CashFlowLine(name: entry.summary, amount: invIn)) }
            if invOut > 0 { investingOut.append(CashFlowLine(name: entry.summary, amount: invOut)) }
            if finIn > 0 { financingIn.append(CashFlowLine(name: entry.summary, amount: finIn)) }
            if finOut > 0 { financingOut.append(CashFlowLine(name: entry.summary, amount: finOut)) }
        }
        
        // 期初现金
        let dayBeforeStart = cal.date(byAdding: .day, value: -1, to: startDate)!.endOfDay
        let beginningCash = cashAccounts.reduce(Decimal.zero) { $0 + balance(for: $1, upTo: dayBeforeStart) }
        
        return CashFlowReport(
            companyName: company.name,
            year: year,
            period: "\(year)年\(month)月",
            currency: company.currency,
            operatingInflows: operatingIn,
            operatingOutflows: operatingOut,
            investingInflows: investingIn,
            investingOutflows: investingOut,
            financingInflows: financingIn,
            financingOutflows: financingOut,
            beginningCash: beginningCash
        )
    }
    
    // MARK: - 增值税申报表
    
    /// 生成增值税申报表（按期间汇总进销项）
    static func vatReport(for company: Company, year: Int, month: Int) -> VATReport {
        let store = DataStore.shared
        let accts = store.accounts(for: company.id)
        let cal = Calendar.current
        guard let startDate = date(year: year, month: month, day: 1),
              let endDate = cal.date(byAdding: DateComponents(month: 1, day: -1), to: startDate)?.endOfDay else {
            return VATReport(companyName: company.name, year: year, month: month, inputTotal: 0, outputTotal: 0, transferOutTotal: 0, deductible: 0, payable: 0, alreadyPaid: 0, stillDue: 0, inputDetails: [], outputDetails: [], rateBreakdown: [])
        }
        
        let entries = store.entries(for: company.id)
            .filter { $0.isPosted && $0.date >= startDate && $0.date <= endDate }
        
        // 找增值税科目ID
        func findAccount(code: String) -> Account? { accts.first { $0.code == code } }
        let inputTaxID = findAccount(code: "2221.01.01")?.id
        let outputTaxID = findAccount(code: "2221.01.02")?.id
        let transferOutID = findAccount(code: "2221.01.03")?.id
        let paidTaxID = findAccount(code: "2221.01.04")?.id
        
        var inputTotal: Decimal = 0
        var outputTotal: Decimal = 0
        var transferOutTotal: Decimal = 0
        var paidTotal: Decimal = 0
        var inputDetails: [VATDetailLine] = []
        var outputDetails: [VATDetailLine] = []
        var rateBreakdown: [VATRateLine] = []
        var rateBuckets: [Double: (input: Decimal, output: Decimal)] = [:]
        
        for entry in entries {
            for line in entry.lines {
                guard let aid = line.accountID else { continue }
                if aid == inputTaxID {
                    inputTotal += line.debit
                    inputDetails.append(VATDetailLine(
                        voucherNumber: entry.number, summary: entry.summary,
                        amount: line.debit, taxRate: line.vatRate, accountName: "进项税额"))
                    // 按税率汇总
                    let r = line.vatRate
                    rateBuckets[r, default: (.zero, .zero)].input += line.debit
                }
                if aid == outputTaxID {
                    outputTotal += line.credit
                    outputDetails.append(VATDetailLine(
                        voucherNumber: entry.number, summary: entry.summary,
                        amount: line.credit, taxRate: line.vatRate, accountName: "销项税额"))
                    let r = line.vatRate
                    rateBuckets[r, default: (.zero, .zero)].output += line.credit
                }
                if aid == transferOutID {
                    transferOutTotal += line.credit
                }
                if aid == paidTaxID {
                    paidTotal += line.debit
                }
            }
        }
        
        // 按税率生成明细行
        for (rate, amounts) in rateBuckets.sorted(by: { $0.key > $1.key }) {
            rateBreakdown.append(VATRateLine(rate: rate, inputAmount: amounts.input, outputAmount: amounts.output))
        }
        
        let deductible = inputTotal + transferOutTotal
        let payable = max(outputTotal - deductible, 0)
        let alreadyPaid = paidTotal
        
        return VATReport(
            companyName: company.name,
            year: year,
            month: month,
            inputTotal: inputTotal,
            outputTotal: outputTotal,
            transferOutTotal: transferOutTotal,
            deductible: deductible,
            payable: payable,
            alreadyPaid: alreadyPaid,
            stillDue: max(payable - alreadyPaid, 0),
            inputDetails: inputDetails,
            outputDetails: outputDetails,
            rateBreakdown: rateBreakdown
        )
    }
    
    // MARK: - T 型账户数据
    
    /// 获取单个科目的 T 型账户数据
    static func tAccount(for account: Account, year: Int, month: Int) -> TAccountData {
        let cal = Calendar.current
        guard let start = date(year: year, month: month, day: 1),
              let end = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start)?.endOfDay else {
            return TAccountData(account: account, period: "", openingBalance: .zero, debitEntries: [], creditEntries: [])
        }
        
        let allEntries = DataStore.shared.entries(for: account.companyID ?? UUID())
            .filter { $0.isPosted && $0.date >= start && $0.date <= end }
        
        var debitEntries: [(voucherNumber: String, summary: String, amount: Decimal)] = []
        var creditEntries: [(voucherNumber: String, summary: String, amount: Decimal)] = []
        
        for entry in allEntries {
            for line in entry.lines where line.accountID == account.id {
                if line.debit > 0 {
                    debitEntries.append((entry.number, entry.summary, line.debit))
                }
                if line.credit > 0 {
                    creditEntries.append((entry.number, entry.summary, line.credit))
                }
            }
        }
        
        let dayBefore = cal.date(byAdding: .day, value: -1, to: start)!.endOfDay
        let opening = balance(for: account, upTo: dayBefore)
        
        return TAccountData(
            account: account,
            period: "\(year)年\(month)月",
            openingBalance: opening,
            debitEntries: debitEntries,
            creditEntries: creditEntries
        )
    }
    
    // MARK: - 固定资产折旧引擎
    
    /// 计算单项固定资产月折旧额
    static func monthlyDepreciation(for asset: FixedAsset) -> Decimal {
        let depreciableBase = asset.originalValue - asset.residualValue
        guard depreciableBase > 0, asset.usefulLife > 0 else { return 0 }
        
        switch asset.depreciationMethod {
        case .straightLine:
            return depreciableBase / Decimal(asset.usefulLife)
        case .doubleDeclining:
            let monthlyRate = 2.0 / Double(asset.usefulLife)
            let netValue = asset.originalValue - asset.accumulatedDepreciation
            let depreciation = Decimal(Double(NSDecimalNumber(decimal: netValue).doubleValue) * monthlyRate)
            let straightLineRemaining = depreciableBase / Decimal(max(1, asset.usefulLife - monthsUsed(asset)))
            return min(depreciation, max(straightLineRemaining, 0))
        }
    }
    
    /// 计算已使用月数（到指定日期为止，默认当前日期）
    static func monthsUsed(_ asset: FixedAsset, asOf date: Date = Date()) -> Int {
        let cal = Calendar.current
        let start = asset.startDepreciationDate
        let components = cal.dateComponents([.month], from: start, to: date)
        return max(0, components.month ?? 0)
    }
    
    /// 生成折旧凭证
    static func generateDepreciationEntry(for asset: FixedAsset, companyID: UUID) -> JournalEntry? {
        let depAmount = monthlyDepreciation(for: asset)
        guard depAmount > 0,
              let depAccountID = asset.depreciationAccountID,
              let expenseAccountID = asset.expenseAccountID else { return nil }
        
        let now = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        
        // 检查本月是否已计提
        let prefix = "折-\(year)-\(String(format: "%02d", month))"
        let existing = DataStore.shared.journalEntries.filter {
            $0.number.hasPrefix(prefix) && $0.companyID == companyID &&
            $0.lines.contains(where: { $0.accountID == expenseAccountID })
        }
        if !existing.isEmpty {
            print("⚠️ 本月已对资产 \(asset.name) 计提折旧")
            return nil
        }
        
        let entry = JournalEntry(
            number: "\(prefix)-\(DataStore.shared.journalEntries.filter { $0.number.hasPrefix(prefix) }.count + 1)",
            date: now,
            summary: "计提\(asset.name)折旧"
        )
        entry.companyID = companyID
        
        let line1 = JournalLine()
        line1.accountID = expenseAccountID
        line1.debit = depAmount
        line1.entryID = entry.id
        line1.summary = "折旧费用"
        
        let line2 = JournalLine()
        line2.accountID = depAccountID
        line2.credit = depAmount
        line2.entryID = entry.id
        line2.summary = "累计折旧"
        
        entry.lines = [line1, line2]
        return entry
    }
    
    /// 批量生成所有活跃资产的折旧凭证
    static func generateAllDepreciationEntries(companyID: UUID) -> [JournalEntry] {
        let assets = DataStore.shared.fixedAssets.filter {
            $0.companyID == companyID && $0.status == .active
        }
        var entries: [JournalEntry] = []
        for asset in assets {
            if let entry = generateDepreciationEntry(for: asset, companyID: companyID) {
                DataStore.shared.journalEntries.append(entry)
                DataStore.shared.saveAll()
                entries.append(entry)
            }
        }
        return entries
    }
}

// MARK: - T 型账户模型
struct TAccountData: Identifiable {
    let id = UUID()
    let account: Account
    let period: String
    let openingBalance: Decimal
    
    let debitEntries: [(voucherNumber: String, summary: String, amount: Decimal)]
    let creditEntries: [(voucherNumber: String, summary: String, amount: Decimal)]
    
    var totalDebit: Decimal { debitEntries.reduce(.zero) { $0 + $1.amount } }
    var totalCredit: Decimal { creditEntries.reduce(.zero) { $0 + $1.amount } }
    
    var closingBalance: Decimal {
        switch account.effectiveBalanceDirection {
        case .debit: return openingBalance + totalDebit - totalCredit
        case .credit: return openingBalance + totalCredit - totalDebit
        }
    }
    
    var closingDirection: String {
        let dir = account.effectiveBalanceDirection
        return closingBalance >= 0 ? (dir == .debit ? "借" : "贷") : (dir == .debit ? "贷" : "借")
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

// MARK: - 现金流量表

/// 现金流量分类
enum CashFlowCategory {
    case operating
    case investing
    case financing
}

struct CashFlowReport {
    let companyName: String
    let year: Int
    let period: String  // "Q1", "H1", "YTD", "M1"...
    let currency: String
    
    // 经营活动
    let operatingInflows: [CashFlowLine]
    let operatingOutflows: [CashFlowLine]
    var operatingNet: Decimal { operatingInflowsTotal - operatingOutflowsTotal }
    var operatingInflowsTotal: Decimal { operatingInflows.reduce(.zero) { $0 + $1.amount } }
    var operatingOutflowsTotal: Decimal { operatingOutflows.reduce(.zero) { $0 + $1.amount } }
    
    // 投资活动
    let investingInflows: [CashFlowLine]
    let investingOutflows: [CashFlowLine]
    var investingNet: Decimal { investingInflowsTotal - investingOutflowsTotal }
    var investingInflowsTotal: Decimal { investingInflows.reduce(.zero) { $0 + $1.amount } }
    var investingOutflowsTotal: Decimal { investingOutflows.reduce(.zero) { $0 + $1.amount } }
    
    // 筹资活动
    let financingInflows: [CashFlowLine]
    let financingOutflows: [CashFlowLine]
    var financingNet: Decimal { financingInflowsTotal - financingOutflowsTotal }
    var financingInflowsTotal: Decimal { financingInflows.reduce(.zero) { $0 + $1.amount } }
    var financingOutflowsTotal: Decimal { financingOutflows.reduce(.zero) { $0 + $1.amount } }
    
    var netCashFlow: Decimal { operatingNet + investingNet + financingNet }
    
    // 期初期末现金
    let beginningCash: Decimal
    var endingCash: Decimal { beginningCash + netCashFlow }
}

struct CashFlowLine: Identifiable {
    let id = UUID()
    let name: String
    let amount: Decimal
}

// MARK: - 增值税申报表
struct VATReport {
    let companyName: String
    let year: Int
    let month: Int
    
    let inputTotal: Decimal          // 进项税额合计
    let outputTotal: Decimal         // 销项税额合计
    let transferOutTotal: Decimal    // 进项税额转出
    let deductible: Decimal          // 可抵扣税额
    let payable: Decimal             // 应纳增值税
    let alreadyPaid: Decimal         // 已预缴
    let stillDue: Decimal            // 应补/退税额
    
    let inputDetails: [VATDetailLine]
    let outputDetails: [VATDetailLine]
    let rateBreakdown: [VATRateLine]
    
    var period: String { "\(year)年\(month)月" }
}

struct VATDetailLine: Identifiable {
    let id = UUID()
    let voucherNumber: String
    let summary: String
    let amount: Decimal
    let taxRate: Double
    let accountName: String
    
    var rateDisplay: String {
        taxRate > 0 ? "\(Int(taxRate * 100))%" : "-"
    }
}

struct VATRateLine: Identifiable {
    let id = UUID()
    let rate: Double
    let inputAmount: Decimal
    let outputAmount: Decimal
    
    var rateDisplay: String { "\(Int(rate * 100))%" }
}

extension AccountingEngine {

    // MARK: - 试算平衡表

    /// 获取试算平衡表 — 所有科目的期末借方/贷方汇总
    static func trialBalance(year: Int, month: Int) -> [(account: Account, debit: Decimal, credit: Decimal)] {
        let accounts = DataStore.shared.accounts.filter(\.isActive)
        var result: [(Account, Decimal, Decimal)] = []

        let cal = Calendar.current
        guard let periodStart = AccountingEngine.date(year: year, month: month, day: 1),
              let periodEnd = cal.date(byAdding: DateComponents(month: 1, day: -1), to: periodStart)?.endOfDay else {
            return []
        }

        for account in accounts {
            let entries = DataStore.shared.entries(for: account.companyID ?? UUID())
                .filter { $0.isPosted && $0.date >= periodStart && $0.date <= periodEnd }

            var totalDebit: Decimal = 0
            var totalCredit: Decimal = 0

            for entry in entries {
                for line in entry.lines where line.accountCode == account.code {
                    totalDebit += line.debit
                    totalCredit += line.credit
                }
            }

            // 累积期初余额（年初到上期末）
            let priorEntries = DataStore.shared.entries(for: account.companyID ?? UUID())
                .filter { $0.isPosted && $0.date < periodStart }

            var priorDebit: Decimal = 0
            var priorCredit: Decimal = 0
            for entry in priorEntries {
                for line in entry.lines where line.accountCode == account.code {
                    priorDebit += line.debit
                    priorCredit += line.credit
                }
            }

            // 根据科目性质计算期末方向
            var endingDebit: Decimal = 0
            var endingCredit: Decimal = 0
            let opening = (priorDebit - priorCredit) * (account.effectiveBalanceDirection == .debit ? 1 : -1)
            if account.effectiveBalanceDirection == .debit {
                let net = opening + totalDebit - totalCredit
                if net >= 0 {
                    endingDebit = net
                } else {
                    endingCredit = -net
                }
            } else {
                let net = opening + totalCredit - totalDebit
                if net >= 0 {
                    endingCredit = net
                } else {
                    endingDebit = -net
                }
            }

            result.append((account, endingDebit, endingCredit))
        }

        return result
    }

    // MARK: - 账龄分析

    /// 获取应收/应付账龄分析报告
    static func agingReport(type: AgingType, asOf date: Date = Date()) -> [(period: String, amount: Decimal, percentage: Double)] {
        let store = DataStore.shared
        let code: String

        switch type {
        case .receivable:
            code = "1122" // 应收账款
        case .payable:
            code = "2202" // 应付账款
        }

        let accounts = store.accounts.filter { $0.code.hasPrefix(code.prefix(4)) && $0.isActive }
        guard !accounts.isEmpty else { return [] }

        // 查找所有涉及该科目的已过账凭证
        var balanceByAge: [Int: Decimal] = [0: 0, 1: 0, 2: 0, 3: 0] // 0-30, 31-60, 61-90, 90+
        var totalBalance: Decimal = 0

        for account in accounts {
            let bal = AccountingEngine.balance(for: account)
            if bal == 0 { continue }
            totalBalance += bal

            let entries = store.entries(for: account.companyID ?? UUID())
                .filter { $0.isPosted }
                .sorted { $0.date < $1.date }

            // 按凭证日期分摊余额到各账龄段
            var remaining = bal
            for entry in entries {
                if remaining <= 0 { break }
                let daysDiff = Calendar.current.dateComponents([.day], from: entry.date, to: date).day ?? 0
                let entryBal = entry.lines
                    .filter { $0.accountCode == account.code }
                    .reduce(Decimal.zero) { $0 + $1.debit - $1.credit }

                let allocated = min(abs(entryBal), abs(remaining))
                let bucket: Int
                if daysDiff <= 30 {
                    bucket = 0
                } else if daysDiff <= 60 {
                    bucket = 1
                } else if daysDiff <= 90 {
                    bucket = 2
                } else {
                    bucket = 3
                }
                balanceByAge[bucket, default: 0] += allocated
                remaining -= allocated * (remaining >= 0 ? 1 : -1)
            }
        }

        let absTotal = abs(totalBalance)
        let periods = ["0-30天", "31-60天", "61-90天", "90天以上"]
        return periods.enumerated().map { i, period in
            let amount = balanceByAge[i] ?? 0
            let pct = absTotal > 0 ? Double(truncating: (amount / absTotal) as NSDecimalNumber) * 100 : 0
            return (period: period, amount: amount, percentage: pct)
        }
    }

    enum AgingType {
        case receivable
        case payable
    }

enum AccountingError: Error, LocalizedError {
    case noProfitAccount
    case notBalanced
    case alreadyPosted
    case previousPeriodNotClosed
    case periodAlreadyClosed
    case unpostedEntriesExist([String])
    var errorDescription: String? {
        switch self {
        case .noProfitAccount: return "未找到本年利润科目(4103)"
        case .notBalanced: return "借贷不平"
        case .alreadyPosted: return "凭证已过账"
        case .previousPeriodNotClosed: return "前期未结账，请先结账上一期间"
        case .periodAlreadyClosed: return "该期间已结账，不可重复结转"
        case .unpostedEntriesExist(let numbers): return "期间内存在未过账凭证: \(numbers.joined(separator: ", "))，请先过账"
        }
    }
}
}
