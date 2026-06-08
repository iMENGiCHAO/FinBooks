import SwiftUI

// MARK: - 发票管理

struct InvoiceListView: View {
    let company: Company
    @EnvironmentObject var dataStore: DataStore
    @State private var showAdd = false
    @State private var editingInvoice: Invoice?
    @State private var deleteConfirm: Invoice?
    @State private var filterType: InvoiceType?

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Picker("类型筛选", selection: $filterType) {
                    Text("全部").tag(nil as InvoiceType?)
                    ForEach(InvoiceType.allCases) { t in
                        Text(t.rawValue).tag(t as InvoiceType?)
                    }
                }
                .frame(width: 120)
                Spacer()
                Button {
                    showAdd = true
                } label: {
                    Label("录入发票", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            if filteredInvoices.isEmpty {
                ContentUnavailableView("暂无发票", systemImage: "doc.text.magnifyingglass",
                                       description: Text("点击「录入发票」添加进项或销项发票"))
            } else {
                // 汇总
                HStack {
                    let inputTotal = filteredInvoices.filter { $0.type == .input }.reduce(Decimal.zero) { $0 + $1.taxAmount }
                    let outputTotal = filteredInvoices.filter { $0.type == .output }.reduce(Decimal.zero) { $0 + $1.taxAmount }
                    StatPill(title: "进项税额", value: inputTotal, color: .blue)
                    StatPill(title: "销项税额", value: outputTotal, color: .red)
                    StatPill(title: "发票张数", value: Decimal(filteredInvoices.count), color: .gray, format: "%.0f")
                }
                .padding(.horizontal)
                .padding(.bottom, 4)

                Table(filteredInvoices) {
                    TableColumn("类型") { inv in
                        HStack(spacing: 4) {
                            Circle().fill(inv.type == .input ? Color.blue : Color.red).frame(width: 7)
                            Text(inv.type.rawValue).font(.caption)
                        }
                    }.width(60)
                    TableColumn("发票号码", value: \.invoiceNo).width(120)
                    TableColumn("发票日期") { inv in
                        Text(FMT.date(inv.invoiceDate)).font(.caption)
                    }.width(100)
                    TableColumn("对方") { inv in
                        Text(inv.type == .input ? inv.sellerName : inv.buyerName)
                    }.width(140)
                    TableColumn("不含税金额") { inv in
                        Text("¥\(FMT.amount(inv.amount))")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .monospacedDigit()
                    }.width(110).alignment(.trailing)
                    TableColumn("税额") { inv in
                        Text("¥\(FMT.amount(inv.taxAmount))")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .monospacedDigit()
                            .foregroundStyle(inv.type == .input ? .blue : .red)
                    }.width(100).alignment(.trailing)
                    TableColumn("价税合计") { inv in
                        Text("¥\(FMT.amount(inv.totalAmount))")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .bold().monospacedDigit()
                    }.width(110).alignment(.trailing)
                    TableColumn("税率") { inv in
                        Text("\(Int(inv.taxRate * 100))%")
                            .font(.caption)
                    }.width(55)
                    TableColumn("状态") { inv in
                        HStack(spacing: 4) {
                            Circle().fill(inv.status == .matched ? Color.green : Color.orange).frame(width: 7)
                            Text(inv.status.rawValue).font(.caption)
                                .foregroundStyle(inv.status == .matched ? .green : .orange)
                        }
                    }.width(70)
                    TableColumn("操作") { inv in
                        HStack(spacing: 6) {
                            Button { editingInvoice = inv } label: {
                                Image(systemName: "pencil").font(.caption)
                            }.buttonStyle(.plain).help("编辑")
                            Button { deleteConfirm = inv } label: {
                                Image(systemName: "trash").font(.caption).foregroundStyle(.red)
                            }.buttonStyle(.plain).help("删除")
                        }
                    }.width(70)
                }
                .tableStyle(.bordered)
            }
        }
        .sheet(isPresented: $showAdd) {
            InvoiceEditView(company: company, invoice: nil)
        }
        .sheet(item: $editingInvoice) { inv in
            InvoiceEditView(company: company, invoice: inv)
        }
        .alert("删除发票", isPresented: .init(
            get: { deleteConfirm != nil },
            set: { if !$0 { deleteConfirm = nil } }
        ), presenting: deleteConfirm) { inv in
            Button("取消", role: .cancel) { deleteConfirm = nil }
            Button("删除", role: .destructive) {
                dataStore.deleteInvoice(inv)
                deleteConfirm = nil
            }
        } message: { inv in
            Text("确定删除发票「\(inv.invoiceNo)」？")
        }
    }

