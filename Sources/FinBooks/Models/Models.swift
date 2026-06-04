import SwiftUI
import Foundation
import Combine

// MARK: - 公司
final class Company: Codable, Identifiable, ObservableObject, Hashable {
    static func == (lhs: Company, rhs: Company) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var id: UUID
    var name: String
    var legalName: String
    var taxId: String
    var address: String
    var phone: String
    var fiscalYearStart: String
    var currency: String
    var createdAt: Date
    var updatedAt: Date

    init(name: String, legalName: String = "", taxId: String = "", address: String = "", phone: String = "",
         fiscalYearStart: String = "01-01", currency: String = "CNY") {
        self.id = UUID()
        self.name = name
        self.legalName = legalName
        self.taxId = taxId
        self.address = address
        self.phone = phone
        self.fiscalYearStart = fiscalYearStart
        self.currency = currency
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - 会计科目
final class Account: Codable, Identifiable, ObservableObject, Hashable {
    static func == (lhs: Account, rhs: Account) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var id: UUID
    var code: String
    var name: String
    var category: AccountCategory
    var parentCode: String?
    var isActive: Bool
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
    var companyID: UUID?

    init(code: String, name: String, category: AccountCategory, parentCode: String? = nil,
         isActive: Bool = true, sortOrder: Int = 0) {
        self.id = UUID()
        self.code = code
        self.name = name
        self.category = category
        self.parentCode = parentCode
        self.isActive = isActive
        self.sortOrder = sortOrder
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

enum AccountCategory: String, Codable, CaseIterable, Identifiable {
    case asset = "资产"
    case liability = "负债"
    case equity = "所有者权益"
    case revenue = "收入"
    case expense = "费用"

    var id: String { rawValue }

    var nature: Nature {
        switch self {
        case .asset, .expense: return .debit
        case .liability, .equity, .revenue: return .credit
        }
    }
    enum Nature: String, Codable { case debit, credit }
}

// MARK: - 凭证
final class JournalEntry: Codable, Identifiable, ObservableObject, Hashable {
    static func == (lhs: JournalEntry, rhs: JournalEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var id: UUID
    var number: String
    var date: Date
    var summary: String
    var attachmentCount: Int
    var isPosted: Bool
    var createdAt: Date
    var updatedAt: Date
    var companyID: UUID?
    var lines: [JournalLine] = []

    var debitTotal: Decimal { lines.reduce(Decimal.zero) { $0 + $1.debit } }
    var creditTotal: Decimal { lines.reduce(Decimal.zero) { $0 + $1.credit } }
    var isBalanced: Bool { debitTotal == creditTotal }

    init(number: String, date: Date, summary: String, attachmentCount: Int = 0, isPosted: Bool = false) {
        self.id = UUID()
        self.number = number
        self.date = date
        self.summary = summary
        self.attachmentCount = attachmentCount
        self.isPosted = isPosted
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - 分录行
final class JournalLine: Codable, Identifiable, ObservableObject, Hashable {
    static func == (lhs: JournalLine, rhs: JournalLine) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var id: UUID
    var summary: String
    var debit: Decimal
    var credit: Decimal
    var entryID: UUID?
    var accountID: UUID?
    @available(*, deprecated, message: "使用 resolvedAccountCode")
    var accountCode: String = ""
    @available(*, deprecated, message: "使用 resolvedAccountName")
    var accountName: String = ""

    /// 从科目表反查科目编码
    @MainActor
    var resolvedAccountCode: String {
        guard let aid = accountID else { return self.accountCode }
        return DataStore.shared.accounts.first(where: { $0.id == aid })?.code ?? self.accountCode
    }
    /// 从科目表反查科目名称
    @MainActor
    var resolvedAccountName: String {
        guard let aid = accountID else { return self.accountName }
        return DataStore.shared.accounts.first(where: { $0.id == aid })?.name ?? self.accountName
    }

    init(summary: String = "", debit: Decimal = .zero, credit: Decimal = .zero) {
        self.id = UUID()
        self.summary = summary
        self.debit = debit
        self.credit = credit
        // accountCode 和 accountName 保留默认空值
    }
}

// MARK: - PeriodClose
final class PeriodClose: Codable, Identifiable, ObservableObject, Hashable {
    static func == (lhs: PeriodClose, rhs: PeriodClose) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var id: UUID
    var year: Int
    var month: Int
    var isClosed: Bool
    var closedAt: Date?
    var closedBy: String
    var companyID: UUID?

    init(year: Int, month: Int, closedBy: String = "") {
        self.id = UUID()
        self.year = year
        self.month = month
        self.isClosed = false
        self.closedBy = closedBy
    }
}

// MARK: - 审计日志
struct AuditLog: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let action: String      // create / update / delete / post / unpost / closePeriod
    let detail: String
    let user: String
    let entityID: String?
    let entityType: String? // Company / JournalEntry / Account / PeriodClose

    init(action: String, detail: String, user: String, entityID: String? = nil, entityType: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.action = action
        self.detail = detail
        self.user = user
        self.entityID = entityID
        self.entityType = entityType
    }
}

// MARK: - 数据持久化 (MainActor)
@MainActor
final class DataStore: ObservableObject {
    static let shared = DataStore()

    @Published var companies: [Company] = []
    @Published var accounts: [Account] = []
    @Published var journalEntries: [JournalEntry] = []
    @Published var periodCloses: [PeriodClose] = []
    @Published var auditLogs: [AuditLog] = []

    /// 数据版本号，用于检测 JSON schema 变更
    static let dataVersion = 1
    private let versionKey = "com.finbooks.dataVersion"

    private let fileManager = FileManager.default
    private var dataURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.finbooks.app")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        migrateIfNeeded()
        loadAll()
        if companies.isEmpty {
            createDemoData()
        }
    }

    /// 数据迁移：检测 schema 版本变更
    private func migrateIfNeeded() {
        let storedVersion = UserDefaults.standard.integer(forKey: versionKey)
        if storedVersion < Self.dataVersion {
            print("[DataStore] 执行数据迁移: \(storedVersion) → \(Self.dataVersion)")
            // 迁移逻辑：目前版本1无需执行
            UserDefaults.standard.set(Self.dataVersion, forKey: versionKey)
        }
    }

    /// 备份所有 JSON 文件
    func backupAll() {
        let backupDir = dataURL.appendingPathComponent("backups")
        try? fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let ts = DateFormatter()
        ts.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = ts.string(from: Date())
        for file in ["companies.json", "accounts.json", "entries.json", "periodCloses.json"] {
            let src = dataURL.appendingPathComponent(file)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            let dst = backupDir.appendingPathComponent("\(stamp)_\(file)")
            try? fileManager.copyItem(at: src, to: dst)
        }
        // 清理超过30天的备份
        cleanupOldBackups(backupDir: backupDir)
    }

    private func cleanupOldBackups(backupDir: URL) {
        guard let files = try? fileManager.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let deadline = Date().addingTimeInterval(-30 * 86400)
        for file in files {
            if let attrs = try? fileManager.attributesOfItem(atPath: file.path),
               let cdate = attrs[.creationDate] as? Date,
               cdate < deadline {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    // MARK: - Persistence
    func saveAll() {
        backupAll()
        saveJSON("companies.json", data: companies)
        saveJSON("accounts.json", data: accounts)
        saveJSON("entries.json", data: journalEntries)
        saveJSON("periodCloses.json", data: periodCloses)
    }

    func loadAll() {
        companies = loadJSON("companies.json") ?? []
        accounts = loadJSON("accounts.json") ?? []
        journalEntries = loadJSON("entries.json") ?? []
        periodCloses = loadJSON("periodCloses.json") ?? []
        auditLogs = loadJSON("auditLogs.json") ?? []
    }

    /// 从磁盘重新加载数据（供 AI Agent 写入后被 App 调用）
    func refreshFromDisk() {
        loadAll()
        // 手动触发 SwiftUI 更新
        objectWillChange.send()
        print("[DataStore] 已从磁盘刷新数据: \(companies.count) 公司, \(accounts.count) 科目, \(journalEntries.count) 凭证")
    }

    // MARK: - 审计日志
    func addAuditLog(action: String, detail: String, user: String = "system",
                     entityID: String? = nil, entityType: String? = nil) {
        let log = AuditLog(action: action, detail: detail, user: user,
                           entityID: entityID, entityType: entityType)
        auditLogs.append(log)
        saveJSON("auditLogs.json", data: auditLogs)
        // 保留最近1000条
        if auditLogs.count > 1000 {
            auditLogs = Array(auditLogs.suffix(1000))
        }
    }

    func loadAuditLogs() {
        auditLogs = loadJSON("auditLogs.json") ?? []
    }

    private func saveJSON<T: Codable>(_ filename: String, data: T) {
        let url = dataURL.appendingPathComponent(filename)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(data).write(to: url, options: .atomic)
        } catch { print("Save \(filename) failed: \(error)") }
    }

    private func loadJSON<T: Codable>(_ filename: String) -> T? {
        let url = dataURL.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
        catch { print("Load \(filename) failed: \(error)"); return nil }
    }

    // MARK: - Company CRUD
    func addCompany(_ company: Company) {
        companies.append(company)
        saveAll()
        objectWillChange.send()
    }
    func updateCompany(_ company: Company) {
        company.updatedAt = Date()
        saveAll()
        objectWillChange.send()
    }
    func deleteCompany(_ company: Company) {
        companies.removeAll { $0.id == company.id }
        accounts.removeAll { $0.companyID == company.id }
        journalEntries.removeAll { $0.companyID == company.id }
        periodCloses.removeAll { $0.companyID == company.id }
        saveAll()
        objectWillChange.send()
    }

    // MARK: - Account CRUD
    func addAccount(_ account: Account) {
        accounts.append(account)
        saveAll()
        objectWillChange.send()
    }
    func updateAccount(_ account: Account) {
        account.updatedAt = Date()
        saveAll()
        objectWillChange.send()
    }
    @discardableResult
    func deleteAccount(_ account: Account) -> Bool {
        // BUG-2: 检查是否有凭证引用此科目
        let refs = journalEntries.filter { entry in
            entry.lines.contains { $0.accountID == account.id }
        }
        if !refs.isEmpty {
            let refNumbers = refs.prefix(5).map(\.number).joined(separator: "、")
            let suffix = refs.count > 5 ? "等\(refs.count)张凭证" : ""
            print("科目 \"\(account.code) \(account.name)\" 被 \(refNumbers)\(suffix) 引用，无法删除")
            return false
        }
        accounts.removeAll { $0.id == account.id }
        saveAll()
        objectWillChange.send()
        return true
    }

    // MARK: - JournalEntry CRUD (返回 Bool 表示是否成功)
    @discardableResult
    func addEntry(_ entry: JournalEntry) -> Bool {
        // 结账锁定期间不可新增
        if let cid = entry.companyID {
            let ey = Calendar.current.component(.year, from: entry.date)
            let em = Calendar.current.component(.month, from: entry.date)
            guard !isPeriodClosed(companyID: cid, year: ey, month: em) else {
                print("⚠️ 该期间已结账，无法新增凭证")
                return false
            }
        }
        journalEntries.append(entry)
        saveAll()
        objectWillChange.send()
        return true
    }
    @discardableResult
    func updateEntry(_ entry: JournalEntry) -> Bool {
        // 已过账凭证禁止修改
        guard !entry.isPosted else {
            print("凭证 \(entry.number) 已过账，不可修改")
            return false
        }
        // 结账锁定期间不可修改
        if let cid = entry.companyID {
            let ey = Calendar.current.component(.year, from: entry.date)
            let em = Calendar.current.component(.month, from: entry.date)
            guard !isPeriodClosed(companyID: cid, year: ey, month: em) else {
                print("⚠️ 该期间已结账，无法修改凭证")
                return false
            }
        }
        entry.updatedAt = Date()
        saveAll()
        journalEntries = journalEntries
        objectWillChange.send()
        return true
    }
    @discardableResult
    func deleteEntry(_ entry: JournalEntry) -> Bool {
        // 已过账凭证禁止删除
        guard !entry.isPosted else {
            print("凭证 \(entry.number) 已过账，不可删除")
            return false
        }
        // 结账锁定期间不可删除
        if let cid = entry.companyID {
            let ey = Calendar.current.component(.year, from: entry.date)
            let em = Calendar.current.component(.month, from: entry.date)
            guard !isPeriodClosed(companyID: cid, year: ey, month: em) else {
                print("⚠️ 该期间已结账，无法删除凭证")
                return false
            }
        }
        journalEntries.removeAll { $0.id == entry.id }
        saveAll()
        journalEntries = journalEntries
        objectWillChange.send()
        return true
    }
    func togglePosted(_ entry: JournalEntry) -> Bool {
        // 结账锁定期间不可变更状态
        if let cid = entry.companyID {
            let ey = Calendar.current.component(.year, from: entry.date)
            let em = Calendar.current.component(.month, from: entry.date)
            guard !isPeriodClosed(companyID: cid, year: ey, month: em) else {
                print("⚠️ 该期间已结账，无法变更凭证状态")
                return false
            }
        }
        // BUG-3: 过账时校验借贷平衡
        if !entry.isPosted {
            guard entry.isBalanced && entry.debitTotal > 0 else {
                print("凭证 \(entry.number) 借贷不平，无法过账")
                return false
            }
        }
        entry.isPosted.toggle()
        entry.updatedAt = Date()
        // BUG-4: 过账/反过账时同步更新被引用科目的余额缓存
        AccountingEngine.syncBalances(for: entry)
        saveAll()
        journalEntries = journalEntries
        objectWillChange.send()
        return true
    }

    // MARK: - PeriodClose CRUD
    func addPeriodClose(_ pc: PeriodClose) {
        // 防止重复添加同一期间
        if let existing = periodCloses.first(where: { $0.companyID == pc.companyID && $0.year == pc.year && $0.month == pc.month }) {
            existing.isClosed = pc.isClosed
            existing.closedAt = pc.closedAt
            existing.closedBy = pc.closedBy
        } else {
            periodCloses.append(pc)
        }
        saveAll()
        objectWillChange.send()
    }

    func isPeriodClosed(companyID: UUID, year: Int, month: Int) -> Bool {
        periodCloses.contains { $0.companyID == companyID && $0.year == year && $0.month == month && $0.isClosed }
    }

    // MARK: - Query
    func accounts(for companyID: UUID) -> [Account] {
        accounts.filter { $0.companyID == companyID }
    }
    func entries(for companyID: UUID) -> [JournalEntry] {
        journalEntries.filter { $0.companyID == companyID }
    }

    // MARK: - Demo Data
    private func date(year: Int, month: Int, day: Int) -> Date? {
        var c = DateComponents(); c.year = year; c.month = month; c.day = day
        return Calendar.current.date(from: c)
    }

    private func createDemoData() {
        let company = Company(name: "示例科技有限公司", legalName: "示例科技有限公司",
                              taxId: "91440101MA5XXXXXXX", address: "北京市朝阳区建国路88号",
                              phone: "010-88886666")
        companies.append(company)

        let defaultAccounts: [(String, String, AccountCategory)] = [
            ("1001", "库存现金", .asset), ("1002", "银行存款", .asset),
            ("1122", "应收账款", .asset), ("1123", "预付账款", .asset),
            ("1221", "其他应收款", .asset), ("1403", "原材料", .asset),
            ("1405", "库存商品", .asset), ("1601", "固定资产", .asset),
            ("1602", "累计折旧", .asset),
            ("2001", "短期借款", .liability), ("2202", "应付账款", .liability),
            ("2203", "预收账款", .liability), ("2211", "应付职工薪酬", .liability),
            ("2221", "应交税费", .liability), ("2241", "其他应付款", .liability),
            ("2501", "长期借款", .liability),
            ("4001", "实收资本", .equity), ("4103", "本年利润", .equity),
            ("4104", "利润分配", .equity),
            ("5001", "主营业务收入", .revenue), ("5051", "其他业务收入", .revenue),
            ("5111", "投资收益", .revenue),
            ("6001", "主营业务成本", .expense), ("6401", "税金及附加", .expense),
            ("6601", "销售费用", .expense), ("6602", "管理费用", .expense),
            ("6603", "财务费用", .expense), ("6801", "所得税费用", .expense),
        ]
        for (idx, (code, name, cat)) in defaultAccounts.enumerated() {
            let a = Account(code: code, name: name, category: cat, sortOrder: idx)
            a.companyID = company.id
            accounts.append(a)
        }

        // 创建几条示例凭证（设置 entryID 确保总账查询正常）
        let bank = accounts.first { $0.code == "1002" }!
        let revenue = accounts.first { $0.code == "5001" }!
        let cost = accounts.first { $0.code == "6001" }!
        let inventory = accounts.first { $0.code == "1405" }!
        let salary = accounts.first { $0.code == "2211" }!
        let management = accounts.first { $0.code == "6602" }!

        let e1 = JournalEntry(number: "记-2026-0001", date: date(year: 2026, month: 5, day: 31)!, summary: "销售收入入账", isPosted: true)
        e1.companyID = company.id
        let l1a = JournalLine(summary: "银行存款", debit: 100000, credit: 0)
        l1a.accountID = bank.id; l1a.entryID = e1.id
        let l1b = JournalLine(summary: "主营业务收入", debit: 0, credit: 100000)
        l1b.accountID = revenue.id; l1b.entryID = e1.id
        e1.lines = [l1a, l1b]

        let e2 = JournalEntry(number: "记-2026-0002", date: date(year: 2026, month: 5, day: 31)!, summary: "结转销售成本", isPosted: true)
        e2.companyID = company.id
        let l2a = JournalLine(summary: "主营业务成本", debit: 60000, credit: 0)
        l2a.accountID = cost.id; l2a.entryID = e2.id
        let l2b = JournalLine(summary: "库存商品", debit: 0, credit: 60000)
        l2b.accountID = inventory.id; l2b.entryID = e2.id
        e2.lines = [l2a, l2b]

        let e3 = JournalEntry(number: "记-2026-0003", date: date(year: 2026, month: 6, day: 1)!, summary: "支付管理人员工资", isPosted: true)
        e3.companyID = company.id
        let l3a = JournalLine(summary: "管理费用", debit: 15000, credit: 0)
        l3a.accountID = management.id; l3a.entryID = e3.id
        let l3b = JournalLine(summary: "应付职工薪酬", debit: 0, credit: 15000)
        l3b.accountID = salary.id; l3b.entryID = e3.id
        e3.lines = [l3a, l3b]

        journalEntries = [e1, e2, e3]
        saveAll()
    }
}

// MARK: - AccountCategory 颜色
extension AccountCategory {
    var categoryColor: Color {
        switch self {
        case .asset: return .blue
        case .liability: return .orange
        case .equity: return .green
        case .revenue: return .purple
        case .expense: return .red
        }
    }
}
