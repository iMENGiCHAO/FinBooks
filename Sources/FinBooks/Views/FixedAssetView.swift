import SwiftUI

// MARK: - 固定资产管理

struct FixedAssetView: View {
    let company: Company
    @EnvironmentObject var dataStore: DataStore
    @State private var showAddAsset = false
    @State private var editingAsset: FixedAsset?
    @State private var showDepreciationSchedule: FixedAsset?
    @State private var deleteConfirm: FixedAsset?
    @State private var disposeConfirm: FixedAsset?
    @State private var depreciationResult: String?
    @State private var assetSearchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索资产…", text: $assetSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Spacer()
                Button {
                    showAddAsset = true
                } label: {
                    Label("新增资产", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                if !myAssets.isEmpty {
                    Button {
                        generateMonthlyDepreciation()
                    } label: {
                        Label("计提本月折旧", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()

            Divider()

            if myAssets.isEmpty {
                ContentUnavailableView("暂无固定资产", systemImage: "building.2",
                                       description: Text("点击「新增资产」添加固定资产"))
            } else {
                Table(myAssets) {
                    TableColumn("资产名称", value: \.name).width(130)
                    TableColumn("编号", value: \.assetCode).width(90)
                    TableColumn("类别", value: \.category).width(80)
                    TableColumn("原值") { a in
                        Text("¥\(FMT.amount(a.originalValue))")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .monospacedDigit()
                    }.width(100).alignment(.trailing)
                    TableColumn("累计折旧") { a in
                        Text("¥\(FMT.amount(a.accumulatedDepreciation))")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                    }.width(100).alignment(.trailing)
                    TableColumn("净值") { a in
                        Text("¥\(FMT.amount(a.netBookValue))")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .monospacedDigit()
                            .foregroundStyle(a.netBookValue > 0 ? .primary : .secondary)
                    }.width(100).alignment(.trailing)
                    TableColumn("折旧方法") { a in
                        Text(a.depreciationMethod.rawValue).font(.caption).foregroundStyle(.secondary)
                    }.width(80)
                    TableColumn("状态") { a in
                        statusBadge(a.status)
                    }.width(80)
                    TableColumn("操作") { a in
                        HStack(spacing: 6) {
                            Button { showDepreciationSchedule = a } label: {
                                Image(systemName: "calendar").font(.caption)
                            }
                            .buttonStyle(.plain).help("折旧明细")
                            Button { editingAsset = a } label: {
                                Image(systemName: "pencil").font(.caption)
                            }
                            .buttonStyle(.plain).help("编辑")
                            if a.status == .active {
                                Button { disposeConfirm = a } label: {
                                    Image(systemName: "xmark.circle").font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                .buttonStyle(.plain).help("处置")
                            }
                            Button { deleteConfirm = a } label: {
                                Image(systemName: "trash").font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain).help("删除")
                        }
                    }.width(140)
                }
                .tableStyle(.bordered)
            }
        }
        .sheet(isPresented: $showAddAsset) {
            FixedAssetEditView(company: company, asset: nil)
        }
        .sheet(item: $editingAsset) { asset in
            FixedAssetEditView(company: company, asset: asset)
        }
        .sheet(item: $showDepreciationSchedule) { asset in
            DepreciationScheduleView(asset: asset)
        }
        .alert("删除资产", isPresented: .init(
            get: { deleteConfirm != nil },
            set: { if !$0 { deleteConfirm = nil } }
        ), presenting: deleteConfirm) { a in
            Button("取消", role: .cancel) { deleteConfirm = nil }
            Button("删除", role: .destructive) {
                dataStore.deleteFixedAsset(a)
                deleteConfirm = nil
            }
        } message: { a in
            Text("确定删除资产「\(a.name)」？\\n此操作不可恢复。")
        }
        .alert("处置资产", isPresented: .init(
            get: { disposeConfirm != nil },
            set: { if !$0 { disposeConfirm = nil } }
        ), presenting: disposeConfirm) { a in
            Button("取消", role: .cancel) { disposeConfirm = nil }
            Button("确认处置") {
                dataStore.disposeAsset(a)
                disposeConfirm = nil
            }
        } message: { a in
            Text("将资产「\(a.name)」标记为「已处置」状态？\\n净值：¥\(FMT.amount(a.netBookValue))")
        }
        .alert("折旧结果", isPresented: .init(
            get: { depreciationResult != nil },
            set: { if !$0 { depreciationResult = nil } }
        ), presenting: depreciationResult) { _ in
            Button("确定") { depreciationResult = nil }
        } message: { Text($0) }
    }

    private var myAssets: [FixedAsset] {
        dataStore.fixedAssets.filter { $0.companyID == company.id }
            .sorted { $0.name < $1.name }
    }

    @ViewBuilder
    private func statusBadge(_ status: AssetStatus) -> some View {
        HStack(spacing: 4) {
            Circle().fill(statusColor(status)).frame(width: 7)
            Text(status.rawValue)
                .font(.caption)
                .foregroundStyle(statusColor(status))
        }
    }

    private func statusColor(_ status: AssetStatus) -> Color {
        switch status {
        case .active: return .green
        case .disposed: return .red
        case .fullyDepreciated: return .orange
        }
    }

    /// 生成本月折旧凭证
    private func generateMonthlyDepreciation() {
        let activeAssets = myAssets.filter { $0.status == .active }
        guard !activeAssets.isEmpty else {
            depreciationResult = "没有使用中的固定资产需要计提折旧"
            return
        }

        let cal = Calendar.current
        let now = Date()
        let thisYear = cal.component(.year, from: now)
        let thisMonth = cal.component(.month, from: now)

        // 检查是否已计提
        let existingDepEntries = dataStore.entries(for: company.id).filter { entry in
            entry.summary.hasPrefix("计提折旧") &&
            cal.component(.year, from: entry.date) == thisYear &&
            cal.component(.month, from: entry.date) == thisMonth
        }
        if !existingDepEntries.isEmpty {
            depreciationResult = "本月已计提折旧，凭证号：\(existingDepEntries.map(\.number).joined(separator: "、"))"
            return
        }

        var totalDepreciation: Decimal = 0
        var depDetails: [String] = []

        for asset in activeAssets {
            let monthlyDep = monthlyDepreciation(for: asset)
            guard monthlyDep > 0 else { continue }
            totalDepreciation += monthlyDep
            depDetails.append("\(asset.name): ¥\(FMT.amount(monthlyDep))")
        }

        guard totalDepreciation > 0 else {
            depreciationResult = "没有资产需要计提折旧（可能净值已为零）"
            return
        }

        // 找费用科目和累计折旧科目
        let expenseAccounts = dataStore.accounts(for: company.id).filter { $0.category == .expense && $0.isActive }
        let depreciationAccounts = dataStore.accounts(for: company.id).filter { $0.name.contains("累计折旧") && $0.isActive }

        guard let expenseAcct = expenseAccounts.first(where: { $0.code.hasPrefix("6602") }) ?? expenseAccounts.first else {
            depreciationResult = "未找到折旧费用科目，请先在科目表中创建"
            return
        }
        guard let depAcct = depreciationAccounts.first else {
            depreciationResult = "未找到累计折旧科目（1602），请先在科目表中创建"
            return
        }

        // 获取下个凭证号
        let existingNumbers = dataStore.entries(for: company.id).map(\.number)
        let seq = existingNumbers.filter { $0.hasPrefix("记-") }.count + 1
        let entryNumber = "记-\(thisYear)-\(String(format: "%04d", seq))"

        let entry = JournalEntry(number: entryNumber, date: now, summary: "计提折旧 (\(thisYear)年\(thisMonth)月)")
        entry.companyID = company.id

        let line1 = JournalLine(summary: "计提折旧费用", debit: totalDepreciation, credit: 0)
        line1.accountID = expenseAcct.id
        line1.entryID = entry.id

        let line2 = JournalLine(summary: "累计折旧", debit: 0, credit: totalDepreciation)
        line2.accountID = depAcct.id
        line2.entryID = entry.id

        entry.lines = [line1, line2]

        // 添加凭证并自动过账
        if dataStore.addEntry(entry) {
            // 自动过账，生成哈希链
            _ = dataStore.togglePosted(entry, reason: "系统自动计提折旧")
            // 更新累计折旧到资产
            for asset in activeAssets {
                let monthlyDep = Self.staticMonthlyDepreciation(for: asset)
                guard monthlyDep > 0 else { continue }
                if let idx = dataStore.fixedAssets.firstIndex(where: { $0.id == asset.id }) {
                    dataStore.fixedAssets[idx].accumulatedDepreciation += monthlyDep
                    // 如果已提足，更新状态
                    if dataStore.fixedAssets[idx].netBookValue <= 0 {
                        dataStore.fixedAssets[idx].status = .fullyDepreciated
                    }
                }
            }
            dataStore.saveAll()
            dataStore.objectWillChange.send()

            let details = depDetails.joined(separator: "\n")
            let posted = entry.isPosted ? "已过账" : "过账失败"
            depreciationResult = """
折旧凭证已生成：\(entryNumber)（\(posted)）
合计：¥\(FMT.amount(totalDepreciation))

明细：
\(details)
"""
        } else {
            depreciationResult = "生成折旧凭证失败，请检查期间是否已结账"
        }
    }

    /// 计算月折旧额（实例方法，委托静态方法）
    func monthlyDepreciation(for asset: FixedAsset) -> Decimal {
        return Self.staticMonthlyDepreciation(for: asset)
    }

    /// 静态月折旧计算（供闭包/静态上下文使用）
    static func staticMonthlyDepreciation(for asset: FixedAsset) -> Decimal {
        guard asset.netBookValue > 0, asset.usefulLife > 0 else { return 0 }

        switch asset.depreciationMethod {
        case .straightLine:
            let depreciableBase = asset.originalValue - asset.residualValue
            guard depreciableBase > 0 else { return 0 }
            return depreciableBase / Decimal(asset.usefulLife)

        case .doubleDeclining:
            let rate = Decimal(2) / Decimal(asset.usefulLife)
            let monthlyDep = asset.netBookValue * rate
            let cal = Calendar.current
            let monthsSinceStart = cal.dateComponents([.month], from: asset.startDepreciationDate, to: Date()).month ?? 0
            let remainingMonths = max(0, asset.usefulLife - monthsSinceStart + 1)
            if remainingMonths <= 2 {
                let remainingValue = asset.netBookValue - asset.residualValue
                return max(0, remainingValue / Decimal(max(1, remainingMonths)))
            }
            return max(0, monthlyDep)
        }
    }

    /// 剩余折旧月数（估算）
    func remainingLife(for asset: FixedAsset) -> Int {
        let cal = Calendar.current
        let monthsSinceStart = cal.dateComponents([.month], from: asset.startDepreciationDate, to: Date()).month ?? 0
        return max(0, asset.usefulLife - monthsSinceStart + 1)
    }

    /// 获取资产当前期间的折旧明细列表
    func depreciationDetail(for asset: FixedAsset) -> [(period: String, amount: Decimal)] {
        guard asset.accumulatedDepreciation > 0 else { return [] }
        let cal = Calendar.current
        let start = asset.startDepreciationDate
        let monthsSinceStart = cal.dateComponents([.month], from: start, to: Date()).month ?? 0
        let totalMonths = min(monthsSinceStart, asset.usefulLife)
        var result: [(String, Decimal)] = []

        for i in 0..<totalMonths {
            guard let periodDate = cal.date(byAdding: .month, value: i, to: start) else { continue }
            let year = cal.component(.year, from: periodDate)
            let month = cal.component(.month, from: periodDate)
            let amount = monthlyDepreciation(for: asset)
            result.append(("\(year)-\(String(format: "%02d", month))", amount))
        }
        return result
    }
}

// MARK: - 新增/编辑固定资产

struct FixedAssetEditView: View {
    @EnvironmentObject var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss

    let company: Company
    let asset: FixedAsset?

    @State private var name: String = ""
    @State private var assetCode: String = ""
    @State private var category: String = ""
    @State private var originalValue: Decimal = 0
    @State private var residualValue: Decimal = 0
    @State private var usefulLife: Int = 60
    @State private var depreciationMethod: DepreciationMethod = .straightLine
    @State private var acquiredDate: Date = Date()
    @State private var startDepreciationDate: Date = Date()
    @State private var accumulatedDepreciation: Decimal = 0
    @State private var selectedAccountID: UUID?
    @State private var selectedDepAccountID: UUID?
    @State private var selectedExpenseAccountID: UUID?
    @State private var showError = false
    @State private var errorMessage = ""

    private var isEditing: Bool { asset != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("资产名称", text: $name)
                    TextField("资产编号", text: $assetCode)
                    TextField("类别（如：电子设备）", text: $category)
                }

                Section("价值信息") {
                    HStack {
                        Text("原值")
                        TextField("原值", value: $originalValue, format: .number.precision(.fractionLength(2)))
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("残值")
                        TextField("残值", value: $residualValue, format: .number.precision(.fractionLength(2)))
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("使用年限（月）")
                        Stepper("\(usefulLife) 个月", value: $usefulLife, in: 1...600)
                    }
                    if isEditing {
                        HStack {
                            Text("累计折旧")
                            TextField("累计折旧", value: $accumulatedDepreciation,
                                      format: .number.precision(.fractionLength(2)))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section("折旧方法") {
                    Picker("折旧方法", selection: $depreciationMethod) {
                        ForEach(DepreciationMethod.allCases) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                }

                Section("日期") {
                    DatePicker("购置日期", selection: $acquiredDate, displayedComponents: .date)
                    DatePicker("开始折旧日期", selection: $startDepreciationDate, displayedComponents: .date)
                }

                Section("关联科目") {
                    Picker("固定资产科目", selection: $selectedAccountID) {
                        Text("不关联").tag(nil as UUID?)
                        ForEach(assetAccounts) { acct in
                            Text("\(acct.code) \(acct.name)").tag(acct.id as UUID?)
                        }
                    }
                    Picker("累计折旧科目", selection: $selectedDepAccountID) {
                        Text("不关联").tag(nil as UUID?)
                        ForEach(depAccounts) { acct in
                            Text("\(acct.code) \(acct.name)").tag(acct.id as UUID?)
                        }
                    }
                    Picker("折旧费用科目", selection: $selectedExpenseAccountID) {
                        Text("不关联").tag(nil as UUID?)
                        ForEach(expenseAccounts) { acct in
                            Text("\(acct.code) \(acct.name)").tag(acct.id as UUID?)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "编辑资产" : "新增资产")
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
            .onAppear {
                if let a = asset {
                    name = a.name
                    assetCode = a.assetCode
                    category = a.category
                    originalValue = a.originalValue
                    residualValue = a.residualValue
                    usefulLife = a.usefulLife
                    depreciationMethod = a.depreciationMethod
                    acquiredDate = a.acquiredDate
                    startDepreciationDate = a.startDepreciationDate
                    accumulatedDepreciation = a.accumulatedDepreciation
                    selectedAccountID = a.accountID
                    selectedDepAccountID = a.depreciationAccountID
                    selectedExpenseAccountID = a.expenseAccountID
                } else {
                    assetCode = autoGenerateCode()
                }
            }
            .frame(minWidth: 420, minHeight: 500)
        }
    }

    private var assetAccounts: [Account] {
        dataStore.accounts(for: company.id).filter { $0.isActive && $0.category == .asset && $0.code.hasPrefix("1601") }
            .sorted { $0.code < $1.code }
    }

    private var depAccounts: [Account] {
        dataStore.accounts(for: company.id).filter { $0.isActive && $0.code.hasPrefix("1602") }
            .sorted { $0.code < $1.code }
    }

    private var expenseAccounts: [Account] {
        dataStore.accounts(for: company.id).filter { $0.isActive && $0.category == .expense }
            .sorted { $0.code < $1.code }
    }

    private func autoGenerateCode() -> String {
        let existing = dataStore.fixedAssets.filter { $0.companyID == company.id }
        return "FA-\(String(format: "%04d", existing.count + 1))"
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "资产名称不能为空"
            showError = true
            return
        }
        guard !assetCode.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "资产编号不能为空"
            showError = true
            return
        }
        guard originalValue > 0 else {
            errorMessage = "原值必须大于零"
            showError = true
            return
        }

        if let a = asset {
            a.name = name
            a.assetCode = assetCode
            a.category = category
            a.originalValue = originalValue
            a.residualValue = residualValue
            a.usefulLife = usefulLife
            a.depreciationMethod = depreciationMethod
            a.acquiredDate = acquiredDate
            a.startDepreciationDate = startDepreciationDate
            a.accumulatedDepreciation = accumulatedDepreciation
            a.accountID = selectedAccountID
            a.depreciationAccountID = selectedDepAccountID
            a.expenseAccountID = selectedExpenseAccountID
            dataStore.updateFixedAsset(a)
        } else {
            let newAsset = FixedAsset(
                name: name, assetCode: assetCode, category: category,
                originalValue: originalValue, residualValue: residualValue,
                usefulLife: usefulLife, depreciationMethod: depreciationMethod,
                acquiredDate: acquiredDate, startDepreciationDate: startDepreciationDate
            )
            newAsset.accountID = selectedAccountID
            newAsset.depreciationAccountID = selectedDepAccountID
            newAsset.expenseAccountID = selectedExpenseAccountID
            newAsset.companyID = company.id
            dataStore.addFixedAsset(newAsset)
        }
        dismiss()
    }
}

// MARK: - 折旧明细表

struct DepreciationScheduleView: View {
    let asset: FixedAsset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 资产摘要
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.name).font(.headline)
                        Text("编号: \(asset.assetCode) | 类别: \(asset.category)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("原值: ¥\(FMT.amount(asset.originalValue))")
                        Text("累计折旧: ¥\(FMT.amount(asset.accumulatedDepreciation))")
                        Text("净值: ¥\(FMT.amount(asset.netBookValue))")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption.monospacedDigit())
                }
                .padding()

                Divider()

                if schedule.isEmpty {
                    ContentUnavailableView("暂无折旧记录", systemImage: "calendar",
                                           description: Text("该资产尚未开始计提折旧"))
                } else {
                    Table(schedule) {
                        TableColumn("期间") { s in Text(s.period).font(.caption) }.width(100)
                        TableColumn("月折旧额") { s in
                            Text("¥\(FMT.amount(s.amount))")
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .monospacedDigit()
                        }.width(120).alignment(.trailing)
                        TableColumn("累计") { s in
                            Text("¥\(FMT.amount(s.cumulative))")
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                        }.width(120).alignment(.trailing)
                        TableColumn("剩余净值") { s in
                            Text("¥\(FMT.amount(s.remainingValue))")
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .monospacedDigit()
                        }.width(120).alignment(.trailing)
                    }
                    .tableStyle(.bordered)
                }
            }
            .navigationTitle("折旧明细")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }.keyboardShortcut(.escape)
                }
            }
            .frame(minWidth: 500, minHeight: 400)
        }
    }

    private struct DepRow: Identifiable {
        let id = UUID()
        let period: String
        let amount: Decimal
        let cumulative: Decimal
        let remainingValue: Decimal
    }

    private var schedule: [DepRow] {
        guard asset.accumulatedDepreciation > 0 || asset.netBookValue > 0 else { return [] }
        let cal = Calendar.current
        let start = asset.startDepreciationDate
        let monthsSinceStart = cal.dateComponents([.month], from: start, to: Date()).month ?? 0
        let totalMonths = min(monthsSinceStart, asset.usefulLife)
        var rows: [DepRow] = []

        // 用直线法统计算折旧
        let monthlyDep = asset.originalValue > 0 && asset.usefulLife > 0
            ? (asset.originalValue - asset.residualValue) / Decimal(asset.usefulLife)
            : Decimal.zero

        for i in 0..<totalMonths {
            guard let periodDate = cal.date(byAdding: .month, value: i, to: start) else { continue }
            let year = cal.component(.year, from: periodDate)
            let month = cal.component(.month, from: periodDate)
            let cum = monthlyDep * Decimal(i + 1)
            let remaining = asset.originalValue - asset.residualValue - cum
            rows.append(DepRow(
                period: "\(year)-\(String(format: "%02d", month))",
                amount: monthlyDep,
                cumulative: cum,
                remainingValue: max(0, remaining)
            ))
        }
        return rows
    }
}
