import SwiftUI

struct GeneralLedgerView: View {
    let company: Company
    @EnvironmentObject var dataStore: DataStore
    @State private var selectedAccount: Account?
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var month = Calendar.current.component(.month, from: Date())
    @State private var showTAccount = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("科目", selection: $selectedAccount) {
                    Text("请选择").tag(nil as Account?)
                    ForEach(dataStore.accounts(for: company.id).filter { $0.isActive }.sorted { $0.code < $1.code }) { account in
                        Text("\(account.code) \(account.name)").tag(account as Account?)
                    }
                }
                .frame(width: 300)

                Spacer()

                Picker("年份", selection: $year) {
                    ForEach(availableYears, id: \.self) { y in
                        Text("\(String(y))年").tag(y)
                    }
                }
                .frame(width: 100)

                Picker("月份", selection: $month) {
                    ForEach(1...12, id: \.self) { m in
                        Text("\(String(m))月").tag(m)
                    }
                }
                .frame(width: 80)
                Spacer()
                if selectedAccount != nil {
                    Button {
                        let report = AccountingEngine.generalLedger(for: selectedAccount!, year: year, month: month)
                        if let url = PDFExporter.exportGeneralLedger(report) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("导出PDF", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        showTAccount = true
                    } label: {
                        Label("T型账户", systemImage: "t.square")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()

            Divider()

            if let account = selectedAccount {
                ledgerReport(account: account)
            } else {
                ContentUnavailableView("选择科目", systemImage: "book",
                                       description: Text("请选择一个科目查看总账"))
            }
        }
        .sheet(isPresented: $showTAccount) {
            if let account = selectedAccount {
                TAccountView(account: account, year: year, month: month)
                    .frame(minWidth: 700, minHeight: 500)
            }
        }
    }

    private var availableYears: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 5)...current)
    }

    @ViewBuilder
    private func ledgerReport(account: Account) -> some View {
        let report = AccountingEngine.generalLedger(for: account, year: year, month: month)

        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(account.code) \(account.name)")
                    .font(.title2)
                    .bold()
                HStack(spacing: 20) {
                    Text("科目类别: \(account.category.rawValue)")
                    Text("期初余额: ¥\(FMT.amount(report.openingBalance))")
                    Text("期末余额: ¥\(FMT.amount(report.closingBalance))")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Table(report.lines) {
                TableColumn("日期") { line in
                    Text(FMT.date(line.date))
                }.width(100)
                TableColumn("凭证号", value: \.voucherNumber).width(140)
                TableColumn("摘要", value: \.summary).width(200)
                TableColumn("借方") { line in
                    Text("¥\(FMT.amount(line.debit))")
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(120)
                .alignment(.trailing)
                TableColumn("贷方") { line in
                    Text("¥\(FMT.amount(line.credit))")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(120)
                .alignment(.trailing)
                TableColumn("方向") { line in
                    Text(line.direction)
                        .foregroundStyle(.secondary)
                }.width(50)
                TableColumn("余额") { line in
                    Text("¥\(FMT.amount(line.runningBalance))")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(120)
                .alignment(.trailing)
            }
            .tableStyle(.bordered)
        }
        .padding(.bottom)
        } // end ScrollView
    }
}