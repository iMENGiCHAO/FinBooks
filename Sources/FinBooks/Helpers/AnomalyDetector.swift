import Foundation
import SwiftUI

// MARK: - 财务异常检测引擎

@MainActor
final class AnomalyDetector: ObservableObject {
    static let shared = AnomalyDetector()
    
    @Published var anomalies: [Anomaly] = []
    @Published var lastScanTime: Date?
    
    private init() {}
    
    /// 扫描公司所有凭证，检测异常
    func scan(companyID: UUID) {
        let store = DataStore.shared
        let entries = store.entries(for: companyID)
        let accounts = store.accounts(for: companyID)
        
        var results: [Anomaly] = []
        
        // 1. 借贷不平的凭证
        for entry in entries {
            if !entry.isBalanced && entry.debitTotal > 0 {
                results.append(Anomaly(
                    severity: .critical,
                    type: .unbalanced,
                    title: "借贷不平衡",
                    detail: "凭证 \(entry.number)：借方¥\(FMT.amount(entry.debitTotal)) ≠ 贷方¥\(FMT.amount(entry.creditTotal))",
                    entry: entry
                ))
            }
        }
        
        // 2. 大额异常凭证（超过平均金额5倍）
        let postedAmounts = entries.filter { $0.isPosted }.map { $0.debitTotal }
        if !postedAmounts.isEmpty {
            let avg = postedAmounts.reduce(Decimal.zero, +) / Decimal(postedAmounts.count)
            let threshold = avg * 5
            for entry in entries where entry.isPosted && entry.debitTotal > threshold && entry.debitTotal > 100000 {
                results.append(Anomaly(
                    severity: .warning,
                    type: .largeAmount,
                    title: "大额凭证",
                    detail: "凭证 \(entry.number)：¥\(FMT.amount(entry.debitTotal))，远超平均¥\(FMT.amount(avg))",
                    entry: entry
                ))
            }
        }
        
        // 3. 科目余额方向异常（使用 effectiveBalanceDirection 正确处理累计折旧等）
        for account in accounts where account.isActive {
            let bal = AccountingEngine.balance(for: account)
            let dir = account.effectiveBalanceDirection
            if dir == .debit && bal < 0 {
                results.append(Anomaly(
                    severity: .warning,
                    type: .balanceDirection,
                    title: "\(account.name)余额异常",
                    detail: "\(account.code) \(account.name) 余额为 ¥\(FMT.amount(bal))（借方科目不应为负数）",
                    account: account
                ))
            } else if dir == .credit && bal < 0 {
                results.append(Anomaly(
                    severity: .warning,
                    type: .balanceDirection,
                    title: "\(account.name)余额异常",
                    detail: "\(account.code) \(account.name) 余额为 ¥\(FMT.amount(bal))（贷方科目不应出现借方余额）",
                    account: account
                ))
            }
        }
        
        // 4. 重复凭证检测（同日期、同金额、同摘要）
        let groupedByDate = Dictionary(grouping: entries.filter { $0.isPosted }) { $0.date }
        for (_, group) in groupedByDate where group.count > 1 {
            for i in 0..<group.count {
                for j in (i+1)..<group.count {
                    let a = group[i], b = group[j]
                    if a.debitTotal == b.debitTotal &&
                       a.creditTotal == b.creditTotal &&
                       a.summary == b.summary {
                        results.append(Anomaly(
                            severity: .info,
                            type: .duplicate,
                            title: "可能的重复凭证",
                            detail: "\(a.number) 和 \(b.number) 日期、金额、摘要相同",
                            entry: a
                        ))
                    }
                }
            }
        }
        
        // 5. 未过账凭证数量
        let unposted = entries.filter { !$0.isPosted }
        if unposted.count > 5 {
            results.append(Anomaly(
                severity: .info,
                type: .unposted,
                title: "未过账凭证过多",
                detail: "有 \(unposted.count) 张凭证未过账",
                count: unposted.count
            ))
        }
        
        anomalies = results
        lastScanTime = Date()
    }
    
    var criticalCount: Int { anomalies.filter { $0.severity == .critical }.count }
    var warningCount: Int { anomalies.filter { $0.severity == .warning }.count }
    var infoCount: Int { anomalies.filter { $0.severity == .info }.count }
    
