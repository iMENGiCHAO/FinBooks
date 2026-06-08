import SwiftUI

// MARK: - T 型账户可视化

struct TAccountView: View {
    let account: Account
    @State private var year: Int
    @State private var month: Int
    
    init(account: Account, year: Int? = nil, month: Int? = nil) {
        self.account = account
        let now = Date()
        let cal = Calendar.current
        _year = State(initialValue: year ?? cal.component(.year, from: now))
        _month = State(initialValue: month ?? cal.component(.month, from: now))
    }
    
    private var tData: TAccountData {
        AccountingEngine.tAccount(for: account, year: year, month: month)
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
            // 标题
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(account.code) \(account.name)")
                        .font(.title3.bold())
                    Text("类别：\(account.category.rawValue)")
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
            
            // T 型账户
            HStack(alignment: .top, spacing: 0) {
                // 借方（左侧）
                VStack(spacing: 0) {
                    HStack {
                        Text("借方")
                            .font(.headline)
                            .foregroundStyle(.blue)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.08))
                    
                    Divider()
                    
                    if tData.debitEntries.isEmpty {
                        VStack(spacing: 4) {
                            Image(systemName: "minus.circle")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                            Text("本期无借方发生额")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(24)
                    } else {
                        ForEach(Array(tData.debitEntries.enumerated()), id: \.offset) { _, entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.voucherNumber)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Text(entry.summary)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text("¥\(FMT.amount(entry.amount))")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.blue)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .overlay(
                    Rectangle()
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                
                // 贷方（右侧）
                VStack(spacing: 0) {
                    HStack {
                        Text("贷方")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.08))
                    
                    Divider()
                    
                    if tData.creditEntries.isEmpty {
                        VStack(spacing: 4) {
                            Image(systemName: "minus.circle")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                            Text("本期无贷方发生额")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(24)
                    } else {
                        ForEach(Array(tData.creditEntries.enumerated()), id: \.offset) { _, entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.voucherNumber)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Text(entry.summary)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text("¥\(FMT.amount(entry.amount))")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.red)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .overlay(
                    Rectangle()
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
            }
            .frame(minHeight: 200)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            
            // 余额信息
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("期初余额")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("¥\(FMT.amount(abs(tData.openingBalance)))")
                        .font(.subheadline.bold())
                    Text(tData.openingBalance >= 0
                         ? (account.category.nature == .debit ? "借" : "贷")
                         : (account.category.nature == .debit ? "贷" : "借"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Divider().frame(height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("本期借方合计")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("¥\(FMT.amount(tData.totalDebit))")
                        .font(.subheadline.bold())
                        .foregroundStyle(.blue)
                }
                Divider().frame(height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("本期贷方合计")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("¥\(FMT.amount(tData.totalCredit))")
                        .font(.subheadline.bold())
                        .foregroundStyle(.red)
                }
                Divider().frame(height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("期末余额")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("¥\(FMT.amount(abs(tData.closingBalance)))")
                        .font(.title3.bold())
                    Text(tData.closingDirection)
                        .font(.caption)
                        .foregroundStyle(tData.closingDirection == "借" ? .blue : .red)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
        .padding()
        .frame(minWidth: 500, minHeight: 450)
        } // end ScrollView
    }
}