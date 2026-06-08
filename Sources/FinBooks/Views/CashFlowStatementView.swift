import SwiftUI

// MARK: - 现金流量表视图

struct CashFlowStatementView: View {
    let company: Company
    @State private var year: Int
    @State private var month: Int
    
    init(company: Company, year: Int? = nil, month: Int? = nil) {
        self.company = company
        let now = Date()
        let cal = Calendar.current
        _year = State(initialValue: year ?? cal.component(.year, from: now))
        _month = State(initialValue: month ?? cal.component(.month, from: now))
    }
    
    private var report: CashFlowReport {
        AccountingEngine.cashFlowStatement(for: company, year: year, month: month)
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Beta 声明
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Beta — 现金流量表分类逻辑仍在完善中，请以资产负债表和利润表为准")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(6)
                .padding(.horizontal)
                
                // 标题
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("现金流量表")
                            .font(.largeTitle.bold())
                        Text("编制单位：\(company.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Picker("", selection: $year) {
                            ForEach((year - 2)...(year + 2), id: \.self) { y in
                                Text("\(String(y))年").tag(y)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 90)
                        Picker("", selection: $month) {
                            ForEach(1...12, id: \.self) { m in
                                Text("\(String(m))月").tag(m)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 70)
                    }
                }
                .padding(.horizontal)
                
                // 汇总卡片
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    SummaryCard(title: "期初现金", value: report.beginningCash, color: .blue)
                    SummaryCard(title: "经营净流量", value: report.operatingNet, color: report.operatingNet >= 0 ? .green : .red)
                    SummaryCard(title: "投资净流量", value: report.investingNet, color: report.investingNet >= 0 ? .green : .red)
                    SummaryCard(title: "筹资净流量", value: report.financingNet, color: report.financingNet >= 0 ? .green : .red)
                }
                .padding(.horizontal)
                
                // 期末现金
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Text("期末现金余额")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("¥\(FMT.amount(report.endingCash))")
                            .font(.title.bold())
                            .foregroundStyle(report.endingCash >= 0 ? .green : .red)
                    }
                    Spacer()
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal)
                
                // 经营活动现金流量
                cashFlowSection(title: "一、经营活动现金流量", color: .blue,
                                 inflows: report.operatingInflows, outflows: report.operatingOutflows,
                                 net: report.operatingNet, totalIn: report.operatingInflowsTotal, totalOut: report.operatingOutflowsTotal)
                
                // 投资活动现金流量
                cashFlowSection(title: "二、投资活动现金流量", color: .purple,
                                 inflows: report.investingInflows, outflows: report.investingOutflows,
                                 net: report.investingNet, totalIn: report.investingInflowsTotal, totalOut: report.investingOutflowsTotal)
                
                // 筹资活动现金流量
                cashFlowSection(title: "三、筹资活动现金流量", color: .orange,
                                 inflows: report.financingInflows, outflows: report.financingOutflows,
                                 net: report.financingNet, totalIn: report.financingInflowsTotal, totalOut: report.financingOutflowsTotal)
                
                // 汇率变动影响（TODO）
                
                // 合计
                GroupBox {
                    HStack {
                        Text("现金净增加额")
                            .font(.headline)
                        Spacer()
                        Text("¥\(FMT.amount(report.netCashFlow))")
                            .font(.title2.bold())
                            .foregroundStyle(report.netCashFlow >= 0 ? .green : .red)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }
    
    private func cashFlowSection(title: String, color: Color, inflows: [CashFlowLine], outflows: [CashFlowLine],
                                  net: Decimal, totalIn: Decimal, totalOut: Decimal) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(color)
                
                if !inflows.isEmpty {
                    Text("流入：")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                    ForEach(inflows) { item in
                        HStack {
                            Text(item.name)
                                .font(.subheadline)
                            Spacer()
                            Text("¥\(FMT.amount(item.amount))")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.green)
                        }
                    }
                    HStack {
                        Text("  小计")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("¥\(FMT.amount(totalIn))")
                            .font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(.green)
                    }
                }
                
                if !outflows.isEmpty {
                    Text("流出：")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                    ForEach(outflows) { item in
                        HStack {
                            Text(item.name)
                                .font(.subheadline)
                            Spacer()
                            Text("(¥\(FMT.amount(item.amount)))")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.red)
                        }
                    }
                    HStack {
                        Text("  小计")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("(¥\(FMT.amount(totalOut)))")
                            .font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(.red)
                    }
                }
                
                Divider()
                
                HStack {
                    Text("净额")
                        .font(.subheadline.bold())
                    Spacer()
                    Text("¥\(FMT.amount(net))")
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(net >= 0 ? .green : .red)
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal)
    }
}

struct SummaryCard: View {
    let title: String
    let value: Decimal
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("¥\(FMT.amount(value))")
                .font(.title3.bold())
                .foregroundStyle(color)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }
}