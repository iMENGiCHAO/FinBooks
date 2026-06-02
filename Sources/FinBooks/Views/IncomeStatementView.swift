import SwiftUI

struct IncomeStatementView: View {
    let company: Company
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var month = Calendar.current.component(.month, from: Date())

    private static let expenseItems: [(code: String, label: String)] = [
        ("6001", "营业成本"), ("6401", "税金及附加"),
        ("6601", "销售费用"), ("6602", "管理费用"), ("6603", "财务费用"),
    ]
    private static let otherExclude: Set<String> = ["6001","6401","6601","6602","6603","6801"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("年份", selection: $year) {
                    ForEach(availableYears, id: \.self) { y in
                        Text("\(String(y))年").tag(y)
                    }
                }
                .frame(width: 120)
                Picker("月份", selection: $month) {
                    ForEach(1...12, id: \.self) { m in
                        Text("\(String(m))月").tag(m)
                    }
                }
                .frame(width: 100)
                Spacer()
                Button {
                    let report = AccountingEngine.incomeStatement(for: company, year: year, month: month)
                    if let url = PDFExporter.exportIncomeStatement(report) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("导出PDF", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            let report = AccountingEngine.incomeStatement(for: company, year: year, month: month)
            reportView(report)
        }
    }

    private var availableYears: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 5)...current)
    }

    @ViewBuilder
    private func reportView(_ report: IncomeStatementReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerView(report: report)
                contentBody(report: report)
            }
            .padding(.vertical)
        }
    }

    private func headerView(report: IncomeStatementReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("利润表").font(.title).bold()
            Text("会企02表").font(.caption).foregroundStyle(.secondary)
            Text("编制单位：\(report.companyName)")
            Text("\(report.year)年\(report.month)月    单位：\(report.currency)")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func contentBody(report: IncomeStatementReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 表头
            HStack {
                Text("项目").bold()
                    .frame(width: 180, alignment: .leading)
                Spacer()
                Text("本期金额").bold()
                    .frame(width: 110, alignment: .trailing)
                Text("本年累计").bold()
                    .frame(width: 110, alignment: .trailing)
            }
            .font(.subheadline)
            .padding(.horizontal)
            .padding(.bottom, 4)

            Divider()

            // 一、营业收入
            Text("一、营业收入").font(.headline)
                .padding(.horizontal)
                .padding(.top, 8)

            ForEach(report.revenues) { item in
                HStack {
                    Text("  \(item.name)")
                        .frame(width: 180, alignment: .leading)
                    Spacer()
                    Text("¥\(FMT.amount(item.amount))")
                        .monospacedDigit()
                        .frame(width: 110, alignment: .trailing)
                    Text("¥\(FMT.amount(item.cumulativeAmount))")
                        .monospacedDigit()
                        .frame(width: 110, alignment: .trailing)
                }
                .font(.subheadline)
                .padding(.horizontal)
            }

            HStack {
                Text("  营业收入合计").bold()
                    .frame(width: 180, alignment: .leading)
                Spacer()
                Text("¥\(FMT.amount(report.totalRevenue))").bold()
                    .monospacedDigit()
                    .frame(width: 110, alignment: .trailing)
                Text("¥\(FMT.amount(report.totalRevenueCumulative))").bold()
                    .monospacedDigit()
                    .frame(width: 110, alignment: .trailing)
            }
            .padding(.horizontal)
            .padding(.top, 2)

            Divider().padding(.vertical, 6)

            // 费用项
            Text("减：").font(.headline)
                .padding(.horizontal)

            ForEach(Self.expenseItems, id: \.code) { item in
                if let exp = report.expenses.first(where: { $0.code == item.code }) {
                    HStack {
                        Text("  \(item.label)")
                            .frame(width: 180, alignment: .leading)
                        Spacer()
                        Text("¥\(FMT.amount(exp.amount))")
                            .monospacedDigit()
                            .frame(width: 110, alignment: .trailing)
                        Text("¥\(FMT.amount(exp.cumulativeAmount))")
                            .monospacedDigit()
                            .frame(width: 110, alignment: .trailing)
                    }
                    .font(.subheadline)
                    .padding(.horizontal)
                }
            }

            let otherExp = report.expenses.filter { !Self.otherExclude.contains($0.code) }
            ForEach(otherExp) { item in
                HStack {
                    Text("  \(item.name)")
                        .frame(width: 180, alignment: .leading)
                    Spacer()
                    Text("¥\(FMT.amount(item.amount))")
                        .monospacedDigit()
                        .frame(width: 110, alignment: .trailing)
                    Text("¥\(FMT.amount(item.cumulativeAmount))")
                        .monospacedDigit()
                        .frame(width: 110, alignment: .trailing)
                }
                .font(.subheadline)
                .padding(.horizontal)
            }

            Divider().padding(.vertical, 6)

            // 营业利润
            HStack {
                Text("二、营业利润").bold()
                    .frame(width: 180, alignment: .leading)
                Spacer()
                Text("¥\(FMT.amount(report.operatingProfit))")
                    .bold().monospacedDigit()
                    .foregroundStyle(report.operatingProfit >= 0 ? .green : .red)
                    .frame(width: 110, alignment: .trailing)
                Text("¥\(FMT.amount(report.operatingProfitCumulative))")
                    .bold().monospacedDigit()
                    .foregroundStyle(report.operatingProfitCumulative >= 0 ? .green : .red)
                    .frame(width: 110, alignment: .trailing)
            }
            .padding(.horizontal)
            .padding(.top, 4)

            Divider().padding(.vertical, 6)

            // 所得税
            HStack {
                Text("减：所得税费用")
                    .frame(width: 180, alignment: .leading)
                Spacer()
                Text("¥\(FMT.amount(report.incomeTax))")
                    .monospacedDigit()
                    .frame(width: 110, alignment: .trailing)
                Text("¥\(FMT.amount(report.incomeTaxCumulative))")
                    .monospacedDigit()
                    .frame(width: 110, alignment: .trailing)
            }
            .font(.subheadline)
            .padding(.horizontal)

            Divider().padding(.vertical, 6)

            // 净利润
            HStack {
                Text("三、净利润").bold()
                    .frame(width: 180, alignment: .leading)
                Spacer()
                Text("¥\(FMT.amount(report.netProfit))")
                    .bold().font(.title3).monospacedDigit()
                    .foregroundStyle(report.netProfit >= 0 ? .green : .red)
                    .frame(width: 110, alignment: .trailing)
                Text("¥\(FMT.amount(report.netProfitCumulative))")
                    .bold().font(.title3).monospacedDigit()
                    .foregroundStyle(report.netProfitCumulative >= 0 ? .green : .red)
                    .frame(width: 110, alignment: .trailing)
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .padding(.horizontal)
    }
}