    private var filteredInvoices: [Invoice] {
        let all = dataStore.invoices(for: company.id)
            .sorted { $0.invoiceDate > $1.invoiceDate }
        if let t = filterType {
            return all.filter { $0.type == t }
        }
        return all
    }
}

// MARK: - 发票编辑

struct InvoiceEditView: View {
    let company: Company
    let invoice: Invoice?
    @EnvironmentObject var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss

    @State private var invoiceNo = ""
    @State private var invoiceCode = ""
    @State private var invoiceDate = Date()
    @State private var sellerName = ""
    @State private var buyerName = ""
    @State private var amount: Decimal = 0
    @State private var taxAmount: Decimal = 0
    @State private var totalAmount: Decimal = 0
    @State private var taxRate: Double = 0.13
    @State private var type: InvoiceType = .input
    @State private var showError = false
    @State private var errorMessage = ""

    private var isEditing: Bool { invoice != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("发票类型") {
                    Picker("类型", selection: $type) {
                        ForEach(InvoiceType.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("基本信息") {
                    TextField("发票号码", text: $invoiceNo)
                    TextField("发票代码", text: $invoiceCode)
                    DatePicker("开票日期", selection: $invoiceDate, displayedComponents: .date)
                }
                Section("交易方") {
                    TextField(type == .input ? "销售方" : "开票方（本单位）", text: $sellerName)
                    TextField(type == .input ? "购买方（本单位）" : "购买方", text: $buyerName)
                }
                Section("金额") {
                    HStack {
                        Text("不含税金额")
                        TextField("", value: $amount, format: .number.precision(.fractionLength(2)))
                            .multilineTextAlignment(.trailing)
                            .onChange(of: amount) { _, _ in recalc() }
                    }
                    HStack {
                        Picker("税率", selection: $taxRate) {
                            Text("13%").tag(0.13)
                            Text("9%").tag(0.09)
                            Text("6%").tag(0.06)
                            Text("3%").tag(0.03)
                            Text("0%").tag(0.0)
                        }
                        .onChange(of: taxRate) { _, _ in recalc() }
                    }
                    HStack {
                        Text("税额")
                        TextField("", value: $taxAmount, format: .number.precision(.fractionLength(2)))
                            .multilineTextAlignment(.trailing)
                            .onChange(of: taxAmount) { _, _ in recalcTotal() }
                    }
                    HStack {
                        Text("价税合计").bold()
                        TextField("", value: $totalAmount, format: .number.precision(.fractionLength(2)))
                            .multilineTextAlignment(.trailing)
                            .bold()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "编辑发票" : "录入发票")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(invoiceNo.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("错误", isPresented: $showError) {
                Button("确定") {}
            } message: { Text(errorMessage) }
            .onAppear {
                if let inv = invoice {
                    invoiceNo = inv.invoiceNo
                    invoiceCode = inv.invoiceCode
                    invoiceDate = inv.invoiceDate
                    sellerName = inv.sellerName
                    buyerName = inv.buyerName
                    amount = inv.amount
                    taxAmount = inv.taxAmount
                    totalAmount = inv.totalAmount
                    taxRate = inv.taxRate
                    type = inv.type
                }
            }
            .frame(minWidth: 450, minHeight: 420)
        }
    }

    private func recalc() {
        taxAmount = amount * Decimal(taxRate)
        totalAmount = amount + taxAmount
    }

    private func recalcTotal() {
        totalAmount = amount + taxAmount
    }

    private func save() {
        guard !invoiceNo.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "发票号码不能为空"
            showError = true
            return
        }
        guard totalAmount > 0 else {
            errorMessage = "价税合计必须大于零"
            showError = true
            return
        }

        if let inv = invoice {
            inv.invoiceNo = invoiceNo
            inv.invoiceCode = invoiceCode
            inv.invoiceDate = invoiceDate
            inv.sellerName = sellerName
            inv.buyerName = buyerName
            inv.amount = amount
            inv.taxAmount = taxAmount
            inv.totalAmount = totalAmount
            inv.taxRate = taxRate
            inv.type = type
            dataStore.updateInvoice(inv)
        } else {
            let newInv = Invoice(
                invoiceNo: invoiceNo, invoiceCode: invoiceCode, invoiceDate: invoiceDate,
                sellerName: sellerName, buyerName: buyerName,
                amount: amount, taxAmount: taxAmount, totalAmount: totalAmount,
                taxRate: taxRate, type: type
            )
            newInv.companyID = company.id
            dataStore.addInvoice(newInv)
        }
        dismiss()
    }
}

// MARK: - 小指标

private struct StatPill: View {
    let title: String
    let value: Decimal
    let color: Color
    var format: String = "%.2f"

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("¥\(FMT.amount(value))")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.08))
        .cornerRadius(6)
    }
}
