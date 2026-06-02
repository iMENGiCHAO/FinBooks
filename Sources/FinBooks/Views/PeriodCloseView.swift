import SwiftUI

struct PeriodCloseView: View {
    let company: Company
    @EnvironmentObject var dataStore: DataStore
    @State private var selectedYear = Calendar.current.component(.year, from: Date())
    @State private var selectedMonth = Calendar.current.component(.month, from: Date())
    @State private var showConfirm = false
    @State private var showResult = false
    @State private var resultMessage = ""
    @State private var isSuccess = false

    private var isClosed: Bool {
        dataStore.isPeriodClosed(companyID: company.id, year: selectedYear, month: selectedMonth)
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(isClosed ? .green : .blue)

            Text("期末结账")
                .font(.largeTitle)
                .bold()

            Text("结账后将损益类科目余额结转至本年利润，\n并锁定该期间凭证不允许修改。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

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
            }

            if isClosed {
                VStack(spacing: 8) {
                    Label("该期间已结账", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                    if let pc = dataStore.periodCloses.first(where: {
                        $0.companyID == company.id && $0.year == selectedYear && $0.month == selectedMonth && $0.isClosed
                    }), let closedAt = pc.closedAt {
                        Text("结账时间: \(FMT.date(closedAt, format: "yyyy-MM-dd HH:mm"))")
                            .foregroundStyle(.secondary)
                        Text("经办人: \(pc.closedBy)")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }

            if !isClosed {
                Button {
                    showConfirm = true
                } label: {
                    Label("执行结账", systemImage: "lock")
                        .padding(.horizontal, 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
            }

            // 已结账期间列表
            let closedPeriods = dataStore.periodCloses
                .filter { $0.companyID == company.id && $0.isClosed }
                .sorted { ($0.year, $0.month) > ($1.year, $1.month) }
            if !closedPeriods.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("已结账期间").font(.headline)
                    ForEach(closedPeriods.prefix(6)) { pc in
                        HStack {
                            Text("\(String(pc.year))年\(String(pc.month))月")
                            Spacer()
                            Text("已结账")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                        .font(.subheadline)
                    }
                }
                .padding()
                .frame(maxWidth: 300)
            }

            Spacer()
        }
        .padding(.top, 40)
        .frame(minHeight: 500)
        .alert("确认结账", isPresented: $showConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认结账", role: .destructive) { doClose() }
        } message: {
            Text("将执行 \(selectedYear)年\(selectedMonth)月的期末结账。\n此操作不可逆，是否继续？")
        }
        .alert(isSuccess ? "结账成功" : "结账失败", isPresented: $showResult) {
            Button("确定") {}
        } message: {
            Text(resultMessage)
        }
    }

    private var availableYears: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 5)...current)
    }

    private func doClose() {
        do {
            try AccountingEngine.closePeriod(for: company, year: selectedYear, month: selectedMonth)

            let pc = PeriodClose(year: selectedYear, month: selectedMonth, closedBy: "管理员")
            pc.isClosed = true
            pc.closedAt = Date()
            pc.companyID = company.id
            dataStore.addPeriodClose(pc)

            resultMessage = "\(selectedYear)年\(selectedMonth)月结账完成！\n损益类科目已结转至本年利润。"
            isSuccess = true
        } catch {
            resultMessage = "结账失败: \(error.localizedDescription)"
            isSuccess = false
        }
        showResult = true
    }
}