    var hasCriticalIssues: Bool { criticalCount > 0 }
    var hasWarnings: Bool { warningCount > 0 }
}

// MARK: - 异常模型
struct Anomaly: Identifiable {
    let id = UUID()
    let severity: Severity
    let type: AnomalyType
    let title: String
    let detail: String
    var entry: JournalEntry?
    var account: Account?
    var count: Int?
    
    enum Severity: String, Comparable {
        case critical = "严重"
        case warning = "警告"
        case info = "提示"
        
        var color: Color {
            switch self {
            case .critical: return .red
            case .warning: return .orange
            case .info: return .blue
            }
        }
        
        static func < (lhs: Severity, rhs: Severity) -> Bool {
            let order: [Severity] = [.critical, .warning, .info]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }
    
    enum AnomalyType: String {
        case unbalanced = "借贷不平"
        case largeAmount = "大额异常"
        case balanceDirection = "余额方向"
        case duplicate = "重复凭证"
        case unposted = "未过账"
    }
}

// MARK: - 异常检测面板 UI

struct AnomalyBanner: View {
    let company: Company
    @StateObject private var detector = AnomalyDetector.shared
    @State private var showSheet = false
    
    var body: some View {
        if detector.hasCriticalIssues || detector.hasWarnings {
            Button {
                detector.scan(companyID: company.id)
                showSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(detector.hasCriticalIssues ? .red : .orange)
                    Text("发现 \(detector.criticalCount + detector.warningCount) 个问题")
                        .font(.subheadline.bold())
                    if detector.warningCount > 0 {
                        Text("(\(detector.warningCount) 警告)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if detector.criticalCount > 0 {
                        Text("(\(detector.criticalCount) 严重)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(detector.hasCriticalIssues ? Color.red.opacity(0.1) : Color.orange.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(detector.hasCriticalIssues ? Color.red.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .sheet(isPresented: $showSheet) {
                AnomalySheetView(company: company, detector: detector)
            }
        }
    }
}

struct AnomalySheetView: View {
    let company: Company
    @ObservedObject var detector: AnomalyDetector
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedSeverity: Anomaly.Severity?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 严重级别筛选
                HStack(spacing: 6) {
                    severityChip("全部", selected: selectedSeverity == nil) { selectedSeverity = nil }
                    severityChip("严重", selected: selectedSeverity == .critical) { selectedSeverity = .critical }
                    severityChip("警告", selected: selectedSeverity == .warning) { selectedSeverity = .warning }
                    severityChip("提示", selected: selectedSeverity == .info) { selectedSeverity = .info }
                    Spacer()
                    Button("重新扫描") {
                        detector.scan(companyID: company.id)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
                .padding()
                
                Divider()
                
                let filtered = selectedSeverity == nil ? detector.anomalies : detector.anomalies.filter { $0.severity == selectedSeverity }
                
                if filtered.isEmpty {
                    ContentUnavailableView("未发现异常", systemImage: "checkmark.circle",
                                           description: Text("数据一切正常"))
                } else {
                    List {
                        ForEach(filtered.sorted(by: { $0.severity > $1.severity })) { anomaly in
                            AnomalyRow(anomaly: anomaly)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("异常检测")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .frame(width: 520, height: 500)
            .onAppear {
                detector.scan(companyID: company.id)
            }
        }
    }
    
    private func severityChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                .foregroundStyle(selected ? .white : .primary)
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}

struct AnomalyRow: View {
    let anomaly: Anomaly
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(anomaly.severity.color)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(anomaly.title)
                        .font(.subheadline.bold())
                    Text(anomaly.severity.rawValue)
                        .font(.caption2)
                        .foregroundStyle(anomaly.severity.color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(anomaly.severity.color.opacity(0.12))
                        .cornerRadius(4)
                }
                Text(anomaly.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 在 DashboardView 中添加异常横幅
// 扩展 DashboardView
extension DashboardView {
    func anomalySection(company: Company) -> some View {
        AnomalyBanner(company: company)
            .onAppear {
                AnomalyDetector.shared.scan(companyID: company.id)
            }
    }
}