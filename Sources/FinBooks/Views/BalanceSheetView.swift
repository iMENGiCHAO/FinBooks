import SwiftUI

struct BalanceSheetView: View {
    let company: Company
    @State private var asOfDate: Date = Date()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                DatePicker("截止日期", selection: $asOfDate, displayedComponents: .date)
                    .datePickerStyle(.field)
                    .frame(width: 200)
                Spacer()
                Button {
                    asOfDate = Date()
                } label: {
                    Label("今天", systemImage: "arrow.uturn.backward")
                }
                Spacer()
                Button {
                    let report = AccountingEngine.balanceSheet(for: company, asOf: asOfDate)
                    if let url = PDFExporter.exportBalanceSheet(report) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("导出PDF", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            let report = AccountingEngine.balanceSheet(for: company, asOf: asOfDate)
            reportView(report)
        }
    }

    @ViewBuilder
    private func reportView(_ report: BalanceSheetReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("资产负债表")
                            .font(.title)
                            .bold()
                        Text("会企01表")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("编制单位：\(report.companyName)")
                        Text("截止日期：\(FMT.date(report.date))    单位：\(report.currency)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)

                HStack(alignment: .top, spacing: 32) {
                    // 左侧：资产
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("资产").font(.headline)
                                .frame(width: 130, alignment: .leading)
                            Text("期末余额").font(.caption).foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)
                            Text("年初余额").font(.caption).foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)
                        }
                        .padding(.bottom, 4)

                        Text("流动资产：")
                            .font(.subheadline).bold()
                            .padding(.top, 2)
                        ForEach(report.currentAssets) { item in
                            balanceRow(item)
                        }

                        Text("非流动资产：")
                            .font(.subheadline).bold()
                            .padding(.top, 2)
                        ForEach(report.nonCurrentAssets) { item in
                            balanceRow(item)
                        }

                        Divider()
                        HStack {
                            Text("资产总计").bold()
                                .frame(width: 130, alignment: .leading)
                            Spacer()
                            Text("¥\(FMT.amount(report.totalAssets))")
                                .bold()
                                .frame(width: 90, alignment: .trailing)
                            Text("¥\(FMT.amount(report.totalAssetsBeginning))")
                                .bold()
                                .frame(width: 90, alignment: .trailing)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // 右侧：负债及所有者权益
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("负债及所有者权益").font(.headline)
                                .frame(width: 130, alignment: .leading)
                            Text("期末余额").font(.caption).foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)
                            Text("年初余额").font(.caption).foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)
                        }
                        .padding(.bottom, 4)

                        Text("流动负债：")
                            .font(.subheadline).bold()
                            .padding(.top, 2)
                        ForEach(report.currentLiabilities) { item in
                            balanceRow(item)
                        }

                        Text("非流动负债：")
                            .font(.subheadline).bold()
                            .padding(.top, 2)
                        ForEach(report.nonCurrentLiabilities) { item in
                            balanceRow(item)
                        }

                        Divider()
                        HStack {
                            Text("负债合计").bold()
                                .frame(width: 130, alignment: .leading)
                            Spacer()
                            Text("¥\(FMT.amount(report.totalLiabilities))")
                                .bold()
                                .frame(width: 90, alignment: .trailing)
                            Text("¥\(FMT.amount(report.totalLiabilitiesBeginning))")
                                .bold()
                                .frame(width: 90, alignment: .trailing)
                        }

                        Text("所有者权益：")
                            .font(.subheadline).bold()
                            .padding(.top, 8)
                        ForEach(report.equities) { item in
                            balanceRow(item)
                        }

                        Divider()
                        HStack {
                            Text("所有者权益合计").bold()
                                .frame(width: 130, alignment: .leading)
                            Spacer()
                            Text("¥\(FMT.amount(report.totalEquities))")
                                .bold()
                                .frame(width: 90, alignment: .trailing)
                            Text("¥\(FMT.amount(report.totalEquitiesBeginning))")
                                .bold()
                                .frame(width: 90, alignment: .trailing)
                        }

                        Divider()
                        HStack {
                            Text("负债及所有者权益总计").bold()
                                .frame(width: 130, alignment: .leading)
                            Spacer()
                            Text("¥\(FMT.amount(report.totalLE))")
                                .bold()
                                .frame(width: 90, alignment: .trailing)
                            Text("¥\(FMT.amount(report.totalLEBeginning))")
                                .bold()
                                .frame(width: 90, alignment: .trailing)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    private func balanceRow(_ item: BalanceLine) -> some View {
        HStack {
            Text("  \(item.name)")
                .frame(width: 130, alignment: .leading)
            Spacer()
            Text("¥\(FMT.amount(item.balance))")
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)
            Text("¥\(FMT.amount(item.beginningBalance))")
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)
        }
        .font(.subheadline)
    }
}
