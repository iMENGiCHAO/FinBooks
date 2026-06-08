import SwiftUI

// MARK: - 增值税申报表

struct VATReportView: View {
    let company: Company
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var month = Calendar.current.component(.month, from: Date())
    @State private var selectedTab = 0  // 0=汇总, 1=进项明细, 2=销项明细

    private var report: VATReport {
        AccountingEngine.vatReport(for: company, year: year, month: month)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 期间选择
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
                // Tab 切换
                Picker("", selection: $selectedTab) {
                    Text("汇总").tag(0)
                    Text("进项明细").tag(1)
                    Text("销项明细").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                Spacer()
                Button {
                    exportPDF()
                } label: {
                    Label("导出PDF", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            if selectedTab == 0 {
                summaryView
            } else if selectedTab == 1 {
                inputDetailView
            } else {
                outputDetailView
            }
        }
    }

    private var availableYears: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 5)...current)
    }

    // MARK: - 汇总视图

    private var summaryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 页头
                headerView

                // 税额汇总卡片
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    SummaryCell(title: "销项税额", value: report.outputTotal, color: .red)
                    SummaryCell(title: "进项税额", value: report.inputTotal, color: .blue)
                    SummaryCell(title: "进项税额转出", value: report.transferOutTotal, color: .orange)
                    SummaryCell(title: "可抵扣税额", value: report.deductible, color: .green)
                    SummaryCell(title: "应纳增值税", value: report.payable, color: report.payable > 0 ? .red : .gray)
                    SummaryCell(title: "已预缴", value: report.alreadyPaid, color: .blue)
                }
                .padding(.horizontal)

                // 最终应补/退税
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Text("应补（退）税额")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("¥\(FMT.amount(report.stillDue))")
                            .font(.title.bold())
                            .foregroundStyle(report.stillDue > 0 ? .red : .green)
                        Text(report.stillDue > 0 ? "应补缴" : "应退税")
                            .font(.caption)
                            .foregroundStyle(report.stillDue > 0 ? .red : .green)
                    }
                    .padding(24)
                    .frame(width: 280)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(report.stillDue > 0 ? Color.red.opacity(0.06) : Color.green.opacity(0.06))
                    )
                    Spacer()
                }
                .padding(.horizontal)

                // 税率分档
                if !report.rateBreakdown.isEmpty {
                    Divider().padding(.horizontal)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("按税率分档").font(.headline)
                        ForEach(report.rateBreakdown) { rb in
                            HStack {
                                Text("税率 \(rb.rateDisplay)")
                                    .font(.subheadline.bold())
                                    .frame(width: 80, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    if rb.inputAmount > 0 {
                                        Text("进项: ¥\(FMT.amount(rb.inputAmount))")
                                            .font(.caption).foregroundStyle(.blue)
                                    }
                                    if rb.outputAmount > 0 {
                                        Text("销项: ¥\(FMT.amount(rb.outputAmount))")
                                            .font(.caption).foregroundStyle(.red)
                                    }
                                }
                                Spacer()
                                let net = rb.outputAmount - rb.inputAmount
                                Text("¥\(FMT.amount(net))")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(net >= 0 ? .red : .green)
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                    .padding(.horizontal)
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("增值税申报表").font(.title).bold()
                Text("（一般纳税人）").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            Text("所属期：\(report.period)")
                .font(.caption).foregroundStyle(.secondary)
            Text("纳税人名称：\(report.companyName)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - 进项明细

    private var inputDetailView: some View {
        VStack {
            if report.inputDetails.isEmpty {
                ContentUnavailableView("本期无进项税额", systemImage: "arrow.down.doc",
                                       description: Text("未在此期间的凭证中检测到进项税额分录"))
            } else {
                Table(report.inputDetails) {
                    TableColumn("凭证号", value: \.voucherNumber).width(100)
                    TableColumn("摘要", value: \.summary).width(200)
                    TableColumn("税率") { l in
                        Text(l.rateDisplay).font(.caption).monospacedDigit()
                    }.width(70)
                    TableColumn("税额") { l in
                        Text("¥\(FMT.amount(l.amount))")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .monospacedDigit()
                            .foregroundStyle(.blue)
                    }.width(120).alignment(.trailing)
                }
                .tableStyle(.bordered)

                HStack {
                    Spacer()
                    Text("进项税额合计：¥\(FMT.amount(report.inputTotal))")
                        .font(.headline).padding()
                    Spacer()
                }
            }
        }
    }

    // MARK: - 销项明细

    private var outputDetailView: some View {
        VStack {
            if report.outputDetails.isEmpty {
                ContentUnavailableView("本期无销项税额", systemImage: "arrow.up.doc",
                                       description: Text("未在此期间的凭证中检测到销项税额分录"))
            } else {
                Table(report.outputDetails) {
                    TableColumn("凭证号", value: \.voucherNumber).width(100)
                    TableColumn("摘要", value: \.summary).width(200)
                    TableColumn("税率") { l in
                        Text(l.rateDisplay).font(.caption).monospacedDigit()
                    }.width(70)
                    TableColumn("税额") { l in
                        Text("¥\(FMT.amount(l.amount))")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .monospacedDigit()
                            .foregroundStyle(.red)
                    }.width(120).alignment(.trailing)
                }
                .tableStyle(.bordered)

                HStack {
                    Spacer()
                    Text("销项税额合计：¥\(FMT.amount(report.outputTotal))")
                        .font(.headline).padding()
                    Spacer()
                }
            }
        }
    }

    // MARK: - PDF 导出

    private func exportPDF() {
        guard let url = PDFExporter.exportVATReport(report) else { return }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}

// MARK: - 汇总卡片

private struct SummaryCell: View {
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
        .background(color.opacity(0.06))
        .cornerRadius(8)
    }
}
