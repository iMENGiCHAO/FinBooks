import SwiftUI

// MARK: - 智能期间结转向导

struct PeriodCloseView: View {
    let company: Company
    @EnvironmentObject var dataStore: DataStore
    @State private var selectedYear = Calendar.current.component(.year, from: Date())
    @State private var selectedMonth = Calendar.current.component(.month, from: Date())
    @State private var showConfirm = false
    @State private var showUncloseConfirm = false
    @State private var showResult = false
    @State private var resultMessage = ""
    @State private var isSuccess = false
    
    @State private var checkResults: [CloseCheckItem] = []
    @State private var isChecking = false
    @State private var previewVouchers: [String] = []
    @State private var showExportAlert = false
    @State private var exportAlertMessage = ""
    @State private var exportPath = ""

    private var isClosed: Bool {
        dataStore.isPeriodClosed(companyID: company.id, year: selectedYear, month: selectedMonth)
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerArea
                periodSelector
                
                if isClosed, let pc = findClosedPeriod() {
                    closedInfo(pc: pc)
                }
                
                if !checkResults.isEmpty && !isClosed {
                    checkResultsView
                }
                if !previewVouchers.isEmpty && !isClosed {
                    previewView
                }
                if !isClosed {
                    plSummaryView
                    actionButton
                }
                closedPeriodsSection
            }
            .padding(.vertical)
        }
        .frame(minHeight: 550)
        // 所有 alert 都放在 body 级别的 modifier 链上
        .alert("确认结账", isPresented: $showConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认结账", role: .destructive) { doClose() }
        } message: {
            Text("将执行 \(selectedYear)年\(selectedMonth)月的期末结账。\n此操作不可逆，已检查所有项目，是否继续？")
        }
        .alert("确认反结账", isPresented: $showUncloseConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认反结账", role: .destructive) {
                if let pc = findClosedPeriod() { doUnclose(pc) }
            }
        } message: {
            Text("将撤销 \(selectedYear)年\(selectedMonth)月的结账，并删除该期间生成的结转凭证。\n此操作不可逆，是否继续？")
        }
        .alert("审计导出", isPresented: $showExportAlert) {
            Button("确定") {
                if !exportPath.isEmpty {
                    NSWorkspace.shared.selectFile(exportPath, inFileViewerRootedAtPath: "")
                }
            }
        } message: {
            Text(exportAlertMessage)
        }
        .alert(isSuccess ? "结账成功" : "结账失败", isPresented: $showResult) {
            Button("确定") {}
        } message: {
            Text(resultMessage)
        }
    }
    
    // MARK: - 子视图
    
    private var headerArea: some View {
        HStack {
            Image(systemName: isClosed ? "checkmark.seal.fill" : "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(isClosed ? .green : .blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("智能期末结账")
                    .font(.largeTitle.bold())
                Text("系统自动检查凭证完整性、生成结转凭证")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
    }
    
    private var periodSelector: some View {
        HStack(spacing: 16) {
            Picker("年份", selection: $selectedYear) {
                ForEach(availableYears, id: \.self) { y in
                    Text("\(String(y))年").tag(y)
                }
            }
            .frame(width: 120)
            
            Picker("月份", selection: $selectedMonth) {
                ForEach(1...12, id: \.self) { m in
                    Text("\(String(m))月").tag(m)
                }
            }
            .frame(width: 100)
            
            if !isClosed {
                Button("检查期间") { runChecks() }
                    .buttonStyle(.bordered)
            }
            
            Spacer()
            
            if isClosed {
                Label("该期间已结账", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            }
        }
        .padding(.horizontal)
    }
    
    private func closedInfo(pc: PeriodClose) -> some View {
        HStack {
            Label("结账时间: \(FMT.date(pc.closedAt ?? Date(), format: "yyyy-MM-dd HH:mm"))", systemImage: "clock")
            Text("经办人: \(pc.closedBy)")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
    }
    
    private func findClosedPeriod() -> PeriodClose? {
        dataStore.periodCloses.first {
            $0.companyID == company.id && $0.year == selectedYear && $0.month == selectedMonth && $0.isClosed
        }
    }
    
    private var checkResultsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("期间检查结果").font(.headline)
            ForEach(checkResults) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(item.passed ? .green : (item.isWarning ? .orange : .red))
                    Text(item.message).font(.subheadline)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(item.passed ? Color.green.opacity(0.06) : (item.isWarning ? Color.orange.opacity(0.06) : Color.red.opacity(0.06)))
                )
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal)
    }
    
    private var previewView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("结转凭证预览").font(.headline)
            ForEach(previewVouchers, id: \.self) { v in
                Text(v)
                    .font(.subheadline.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal)
    }
    
    private var plSummaryView: some View {
        let pl = buildProfitLossSummary()
        guard !pl.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                Text("当期损益汇总").font(.headline)
                ForEach(pl, id: \.0) { (name, amount) in
                    HStack {
                        Text(name).font(.subheadline)
                        Spacer()
                        Text("¥\(FMT.amount(amount))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(amount >= 0 ? (amount > 0 ? .green : .secondary) : .red)
                    }
                    Divider()
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
        )
    }
    
    private var actionButton: some View {
        let allPassed = checkResults.isEmpty || checkResults.allSatisfy { $0.passed || $0.isWarning }
        return VStack(spacing: 12) {
            Button {
                if checkResults.isEmpty { runChecks() }
                showConfirm = true
            } label: {
                Label("执行结账", systemImage: "lock")
                    .padding(.horizontal, 40)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(allPassed ? .red : .gray)
            .disabled(!allPassed)
            
            if !allPassed && !checkResults.isEmpty {
                Text("存在严重问题，请修复后再结账")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
    
    @ViewBuilder private var closedPeriodsSection: some View {
        let closedPeriods = dataStore.periodCloses
            .filter { $0.companyID == company.id && $0.isClosed }
            .sorted { ($0.year, $0.month) > ($1.year, $1.month) }
        if !closedPeriods.isEmpty {
            Divider().padding(.horizontal)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("结账历史").font(.headline)
                    Spacer()
                    // 反结账按钮：仅最近已结账期间可操作
                    if closedPeriods.first != nil {
                        let nextPeriodExists = closedPeriods.count > 1 && closedPeriods[0].year == closedPeriods[1].year && closedPeriods[0].month == closedPeriods[1].month + 1
                        if !nextPeriodExists {
                            Button(role: .destructive) {
                                showUncloseConfirm = true
                            } label: {
                                Label("反结账", systemImage: "lock.open")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .disabled(showUncloseConfirm) // 防止重复点击
                        }
                    }
                    
                    // 导出审计报告
                    Button {
                        exportAuditCSV()
                    } label: {
                        Label("导出审计报告", systemImage: "square.and.arrow.up")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("导出 CSV 格式审计报告，供税务/审计使用")
                }
                ForEach(closedPeriods.prefix(12)) { pc in
                    HStack {
                        Image(systemName: "checkmark.seal").foregroundStyle(.green).font(.caption)
                        Text("\(String(pc.year))年\(String(pc.month))月")
                        Spacer()
                        if let ct = pc.closedAt {
                            Text(FMT.date(ct, format: "MM-dd HH:mm"))
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .font(.subheadline)
                }
            }
            .padding()
            .frame(maxWidth: 300)
        }
    }
    
    private var availableYears: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 5)...current)
    }
    
    // MARK: - 审计导出（CSV 格式，供税务/审计使用）
    private func exportAuditCSV() {
        let fm = FileManager.default
        let closedPeriods = dataStore.periodCloses
            .filter { $0.companyID == company.id && $0.isClosed }
            .sorted { ($0.year, $0.month) > ($1.year, $1.month) }
        
        guard let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            exportAlertMessage = "无法访问桌面目录"
            showExportAlert = true
            return
        }
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = desktop.appendingPathComponent("FinBooks_审计报告_\(company.name)_\(timestamp).csv")
        
        var csvLines = ["期间,结账时间,经办人,凭证总数,已过账,未过账,不平衡,审计状态"]
        
        for pc in closedPeriods {
            let entries = dataStore.entries(for: company.id).filter { e in
                let cal = Calendar.current
                let ey = cal.component(.year, from: e.date)
                let em = cal.component(.month, from: e.date)
                return ey == pc.year && em == pc.month
            }
            let posted = entries.filter { $0.isPosted }.count
            let unposted = entries.count - posted
            let unbalanced = entries.filter { !$0.isBalanced }.count
            let closedAtStr = FMT.date(pc.closedAt ?? Date(), format: "yyyy-MM-dd HH:mm")
            let auditStatus = unposted == 0 && unbalanced == 0 ? "合规" : "警告"
            csvLines.append("\(pc.year)-\(String(format: "%02d", pc.month)),\(closedAtStr),\(pc.closedBy),\(entries.count),\(posted),\(unposted),\(unbalanced),\(auditStatus)")
        }
        
        csvLines.append("")
        csvLines.append("--- 审计日志 ---")
        csvLines.append("时间,操作,详情,实体ID,实体类型")
        let auditLogs = dataStore.auditLogs
            .filter { $0.companyID == company.id }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(100)
        for log in auditLogs {
            let ts = FMT.date(log.timestamp, format: "yyyy-MM-dd HH:mm:ss")
            csvLines.append("\(ts),\(log.action),\(log.detail),\(log.entityID ?? ""),\(log.entityType ?? "")")
        }
        
        do {
            try csvLines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            exportPath = fileURL.path
            exportAlertMessage = "✅ 审计报告已导出到:\n\(fileURL.path)\n\n可直接导入 Excel / 税务软件 / 审计系统"
        } catch {
            exportAlertMessage = "❌ 导出失败: \(error.localizedDescription)"
        }
        showExportAlert = true
    }
    
    private func runChecks() {
        isChecking = true
        checkResults = []
        previewVouchers = []
        
        var results: [CloseCheckItem] = []
        let entries = dataStore.entries(for: company.id)
        let cal = Calendar.current
        guard let start = date(year: selectedYear, month: selectedMonth, day: 1) else {
            results.append(CloseCheckItem(passed: false, isWarning: false, message: "❌ 日期计算错误"))
            checkResults = results
            isChecking = false
            return
        }
        let end = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start)?.endOfDay ?? start
        
        let periodEntries = entries.filter { $0.date >= start && $0.date <= end }
        let unposted = periodEntries.filter { !$0.isPosted }
        results.append(CloseCheckItem(
            passed: unposted.isEmpty, isWarning: false,
            message: unposted.isEmpty ? "✅ 所有凭证已过账（共\(periodEntries.count)张）" : "❌ 有 \(unposted.count) 张凭证未过账"))
        
        let unbalanced = periodEntries.filter { !$0.isBalanced && $0.isPosted }
        results.append(CloseCheckItem(
            passed: unbalanced.isEmpty, isWarning: false,
            message: unbalanced.isEmpty ? "✅ 所有凭证借贷平衡" : "❌ 有 \(unbalanced.count) 张凭证借贷不平"))
        
        if selectedMonth > 1 {
            let prevClosed = dataStore.isPeriodClosed(companyID: company.id, year: selectedYear, month: selectedMonth - 1)
            results.append(CloseCheckItem(
                passed: prevClosed, isWarning: false,
                message: prevClosed ? "✅ 上月（\(selectedMonth-1)月）已结账" : "❌ 上月（\(selectedMonth-1)月）尚未结账"))
        } else {
            results.append(CloseCheckItem(passed: true, isWarning: false, message: "✅ 本年首个期间，无需检查上月"))
        }
        
        let largeThreshold = Decimal(100000)
        let largeEntries = periodEntries.filter { $0.debitTotal > largeThreshold }
        results.append(CloseCheckItem(
            passed: largeEntries.isEmpty, isWarning: true,
            message: largeEntries.isEmpty ? "✅ 无大额异常凭证" : "⚠️ 有 \(largeEntries.count) 张大额凭证（>¥\(FMT.amount(largeThreshold))），请确认"))
        
        let accts = dataStore.accounts(for: company.id)
        let revAccts = accts.filter { $0.isActive && $0.category == .revenue }
        let expAccts = accts.filter { $0.isActive && $0.category == .expense && $0.code != "6801" }
        var hasPLBalance = false
        var plLines: [(String, Decimal)] = []
        for a in revAccts {
            let bal = AccountingEngine.balance(for: a, upTo: end)
            if bal != 0 { hasPLBalance = true; plLines.append(("\(a.code) \(a.name)", bal)) }
        }
        for a in expAccts {
            let bal = AccountingEngine.balance(for: a, upTo: end)
            if bal != 0 { hasPLBalance = true; plLines.append(("\(a.code) \(a.name)", bal * -1)) }
        }
        results.append(CloseCheckItem(
            passed: hasPLBalance, isWarning: false,
            message: hasPLBalance ? "✅ 损益类科目有余额（\(plLines.count)个科目），将结转至本年利润" : "❌ 损益类科目余额为零"))
        
        if hasPLBalance {
            var previewLines: [String] = []
            let netProfit = plLines.reduce(Decimal.zero) { $0 + $1.1 }
            for (name, amount) in plLines {
                previewLines.append("  \(amount > 0 ? "借" : "贷"): \(name) ¥\(FMT.amount(abs(amount)))")
            }
            previewLines.append("  结转至本年利润¥\(FMT.amount(abs(netProfit)))")
            previewVouchers = ["【损益结转凭证 \(selectedYear)年\(selectedMonth)月】"] + previewLines
        }
        
        checkResults = results
        isChecking = false
    }
    
    private func buildProfitLossSummary() -> [(String, Decimal)] {
        guard !isClosed else { return [] }
        let cal = Calendar.current
        guard let startDate = date(year: selectedYear, month: selectedMonth, day: 1) else { return [] }
        let endDate = cal.date(byAdding: DateComponents(month: 1, day: -1), to: startDate)?.endOfDay ?? startDate
        
        let accts = dataStore.accounts(for: company.id)
        var result: [(String, Decimal)] = []
        let revAccts = accts.filter { $0.isActive && $0.category == .revenue }
        let expAccts = accts.filter { $0.isActive && $0.category == .expense && $0.code != "6801" }
        var totalRev: Decimal = 0
        var totalExp: Decimal = 0
        
        for a in revAccts {
            let bal = AccountingEngine.balance(for: a, upTo: endDate)
            if bal != 0 { result.append(("收入-\(a.name)", bal)); totalRev += bal }
        }
        for a in expAccts {
            let bal = AccountingEngine.balance(for: a, upTo: endDate)
            if bal != 0 { result.append(("费用-\(a.name)", bal * -1)); totalExp += bal }
        }
        result.append(("--------", 0))
        result.append(("利润（收入-费用）", totalRev - totalExp))
        return result
    }
    
    private func doClose() {
        do {
            try AccountingEngine.closePeriod(for: company, year: selectedYear, month: selectedMonth)
            // 记录审计日志
            dataStore.addAuditLog(action: "period_close",
                                  detail: "期末结账: \(selectedYear)年\(selectedMonth)月",
                                  entityID: company.id.uuidString,
                                  entityType: "Company")
            resultMessage = "\(selectedYear)年\(selectedMonth)月结账完成！\n损益类科目已结转至本年利润。"
            isSuccess = true
        } catch {
            resultMessage = "结账失败: \(error.localizedDescription)"
            isSuccess = false
        }
        showResult = true
    }
    
    private func doUnclose(_ pc: PeriodClose) {
        let prefix = "结-\(pc.year)-\(String(format: "%02d", pc.month))-"
        let closeVouchers = dataStore.journalEntries.filter { $0.number.hasPrefix(prefix) && $0.companyID == company.id }
        for v in closeVouchers {
            if v.isPosted {
                _ = dataStore.togglePosted(v, reason: "反结账撤销")
            }
            dataStore.journalEntries.removeAll { $0.id == v.id }
        }
        dataStore.balanceCache.removeAll { cached in
            cached.year == pc.year && cached.month == pc.month
        }
        dataStore.rebuildBalanceCache(for: company.id, year: pc.year, month: pc.month)
        pc.isClosed = false
        pc.closedAt = nil
        dataStore.addPeriodClose(pc)
        // 记录审计日志
        dataStore.addAuditLog(action: "period_unclose",
                              detail: "反结账: \(pc.year)年\(pc.month)月 (删除\(closeVouchers.count)张结转凭证)",
                              entityID: company.id.uuidString,
                              entityType: "Company")
        dataStore.saveAll()
        resultMessage = """
已撤销 \(pc.year)年\(pc.month)月的结账，删除了 \(closeVouchers.count) 张结转凭证。
余额缓存已重建。
"""
        isSuccess = true
        showResult = true
    }
    
    // MARK: - 私有辅助方法
    private func date(year: Int, month: Int, day: Int) -> Date? {
        var dc = DateComponents()
        dc.year = year; dc.month = month; dc.day = day
        return Calendar.current.date(from: dc)
    }
}

// MARK: - 检查项模型
struct CloseCheckItem: Identifiable {
    let id = UUID()
    let passed: Bool
    let isWarning: Bool
    let message: String
}
