import SwiftUI

// ============================================================
//  记账凭证管理 v14 — 专业财务系统版
//  设计原则:
//  1. 凭证至少两条分录（一借一贷），每行只填一个方向
//  2. 新增凭证默认两行空行，引导用户正确录入
//  3. 凭证明细页直接从 dataStore 取最新数据，确保数据准确
//  4. DataStore 强制数组刷新，编辑/删除/过账实时更新
//  5. 科目选择用 Sheet 弹出搜索器，支持搜索/分类筛选
// ============================================================

// MARK: - 分录行输入模型
struct LineInput: Identifiable, Equatable {
    let id = UUID()
    var summary: String = ""
    var accountID: UUID? = nil
    var accountCode: String = ""
    var accountName: String = ""
    var debit: Decimal = 0
    var credit: Decimal = 0

    static func == (a: LineInput, b: LineInput) -> Bool {
        a.id == b.id &&
        a.summary == b.summary &&
        a.accountID == b.accountID &&
        a.debit == b.debit &&
        a.credit == b.credit
    }
}

// MARK: - 凭证管理主视图
struct JournalEntriesView: View {
    let company: Company
    @EnvironmentObject var dataStore: DataStore
    @State private var searchText = ""
    @State private var showNewEntry = false
    @State private var editingEntry: JournalEntry?
    @State private var viewingEntry: JournalEntry?
    @State private var confirmDelete: JournalEntry?
    @State private var selectedEntries = Set<JournalEntry.ID>()
    @State private var postError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索凭证号或摘要…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                Spacer()
                Button { showNewEntry = true } label: {
                    Label("新增凭证", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                if !filteredEntries.isEmpty {
                    Menu {
                        Button("导出凭证清单 PDF") {
                            if let url = PDFExporter.exportVoucherList(
                                entries: filteredEntries, companyName: company.name
                            ) { NSWorkspace.shared.open(url) }
                        }
                    } label: {
                        Label("导出 PDF", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            Divider()
            EntryTable(
                entries: filteredEntries,
                selectedEntries: $selectedEntries,
                onView: { viewingEntry = $0 },
                onEdit: { editingEntry = $0 },
                onDelete: { confirmDelete = $0 },
                onTogglePost: { e in
                    if !dataStore.togglePosted(e) {
                        postError = "凭证 \(e.number) 过账失败：借贷不平或该期间已结账"
                    }
                }
            )
        }
        .sheet(isPresented: $showNewEntry) {
            EntryEditor(company: company, entry: nil)
        }
        .sheet(item: $editingEntry) { e in
            EntryEditor(company: company, entry: e)
        }
        .sheet(item: $viewingEntry) { e in
            // 直接引用 dataStore 中的最新数据
            let freshEntry = dataStore.journalEntries.first(where: { $0.id == e.id }) ?? e
            EntryDetailSheet(
                entryID: freshEntry.id,
                onEdit: {
                    viewingEntry = nil
                    DispatchQueue.main.async { editingEntry = freshEntry }
                },
                onDelete: {
                    viewingEntry = nil
                    DispatchQueue.main.async { confirmDelete = freshEntry }
                },
                onTogglePost: {
                    if dataStore.togglePosted(freshEntry) {
                        viewingEntry = nil
                    } else {
                        postError = "凭证 \(freshEntry.number) 过账失败：借贷不平或该期间已结账"
                    }
                }
            )
        }
        .alert("删除凭证", isPresented: .init(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        ), presenting: confirmDelete) { entry in
            Button("取消", role: .cancel) { confirmDelete = nil }
            Button("删除", role: .destructive) {
                dataStore.deleteEntry(entry)
                confirmDelete = nil
            }
        } message: { entry in
            Text("确定删除凭证「\(entry.number)」？\n摘要：\(entry.summary)\n删除后不可恢复。")
        }
        .alert("操作提示", isPresented: .init(
            get: { postError != nil },
            set: { if !$0 { postError = nil } }
        ), presenting: postError) { _ in
            Button("确定") { postError = nil }
        } message: { msg in
            Text(msg)
        }
    }

    private var filteredEntries: [JournalEntry] {
        let all = dataStore.entries(for: company.id).sorted { a, b in
            if a.date != b.date { return a.date > b.date }
            return a.number > b.number
        }
        guard !searchText.isEmpty else { return all }
        return all.filter {
            $0.number.localizedCaseInsensitiveContains(searchText) ||
            $0.summary.localizedCaseInsensitiveContains(searchText)
        }
    }
}

// MARK: - 凭证表格
struct EntryTable: View {
    let entries: [JournalEntry]
    @Binding var selectedEntries: Set<JournalEntry.ID>
    let onView: (JournalEntry) -> Void
    let onEdit: (JournalEntry) -> Void
    let onDelete: (JournalEntry) -> Void
    let onTogglePost: (JournalEntry) -> Void
    @EnvironmentObject var dataStore: DataStore

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("暂无凭证", systemImage: "doc.text",
                                   description: Text("点击「新增凭证」创建第一张凭证"))
        } else {
            Table(entries, selection: $selectedEntries) {
                            TableColumn("凭证号", value: \.number).width(100)
                            TableColumn("日期") { e in Text(FMT.date(e.date)) }.width(90)
                            TableColumn("摘要", value: \.summary).width(140)
                            TableColumn("科目") { e in
                                                VStack(alignment: .leading, spacing: 1) {
                                                    ForEach(Array(e.lines.prefix(3)), id: \.id) { line in
                                                        HStack(spacing: 2) {
                                                            let code = line.accountCode.isEmpty ? dataStore.accounts.first(where: { $0.id == line.accountID })?.code ?? "" : line.accountCode
                                                            let name = line.accountName.isEmpty ? dataStore.accounts.first(where: { $0.id == line.accountID })?.name ?? "" : line.accountName
                                                            Text(code).font(.caption2).foregroundStyle(.tertiary)
                                                            Text(name).font(.caption2).foregroundStyle(.secondary)
                                                            if line.debit > 0 {
                                                                Text("借").font(.caption2).foregroundStyle(.blue)
                                                            } else if line.credit > 0 {
                                                                Text("贷").font(.caption2).foregroundStyle(.red)
                                                            }
                                                        }
                                                    }
                                    if e.lines.count > 3 {
                                        Text("+\(e.lines.count - 3) 条更多").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }.width(200)
                            TableColumn("借") { e in
                                Text("¥\(FMT.amount(e.debitTotal))")
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .foregroundStyle(.blue).monospacedDigit()
                            }.width(100).alignment(.trailing)
                            TableColumn("贷") { e in
                                Text("¥\(FMT.amount(e.creditTotal))")
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .foregroundStyle(.red).monospacedDigit()
                            }.width(100).alignment(.trailing)
                            TableColumn("状态") { e in
                                HStack(spacing: 4) {
                                    Circle().fill(e.isPosted ? Color.green : Color.orange).frame(width: 7)
                                    Text(e.isPosted ? "已过账" : "未过账")
                                        .font(.caption)
                                        .foregroundStyle(e.isPosted ? .green : .orange)
                                }
                            }.width(70)
                TableColumn("创建时间") { e in
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(FMT.datetime(e.createdAt)).font(.caption2).foregroundStyle(.secondary)
                        if e.updatedAt != e.createdAt {
                            Text("修改: \(FMT.datetime(e.updatedAt))").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }.width(155)
                TableColumn("操作") { e in
                    HStack(spacing: 6) {
                        Button { onView(e) } label: { Image(systemName: "eye").font(.caption) }
                            .buttonStyle(.plain).help("查看详情")
                        // 所有凭证均可编辑（编辑后需重新过账）
                        Button { onEdit(e) } label: { Image(systemName: "pencil").font(.caption) }
                            .buttonStyle(.plain).help("编辑凭证")
                        Button { onDelete(e) } label: { Image(systemName: "trash").font(.caption) }
                            .buttonStyle(.plain).help("删除").foregroundStyle(.red)
                    }
                }.width(85)
            }
            .tableStyle(.bordered)
            .contextMenu(forSelectionType: JournalEntry.self) { items in
                if let e = items.first {
                    Button("查看详情", systemImage: "eye") { onView(e) }
                    Divider()
                    Button("编辑", systemImage: "pencil") { onEdit(e) }
                    if !e.isPosted {
                        Button("过账", systemImage: "checkmark.circle") { onTogglePost(e) }
                    } else {
                        Button("反过账", systemImage: "arrow.uturn.backward") { onTogglePost(e) }
                    }
                    Divider()
                    Button("删除", systemImage: "trash", role: .destructive) { onDelete(e) }
                }
            }
        }
    }
}

// MARK: - 凭证明细页
// 通过 entryID 从 dataStore 实时读取最新数据，确保显示准确
struct EntryDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var dataStore: DataStore

    let entryID: UUID
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onTogglePost: (() -> Void)?

    /// 从 dataStore 实时获取最新凭证数据
    private var entry: JournalEntry? {
        dataStore.journalEntries.first { $0.id == entryID }
    }

    var body: some View {
        NavigationStack {
            if let entry = entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // —— 凭证头卡片 ——
                        VStack(spacing: 0) {
                            HStack {
                                Text(entry.number).font(.title2).bold()
                                Spacer()
                                HStack(spacing: 4) {
                                    Circle().fill(entry.isPosted ? Color.green : Color.orange).frame(width: 8)
                                    Text(entry.isPosted ? "已过账" : "未过账")
                                        .font(.caption.bold())
                                        .foregroundStyle(entry.isPosted ? .green : .orange)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background((entry.isPosted ? Color.green : Color.orange).opacity(0.12))
                                .cornerRadius(6)
                            }
                            Divider().padding(.vertical, 8)
                            VStack(spacing: 6) {
                                HStack {
                                    Text("日期").foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                                    Text(FMT.date(entry.date)).fontWeight(.medium)
                                    Spacer()
                                    Text("创建").foregroundStyle(.secondary)
                                    Text(FMT.datetime(entry.createdAt)).font(.caption).foregroundStyle(.secondary)
                                }
                                if entry.updatedAt != entry.createdAt {
                                    HStack {
                                        Text("修改").foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                                        Text(FMT.datetime(entry.updatedAt)).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                }
                                HStack(alignment: .top) {
                                    Text("摘要").foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                                    Text(entry.summary).textSelection(.enabled)
                                    Spacer()
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(10)

                        // —— 分录明细表 ——
                        EntryDetailLinesView(entry: entry, dataStore: dataStore)
                    }
                    .padding(16)
                }
                .safeAreaInset(edge: .bottom) {
                    // 底部操作栏
                    VStack(spacing: 0) {
                        Divider()
                        HStack {
                            // 所有凭证均可编辑
                            Button { onEdit?() } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .buttonStyle(.borderedProminent)
                            Button(entry.isPosted ? "反过账" : "过账") {
                                onTogglePost?()
                                dismiss()
                            }.buttonStyle(.bordered)
                            Button("删除", role: .destructive) {
                                onDelete?()
                                dismiss()
                            }.buttonStyle(.bordered)
                            Spacer()
                            Button("关闭") { dismiss() }.buttonStyle(.bordered).keyboardShortcut(.escape)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .navigationTitle("凭证详情")
            } else {
                // 凭证已被删除
                ContentUnavailableView("凭证已不存在", systemImage: "doc.text.magnifyingglass",
                                       description: Text("该凭证可能已被删除"))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("关闭") { dismiss() }
                        }
                    }
            }
        }
        .frame(width: 780, height: 560)
    }
}

// MARK: - 凭证编辑器
struct EntryEditor: View {
    @EnvironmentObject var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss

    let company: Company
    let entry: JournalEntry?

    @State private var date: Date = Date()
    @State private var summary: String = ""
    @State private var lines: [LineInput] = []
    @State private var showAlert = false
    @State private var alertMessage = ""

    private var availableAccounts: [Account] {
        dataStore.accounts(for: company.id).filter { $0.isActive }.sorted { $0.code < $1.code }
    }

    private var totalDebit: Decimal { lines.reduce(0) { $0 + $1.debit } }
    private var totalCredit: Decimal { lines.reduce(0) { $0 + $1.credit } }

    var body: some View {
        let hasAcct = lines.contains(where: { $0.accountID != nil })
        let hasAmt = lines.contains(where: { $0.debit > 0 || $0.credit > 0 })
        let hasSum = !summary.trimmingCharacters(in: .whitespaces).isEmpty
        // 专业财务逻辑：借方合计必须等于贷方合计且大于零
        let canSave = totalDebit == totalCredit && totalDebit > 0 && hasAcct && hasAmt && hasSum

        return NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("凭证信息") {
                        DatePicker("日期", selection: $date, displayedComponents: .date)
                        HStack {
                            Text("凭证号").foregroundStyle(.secondary)
                            Text(entry?.number ?? "自动生成")
                                .foregroundStyle(entry != nil ? .primary : .secondary)
                        }
                        TextField("摘要（必填）", text: $summary, axis: .vertical)
                            .lineLimit(1...3)

                        if let e = entry {
                            HStack {
                                Text("创建时间").foregroundStyle(.secondary)
                                Text(FMT.datetime(e.createdAt)).font(.caption)
                            }
                            HStack {
                                Text("状态").foregroundStyle(.secondary)
                                Text(e.isPosted ? "已过账" : "未过账")
                                    .font(.caption).foregroundStyle(e.isPosted ? .orange : .green)
                            }
                        }
                    }

                    Section("分录行") {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { idx, _ in
                            LineRowView(
                                line: $lines[idx],
                                accounts: availableAccounts,
                                usedIDs: Set(lines.enumerated().filter { $0.offset != idx }.compactMap { $0.element.accountID }),
                                onDelete: lines.count > 1 ? { lines.remove(at: idx) } : nil
                            )
                        }
                        Button {
                            withAnimation { lines.append(LineInput()) }
                        } label: {
                            Label("添加分录行", systemImage: "plus.circle")
                        }
                    }
                }
                .formStyle(.grouped)

                // 底部状态栏 — 借贷平衡 + 保存按钮
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        HStack(spacing: 6) {
                            let hasData = lines.contains(where: { $0.debit > 0 || $0.credit > 0 })
                            let bal = totalDebit == totalCredit && totalDebit > 0
                            Image(systemName: bal ? "checkmark.circle.fill" :
                                    (hasData ? "xmark.circle.fill" : "circle"))
                                .foregroundStyle(bal ? .green :
                                    (hasData ? .red : .secondary))
                            Text(bal ? "借贷平衡" :
                                    (hasData ? "差额 ¥\(FMT.amount(abs(totalDebit - totalCredit)))" : "等待录入"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("借 ¥\(FMT.amount(totalDebit))")
                            .foregroundStyle(.blue).font(.callout.monospacedDigit())
                        Text("贷 ¥\(FMT.amount(totalCredit))")
                            .foregroundStyle(.red).font(.callout.monospacedDigit())

                        Button("取消") { dismiss() }.buttonStyle(.bordered)
                        Button(action: save) { Text("保存凭证") }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canSave)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .navigationTitle(entry != nil ? "编辑凭证" : "新增凭证")
            .alert("提示", isPresented: $showAlert) {
                Button("确定") {}
            } message: { Text(alertMessage) }
            .onAppear(perform: setupFromEntry)
        }
        .frame(width: 850, height: 700)
    }

    private func setupFromEntry() {
        if let e = entry {
            date = e.date
            summary = e.summary
            lines = e.lines.isEmpty ? [LineInput(), LineInput()] : e.lines.map { l in
                var li = LineInput()
                li.summary = l.summary
                li.accountID = l.accountID
                // 编辑时回填科目信息
                li.accountCode = l.accountCode
                li.accountName = l.accountName
                // 兼容旧数据：如果 accountCode 为空但有 accountID，反查科目信息
                if li.accountCode.isEmpty, let aid = l.accountID, let acct = DataStore.shared.accounts.first(where: { $0.id == aid }) {
                    li.accountCode = acct.code
                    li.accountName = acct.name
                }
                li.debit = l.debit
                li.credit = l.credit
                return li
            }
        } else {
            // 新增凭证默认两行分录（一借一贷），符合会计准则
            lines = [LineInput(), LineInput()]
        }
    }

    private func save() {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespaces)
        guard !trimmedSummary.isEmpty else {
            alertMessage = "请输入凭证摘要"; showAlert = true; return
        }
        guard lines.contains(where: { $0.accountID != nil }) else {
            alertMessage = "至少需要指定一个会计科目"; showAlert = true; return
        }
        guard lines.contains(where: { $0.debit > 0 || $0.credit > 0 }) else {
            alertMessage = "至少需要一条有金额的分录"; showAlert = true; return
        }
        guard totalDebit == totalCredit else {
            alertMessage = "借贷不平衡，无法保存\n借方合计：¥\(FMT.amount(totalDebit))\n贷方合计：¥\(FMT.amount(totalCredit))"
            showAlert = true; return
        }
        guard totalDebit > 0 else {
            alertMessage = "金额不能为零"; showAlert = true; return
        }

        let je: JournalEntry
        let isNew = (entry == nil)

        if let existing = entry {
            je = existing
            je.date = date
            je.summary = trimmedSummary
            je.updatedAt = Date()
            je.lines.removeAll()
        } else {
            je = JournalEntry(
                number: AccountingEngine.nextVoucherNumber(for: company),
                date: date,
                summary: trimmedSummary
            )
            je.companyID = company.id
        }

        for li in lines where li.accountID != nil && (li.debit > 0 || li.credit > 0) {
            let line = JournalLine(summary: li.summary, debit: li.debit, credit: li.credit,
                                   accountCode: li.accountCode, accountName: li.accountName)
            line.entryID = je.id
            line.accountID = li.accountID
            je.lines.append(line)
        }

        if isNew { dataStore.addEntry(je) }
        else {
            // 编辑已过账凭证后保持原状态，但要求重新确认
            dataStore.updateEntry(je)
        }

        dismiss()
    }
}

// MARK: - 分录行编辑视图
struct LineRowView: View {
    @Binding var line: LineInput
    let accounts: [Account]
    let usedIDs: Set<UUID>
    let onDelete: (() -> Void)?
    @State private var showPicker = false

    private var selectedAccount: Account? {
        guard let id = line.accountID else { return nil }
        return accounts.first { $0.id == id }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            // 科目选择（含备注输入）
            VStack(alignment: .leading, spacing: 2) {
                Button { showPicker = true } label: {
                    HStack(spacing: 4) {
                        if let a = selectedAccount {
                            Circle().fill(a.category.categoryColor).frame(width: 6, height: 6)
                            Text(a.code).fontWeight(.medium).font(.subheadline)
                            Text(a.name).foregroundStyle(.secondary).font(.subheadline)
                        } else {
                            Text("选择科目").foregroundStyle(.tertiary)
                        }
                        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(selectedAccount != nil ? Color.accentColor.opacity(0.3) : Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showPicker) {
                    SimpleAccountPicker(
                        accounts: accounts,
                        usedIDs: usedIDs,
                        onSelect: { a in
                            line.accountID = a.id
                            line.accountCode = a.code
                            line.accountName = a.name
                            showPicker = false
                        }
                    )
                }

                TextField("备注", text: $line.summary)
                    .textFieldStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 160)

            // 借方金额（填借方时自动清空贷方）
            AmountField(value: Binding(
                get: { line.debit },
                set: { newVal in
                    line.debit = newVal
                    if newVal > 0 { line.credit = 0 }
                }
            ), color: .blue, placeholder: "借方金额")
                .frame(width: 125)

            // 贷方金额（填贷方时自动清空借方）
            AmountField(value: Binding(
                get: { line.credit },
                set: { newVal in
                    line.credit = newVal
                    if newVal > 0 { line.debit = 0 }
                }
            ), color: .red, placeholder: "贷方金额")
                .frame(width: 125)

            // 方向指示（不可能再出现"借+贷"）
            HStack(spacing: 4) {
                if line.debit > 0 {
                    Image(systemName: "arrow.right.circle.fill").font(.caption2).foregroundStyle(.blue)
                    Text("借").font(.caption2.bold()).foregroundStyle(.blue)
                } else if line.credit > 0 {
                    Image(systemName: "arrow.right.circle.fill").font(.caption2).foregroundStyle(.red)
                    Text("贷").font(.caption2.bold()).foregroundStyle(.red)
                } else {
                    Text("—").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 50)

            if let d = onDelete {
                Button(action: d) {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.plain).help("删除此行")
                .padding(.leading, 2)
            }
        }
    }
}

// MARK: - 金额输入组件（专业样式）
struct AmountField: View {
    @Binding var value: Decimal
    let color: Color
    let placeholder: String
    @State private var isFocused = false

    var body: some View {
        HStack(spacing: 0) {
            Text("¥")
                .foregroundStyle(color)
                .font(.subheadline.bold())
                .padding(.leading, 8)
            TextField(placeholder, value: $value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(color.opacity(value > 0 ? 1 : 0.5))
                .monospacedDigit()
                .font(.subheadline)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(value > 0 ? 0.06 : 0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(value > 0 ? color.opacity(0.3) : Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.8)
        )
    }
}

// MARK: - 凭证明细分录行列表（独立视图解决编译器类型检查超时）
struct EntryDetailLinesView: View {
    let entry: JournalEntry
    let dataStore: DataStore

    var body: some View {
        VStack(spacing: 0) {
            // 表头
            HStack(spacing: 0) {
                Text("摘要").frame(width: 130, alignment: .leading)
                Text("科目编码").frame(width: 72, alignment: .leading)
                Text("科目名称").frame(width: 140, alignment: .leading)
                Spacer(minLength: 8)
                Text("借方金额").frame(width: 110, alignment: .trailing)
                Text("贷方金额").frame(width: 110, alignment: .trailing)
            }
            .font(.caption.bold()).foregroundStyle(.secondary)
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // 数据行
            if entry.lines.isEmpty {
                Text("暂无分录数据")
                    .foregroundStyle(.tertiary)
                    .padding(24)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(entry.lines.enumerated()), id: \.element.id) { idx, line in
                    EntryDetailLineRow(line: line, dataStore: dataStore, entrySummary: entry.summary)
                    if idx < entry.lines.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }

            Divider().padding(.top, 4)

            // 合计行
            HStack(spacing: 0) {
                Spacer()
                Text("合计：").font(.subheadline.bold())
                Text("¥\(FMT.amount(entry.debitTotal))")
                    .foregroundStyle(.blue).font(.subheadline.bold().monospacedDigit())
                    .frame(width: 110, alignment: .trailing)
                Text("¥\(FMT.amount(entry.creditTotal))")
                    .foregroundStyle(.red).font(.subheadline.bold().monospacedDigit())
                    .frame(width: 110, alignment: .trailing)
                if entry.isBalanced {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).padding(.leading, 6)
                    Text("平衡").foregroundStyle(.green).font(.caption.bold())
                } else {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red).padding(.leading, 6)
                    Text("不平！").foregroundStyle(.red).font(.caption.bold())
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }
}

// MARK: - 凭证明细单行（独立视图解决编译器类型检查超时）
struct EntryDetailLineRow: View {
    let line: JournalLine
    let dataStore: DataStore
    let entrySummary: String  // 凭证头摘要，用于分录行摘要为空时显示

    var body: some View {
        // 反查科目信息（兼容旧数据）
        let displayCode: String
        let displayName: String
        if !line.accountCode.isEmpty {
            displayCode = line.accountCode
            displayName = line.accountName
        } else if let aid = line.accountID, let acct = dataStore.accounts.first(where: { $0.id == aid }) {
            displayCode = acct.code
            displayName = acct.name
        } else {
            displayCode = line.accountCode
            displayName = line.accountName.isEmpty ? "(无科目)" : line.accountName
        }
        // 分录行摘要为空时，显示凭证头摘要
        let displaySummary = line.summary.isEmpty ? entrySummary : line.summary

        return HStack(spacing: 0) {
            Text(displaySummary)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(displayCode)
                .fontWeight(.medium)
                .frame(width: 72, alignment: .leading)
            Text(displayName)
                .frame(width: 140, alignment: .leading)
            Spacer(minLength: 8)
            Text(line.debit > 0 ? "¥\(FMT.amount(line.debit))" : "")
                .foregroundStyle(.blue).monospacedDigit()
                .frame(width: 110, alignment: .trailing)
            Text(line.credit > 0 ? "¥\(FMT.amount(line.credit))" : "")
                .foregroundStyle(.red).monospacedDigit()
                .frame(width: 110, alignment: .trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 6).padding(.horizontal, 12)
    }
}

// MARK: - 科目选择器（弹出 Sheet）
struct SimpleAccountPicker: View {
    let accounts: [Account]
    let usedIDs: Set<UUID>
    let onSelect: (Account) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var filterCategory: AccountCategory?

    private var available: [Account] {
        var r = accounts.filter { !usedIDs.contains($0.id) }.sorted { $0.code < $1.code }
        if let cat = filterCategory { r = r.filter { $0.category == cat } }
        if !searchText.isEmpty {
            r = r.filter {
                $0.code.localizedCaseInsensitiveContains(searchText) ||
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }
        return r
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索栏
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("搜索编码/名称", text: $searchText).textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)

                // 分类筛选标签
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        categoryChip("全部", selected: filterCategory == nil) { filterCategory = nil }
                        ForEach(AccountCategory.allCases) { cat in
                            categoryChip(cat.rawValue, selected: filterCategory == cat) { filterCategory = cat }
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                }

                Divider()

                if available.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "无可用科目" : "未找到匹配科目",
                        systemImage: "tray",
                        description: Text(searchText.isEmpty ? "所有科目已被选择" : "换个关键词试试")
                    )
                } else {
                    List(available) { a in
                        Button {
                            onSelect(a)
                            dismiss()
                        } label: {
                            HStack {
                                Text(a.code)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 50, alignment: .leading)
                                Text(a.name)
                                Spacer()
                                Text(a.category.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(a.category.categoryColor.opacity(0.12))
                                    .cornerRadius(4)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("选择科目")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .frame(width: 380, height: 460)
        }
    }

    private func categoryChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                .foregroundStyle(selected ? .white : .primary)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}