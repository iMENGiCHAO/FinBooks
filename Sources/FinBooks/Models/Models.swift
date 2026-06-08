import SwiftUI
import Foundation
#if canImport(Darwin)
import Darwin
#endif
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
    /// 余额方向覆盖（如 1602 累计折旧：资产类但余额在贷方）
    var balanceDirection: AccountCategory.Nature?

    init(code: String, name: String, category: AccountCategory, parentCode: String? = nil,
         isActive: Bool = true, sortOrder: Int = 0, balanceDirection: AccountCategory.Nature? = nil) {
        self.id = UUID()
        self.code = code
        self.name = name
        self.category = category
        self.parentCode = parentCode
        self.isActive = isActive
        self.sortOrder = sortOrder
        self.createdAt = Date()
        self.updatedAt = Date()
        self.balanceDirection = balanceDirection
    }

    /// 实际余额方向：优先取 balanceDirection，否则用 category.nature
    var effectiveBalanceDirection: AccountCategory.Nature {
        balanceDirection ?? category.nature
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
    var reverseOfID: UUID?
    /// 数据完整性校验：过账时生成的 SHA-256 哈希
    var hash: String?
    /// 前一张凭证的哈希（区块链式链指针）
    var previousHash: String?
    var createdAt: Date
    var updatedAt: Date
    var companyID: UUID?
    var lines: [JournalLine] = []

    var debitTotal: Decimal { lines.reduce(Decimal.zero) { $0 + $1.debit } }
    var creditTotal: Decimal { lines.reduce(Decimal.zero) { $0 + $1.credit } }
    var isBalanced: Bool { debitTotal == creditTotal }

    /// 验证本凭证的哈希完整性
    var isHashValid: Bool {
        guard let h = hash else { return false }
        return h == Self.computeHash(for: self)
    }
    
    /// 生成用于哈希校验的规范字符串
    static func canonicalString(for entry: JournalEntry) -> String {
        let lineData = entry.lines.sorted(by: { $0.id.uuidString < $1.id.uuidString }).map {
            "\($0.accountID?.uuidString ?? ""):\($0.debit):\($0.credit):\($0.vatRate):\($0.vatAmount)"
        }.joined(separator: "|")
        return "\(entry.number)|\(entry.date.timeIntervalSince1970)|\(entry.summary)|\(entry.reverseOfID?.uuidString ?? "")|\(lineData)"
    }
    
    /// 计算凭证的 SHA-256 哈希
    static func computeHash(for entry: JournalEntry) -> String {
        canonicalString(for: entry).sha256
    }

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

// MARK: - SHA-256 工具
import CommonCrypto
extension String {
    var sha256: String {
        let data = Data(self.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
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
    var accountCode: String = ""
    var accountName: String = ""
    /// 增值税率（如 0.13, 0.09, 0.06）
    var vatRate: Double
    /// 增值税额
    var vatAmount: Decimal
    /// 关联发票ID
    var invoiceID: UUID?

    /// 从科目表反查科目编码（线程安全：优先使用缓存的 accountCode，必要时从 DataStore 读取）
    var resolvedAccountCode: String {
        guard accountID != nil else { return self.accountCode }
        if !self.accountCode.isEmpty { return self.accountCode }
        return self.accountCode
    }
    /// 从科目表反查科目名称（线程安全：优先使用缓存的 accountName，必要时从 DataStore 读取）
    var resolvedAccountName: String {
        guard accountID != nil else { return self.accountName }
        if !self.accountName.isEmpty { return self.accountName }
        return self.accountName
    }

    init(summary: String = "", debit: Decimal = .zero, credit: Decimal = .zero,
         vatRate: Double = 0, vatAmount: Decimal = .zero) {
        self.id = UUID()
        self.summary = summary
        self.debit = debit
        self.credit = credit
        self.vatRate = vatRate
        self.vatAmount = vatAmount
        // accountCode 和 accountName 保留默认空值
    }
}

// MARK: - 银行账户
final class BankAccount: Codable, Identifiable, ObservableObject, Hashable {
    static func == (lhs: BankAccount, rhs: BankAccount) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var id: UUID
    var name: String              // 账户别名，如"基本户-工行"
    var bankName: String          // 银行名称
    var accountNumber: String     // 账号
    var openingBalance: Decimal   // 期初余额
    var currency: String          // 币种，默认 CNY
    var accountID: UUID?          // 关联的会计科目（银行存款）
    var companyID: UUID?
    var createdAt: Date
    
    init(name: String, bankName: String, accountNumber: String, openingBalance: Decimal = 0,
         currency: String = "CNY", accountID: UUID? = nil) {
        self.id = UUID()
        self.name = name
        self.bankName = bankName
        self.accountNumber = accountNumber
        self.openingBalance = openingBalance
        self.currency = currency
        self.accountID = accountID
        self.createdAt = Date()
    }
}

// MARK: - 银行流水
struct BankTransaction: Codable, Identifiable, Hashable {
    var id: UUID
    var date: Date
    var description: String       // 摘要/交易说明
    var amount: Decimal           // 正数=收入，负数=支出
    var balance: Decimal          // 交易后余额
    var reference: String         // 对方账号/参考号
    var isMatched: Bool           // 是否已对账匹配
    var entryID: UUID?            // 匹配的凭证ID
    var bankAccountID: UUID
    var companyID: UUID?
    var importBatch: String       // 导入批次号
    
    init(date: Date, description: String, amount: Decimal, balance: Decimal = 0,
         reference: String = "", bankAccountID: UUID, importBatch: String = "",
         entryID: UUID? = nil) {
        self.id = UUID()
        self.date = date
        self.description = description
        self.amount = amount
        self.balance = balance
        self.reference = reference
        self.isMatched = false
        self.bankAccountID = bankAccountID
        self.importBatch = importBatch
        self.entryID = entryID
    }
}

// MARK: - 对账记录
final class Reconciliation: Codable, Identifiable, ObservableObject, Hashable {
    static func == (lhs: Reconciliation, rhs: Reconciliation) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var id: UUID
    var bankAccountID: UUID
    var reconciliationDate: Date
    var bookBalance: Decimal      // 账面余额
    var statementBalance: Decimal // 银行对账单余额
    var difference: Decimal       // 差额
    var isComplete: Bool
    var matchedCount: Int
    var unmatchedCount: Int
    var companyID: UUID?
    var createdAt: Date
    var notes: String
    
    init(bankAccountID: UUID, reconciliationDate: Date, bookBalance: Decimal = 0,
         statementBalance: Decimal = 0) {
        self.id = UUID()
        self.bankAccountID = bankAccountID
        self.reconciliationDate = reconciliationDate
        self.bookBalance = bookBalance
        self.statementBalance = statementBalance
        self.difference = bookBalance - statementBalance
        self.isComplete = false
        self.matchedCount = 0
        self.unmatchedCount = 0
        self.createdAt = Date()
        self.notes = ""
    }
}

// MARK: - 固定资产
final class FixedAsset: Codable, Identifiable, ObservableObject, Hashable {
    static func == (lhs: FixedAsset, rhs: FixedAsset) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var id: UUID
    var name: String              // 资产名称
    var assetCode: String         // 资产编号
    var category: String          // 类别（如"电子设备"、"房屋建筑"）
    var originalValue: Decimal    // 原值
    var residualValue: Decimal    // 残值
    var usefulLife: Int           // 使用年限（月）
    var depreciationMethod: DepreciationMethod
    var acquiredDate: Date        // 购置日期
    var startDepreciationDate: Date // 开始折旧日期
    var accumulatedDepreciation: Decimal // 累计折旧
    var netBookValue: Decimal { originalValue - residualValue - accumulatedDepreciation }
    var status: AssetStatus
    var accountID: UUID?          // 关联的固定资产科目
    var depreciationAccountID: UUID? // 关联的累计折旧科目
    var expenseAccountID: UUID?   // 关联的折旧费用科目
    var companyID: UUID?
    var createdAt: Date
    
    init(name: String, assetCode: String, category: String, originalValue: Decimal,
         residualValue: Decimal = 0, usefulLife: Int = 60,
         depreciationMethod: DepreciationMethod = .straightLine,
         acquiredDate: Date, startDepreciationDate: Date? = nil,
         status: AssetStatus = .active) {
        self.id = UUID()
        self.name = name
        self.assetCode = assetCode
        self.category = category
        self.originalValue = originalValue
        self.residualValue = residualValue
        self.usefulLife = usefulLife
        self.depreciationMethod = depreciationMethod
        self.acquiredDate = acquiredDate
        self.startDepreciationDate = startDepreciationDate ?? acquiredDate
        self.accumulatedDepreciation = 0
        self.status = status
        self.createdAt = Date()
    }
}

enum DepreciationMethod: String, Codable, CaseIterable, Identifiable {
    case straightLine = "直线法"
    case doubleDeclining = "双倍余额递减法"
    var id: String { rawValue }
}

enum AssetStatus: String, Codable, CaseIterable {
    case active = "使用中"
    case disposed = "已处置"
    case fullyDepreciated = "已提足"
}

// MARK: - 发票类型
final class Invoice: Codable, Identifiable, ObservableObject, Hashable {
    static func == (lhs: Invoice, rhs: Invoice) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    
    var id: UUID
    var invoiceNo: String           // 发票号码
    var invoiceCode: String         // 发票代码
    var invoiceDate: Date
    var sellerName: String          // 销售方
    var buyerName: String           // 购买方
    var amount: Decimal             // 不含税金额
    var taxAmount: Decimal          // 税额
    var totalAmount: Decimal        // 价税合计
    var taxRate: Double             // 税率
    var type: InvoiceType           // 进项/销项
    var status: InvoiceStatus       // 匹配状态
    var entryID: UUID?              // 关联凭证ID
    var imagePath: String?          // 扫描件路径
    var companyID: UUID?
    var createdAt: Date
    
    init(invoiceNo: String, invoiceCode: String = "", invoiceDate: Date, sellerName: String,
         buyerName: String, amount: Decimal, taxAmount: Decimal, totalAmount: Decimal,
         taxRate: Double, type: InvoiceType) {
        self.id = UUID()
        self.invoiceNo = invoiceNo
        self.invoiceCode = invoiceCode
        self.invoiceDate = invoiceDate
        self.sellerName = sellerName
        self.buyerName = buyerName
        self.amount = amount
        self.taxAmount = taxAmount
        self.totalAmount = totalAmount
        self.taxRate = taxRate
        self.type = type
        self.status = .unmatched
        self.createdAt = Date()
    }
}

// MARK: - 科目余额快照（余额缓存）
struct AccountBalance: Codable, Identifiable, Hashable {
    var id: String { "\(accountID.uuidString)_\(year)_\(month)" }
    let accountID: UUID
    let year: Int
    let month: Int
    var openingBalance: Decimal
    var debitTotal: Decimal
    var creditTotal: Decimal
    var closingBalance: Decimal
    /// 余额方向：debit = 借方余额, credit = 贷方余额
    var balanceDirection: AccountCategory.Nature = .debit
    
    static func cacheKey(accountID: UUID, year: Int, month: Int) -> String {
        "\(accountID.uuidString)_\(year)_\(month)"
    }
}

enum InvoiceType: String, Codable, CaseIterable, Identifiable {
    case input = "进项"
    case output = "销项"
    var id: String { rawValue }
}

enum InvoiceStatus: String, Codable, CaseIterable {
    case unmatched = "未匹配"
    case matched = "已匹配"
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

    init(year: Int, month: Int, closedBy: String = ProcessInfo.processInfo.fullUserName, companyID: UUID? = nil) {
        self.id = UUID()
        self.year = year
        self.month = month
        self.isClosed = false
        self.closedBy = closedBy
        self.companyID = companyID
    }
}

// MARK: - 审计日志
struct AuditLog: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let action: String      // create / update / delete / post / unpost / closePeriod / reverse
    let detail: String
    let user: String
    let entityID: String?
    let entityType: String? // Company / JournalEntry / Account / PeriodClose
    let hostname: String    // 操作机器名（审计追踪）
    let companyID: UUID?    // 关联公司（审计过滤）
    let ipAddress: String   // 本机 IP（审计追踪）

    init(action: String, detail: String, user: String, entityID: String? = nil, entityType: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.action = action
        self.detail = detail
        self.user = user
        self.entityID = entityID
        self.entityType = entityType
        self.hostname = ProcessInfo.processInfo.hostName
        self.companyID = nil
        self.ipAddress = AuditLog.localIPAddress() ?? "127.0.0.1"
    }
    
    /// 获取本机局域网 IP
    static func localIPAddress() -> String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            let interface = ptr?.pointee
            let family = interface?.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: (interface?.ifa_name)!)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface?.ifa_addr, socklen_t((interface?.ifa_addr.pointee.sa_len)!),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    addr = String(cString: hostname)
                    break
                }
            }
        }
        freeifaddrs(ifaddr)
        return addr
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
    @Published var invoices: [Invoice] = []
    @Published var balanceCache: [AccountBalance] = []
    @Published var bankAccounts: [BankAccount] = []
    @Published var bankTransactions: [BankTransaction] = []
    @Published var reconciliations: [Reconciliation] = []
    @Published var fixedAssets: [FixedAsset] = []

    /// 数据版本号，用于检测 JSON schema 变更
    static let dataVersion = 4
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
        for file in ["companies.json", "accounts.json", "entries.json", "periodCloses.json",
                "invoices.json", "balanceCache.json", "bankAccounts.json",
                "bankTransactions.json", "reconciliations.json", "fixedAssets.json", "auditLogs.json"] {
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
        saveJSON("invoices.json", data: invoices)
        saveJSON("balanceCache.json", data: Array(balanceCache))
        saveJSON("bankAccounts.json", data: bankAccounts)
        saveJSON("bankTransactions.json", data: bankTransactions)
        saveJSON("reconciliations.json", data: reconciliations)
        saveJSON("fixedAssets.json", data: fixedAssets)
        saveJSON("auditLogs.json", data: auditLogs)
    }

    func loadAll() {
        companies = loadJSON("companies.json") ?? []
        accounts = loadJSON("accounts.json") ?? []
        journalEntries = loadJSON("entries.json") ?? []
        periodCloses = loadJSON("periodCloses.json") ?? []
        auditLogs = loadJSON("auditLogs.json") ?? []
        invoices = loadJSON("invoices.json") ?? []
        balanceCache = loadJSON("balanceCache.json") ?? []
        bankAccounts = loadJSON("bankAccounts.json") ?? []
        bankTransactions = loadJSON("bankTransactions.json") ?? []
        reconciliations = loadJSON("reconciliations.json") ?? []
        fixedAssets = loadJSON("fixedAssets.json") ?? []
    }

    /// 从磁盘重新加载数据（供 AI Agent 写入后被 App 调用）
    func refreshFromDisk() {
        loadAll()
        // 手动触发 SwiftUI 更新
        objectWillChange.send()
        print("[DataStore] 已从磁盘刷新数据: \(companies.count) 公司, \(accounts.count) 科目, \(journalEntries.count) 凭证")
    }

    // MARK: - 余额缓存

    /// 为指定期间构建余额缓存（全量重建）
    func rebuildBalanceCache(for companyID: UUID, year: Int, month: Int) {
        let posted = journalEntries.filter { $0.isPosted && $0.companyID == companyID }
        let cal = Calendar.current
        // 筛选累计到当前期间的所有已过账凭证（包含当前月）
        let periodEntries = posted.filter { entry in
            let ey = cal.component(.year, from: entry.date)
            let em = cal.component(.month, from: entry.date)
            return (ey < year) || (ey == year && em <= month)
        }
        let periodAccounts = accounts.filter { $0.companyID == companyID }

        var newCache: [AccountBalance] = []
        for acct in periodAccounts {
            var opening: Decimal = 0
            var debitTotal: Decimal = 0
            var creditTotal: Decimal = 0
            for entry in periodEntries {
                for line in entry.lines where line.accountID == acct.id {
                    let ey = cal.component(.year, from: entry.date)
                    let em = cal.component(.month, from: entry.date)
                    if ey < year || (ey == year && em < month) {
                        // 期初余额 = 前期累计发生额（自然方向）
                        if acct.effectiveBalanceDirection == .debit {
                            opening += line.debit - line.credit
                        } else {
                            opening += line.credit - line.debit
                        }
                    } else if ey == year && em == month {
                        debitTotal += line.debit
                        creditTotal += line.credit
                    }
                }
            }
            let closing = opening + (acct.effectiveBalanceDirection == .debit ? debitTotal - creditTotal : creditTotal - debitTotal)
            let balance = AccountBalance(
                accountID: acct.id,
                year: year, month: month,
                openingBalance: opening,
                debitTotal: debitTotal,
                creditTotal: creditTotal,
                closingBalance: closing,
                balanceDirection: acct.effectiveBalanceDirection
            )
            newCache.append(balance)
        }
        // 移除该公司该期间的旧缓存
        balanceCache.removeAll { cached in
            periodAccounts.contains(where: { $0.id == cached.accountID })
                && cached.year == year && cached.month == month
        }
        balanceCache.append(contentsOf: newCache)
        saveJSON("balanceCache.json", data: Array(balanceCache))
    }
    
    /// 在过账/反过账后增量更新余额缓存
    func updateBalanceCache(for entry: JournalEntry) {
        guard entry.companyID != nil else { return }
        let cal = Calendar.current
        let ey = cal.component(.year, from: entry.date)
        let em = cal.component(.month, from: entry.date)
        let sign: Decimal = entry.isPosted ? 1 : -1
        
        for line in entry.lines {
            guard let aid = line.accountID else { continue }
            // 多公司隔离：确保账户属于该公司
            guard accounts.contains(where: { $0.id == aid && $0.companyID == entry.companyID }) else { continue }
            let deltaDebit = line.debit * sign
            let deltaCredit = line.credit * sign
            if let idx = balanceCache.firstIndex(where: { $0.accountID == aid && $0.year == ey && $0.month == em }) {
                var cached = balanceCache[idx]
                cached.debitTotal += deltaDebit
                cached.creditTotal += deltaCredit
                if let acct = accounts.first(where: { $0.id == aid }) {
                    let dir = acct.effectiveBalanceDirection
                    if dir == .debit {
                        cached.closingBalance = cached.openingBalance + cached.debitTotal - cached.creditTotal
                    } else {
                        cached.closingBalance = cached.openingBalance + cached.creditTotal - cached.debitTotal
                    }
                }
                balanceCache[idx] = cached
            } else {
                // 缓存不存在时创建新的缓存条目
                // 取上期期末余额作为本期期初
                let prevMonth = em > 1 ? em - 1 : 12
                let prevYear = em > 1 ? ey : ey - 1
                let prevClosing = balanceCache.first(where: { $0.accountID == aid && $0.year == prevYear && $0.month == prevMonth })?.closingBalance ?? 0
                let opening = prevClosing
                let dir = accounts.first(where: { $0.id == aid })?.effectiveBalanceDirection ?? .debit
                let debitTotal = deltaDebit > 0 ? deltaDebit : -deltaDebit
                let creditTotal = deltaCredit > 0 ? deltaCredit : -deltaCredit
                let closing = dir == .debit ? opening + debitTotal - creditTotal : opening + creditTotal - debitTotal
                let bal = AccountBalance(
                    accountID: aid, year: ey, month: em,
                    openingBalance: opening,
                    debitTotal: debitTotal,
                    creditTotal: creditTotal,
                    closingBalance: closing,
                    balanceDirection: dir
                )
                balanceCache.append(bal)
            }
        }
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
        addAuditLog(action: "create", detail: "新增公司: \(company.name)", entityID: company.id.uuidString, entityType: "Company")
        objectWillChange.send()
    }
    func updateCompany(_ company: Company) {
        company.updatedAt = Date()
        saveAll()
        addAuditLog(action: "update", detail: "更新公司: \(company.name)", entityID: company.id.uuidString, entityType: "Company")
        objectWillChange.send()
    }
    func deleteCompany(_ company: Company) {
        let name = company.name
        companies.removeAll { $0.id == company.id }
        accounts.removeAll { $0.companyID == company.id }
        journalEntries.removeAll { $0.companyID == company.id }
        periodCloses.removeAll { $0.companyID == company.id }
        saveAll()
        addAuditLog(action: "delete", detail: "删除公司: \(name)（含所有科目、凭证、结账记录）", entityID: company.id.uuidString, entityType: "Company")
        objectWillChange.send()
    }

    // MARK: - Account CRUD
    func addAccount(_ account: Account) {
        accounts.append(account)
        saveAll()
        addAuditLog(action: "create", detail: "新增科目: \(account.code) \(account.name)", entityID: account.id.uuidString, entityType: "Account")
        objectWillChange.send()
    }
    func updateAccount(_ account: Account) {
        account.updatedAt = Date()
        saveAll()
        addAuditLog(action: "update", detail: "更新科目: \(account.code) \(account.name)", entityID: account.id.uuidString, entityType: "Account")
        objectWillChange.send()
    }
    @discardableResult
    func deleteAccount(_ account: Account) -> Bool {
        // 检查是否有凭证引用此科目
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
        addAuditLog(action: "delete", detail: "删除科目: \(account.code) \(account.name)", entityID: account.id.uuidString, entityType: "Account")
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
        // 过账状态：校验借贷平衡 + 生成哈希链
        if entry.isPosted {
            guard entry.isBalanced && entry.debitTotal > 0 else {
                print("凭证 \(entry.number) 借贷不平，无法过账")
                return false
            }
            // 生成 SHA-256 哈希 + 区块链指针
            entry.hash = JournalEntry.computeHash(for: entry)
            let lastPostedHash = journalEntries
                .filter { $0.isPosted && $0.id != entry.id }
                .sorted { $0.date > $1.date || ($0.date == $1.date && $0.number > $1.number) }
                .first?.hash
            entry.previousHash = lastPostedHash
            AccountingEngine.syncBalances(for: entry)
            updateBalanceCache(for: entry)
        }
        journalEntries.append(entry)
        saveAll()
        addAuditLog(action: "create", detail: "新增凭证: \(entry.number), 金额 ¥\(entry.debitTotal)", entityID: entry.id.uuidString, entityType: "JournalEntry")
        if entry.isPosted {
            addAuditLog(action: "post", detail: "过账: \(entry.number)", entityID: entry.id.uuidString, entityType: "JournalEntry")
        }
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
        addAuditLog(action: "update", detail: "修改凭证: \(entry.number)", entityID: entry.id.uuidString, entityType: "JournalEntry")
        objectWillChange.send()
        return true
    }
    @discardableResult
    func deleteEntry(_ entry: JournalEntry) -> Bool {
        // 结账锁定期间禁止删除任意凭证
        if let cid = entry.companyID {
            let ey = Calendar.current.component(.year, from: entry.date)
            let em = Calendar.current.component(.month, from: entry.date)
            guard !isPeriodClosed(companyID: cid, year: ey, month: em) else {
                print("⚠️ 该期间已结账(\(ey)年\(em)月)，无法删除凭证")
                return false
            }
        }
        // 已过证凭证禁止删除
        guard !entry.isPosted else {
            print("凭证 \(entry.number) 已过账，不可删除")
            return false
        }
        let number = entry.number
        journalEntries.removeAll { $0.id == entry.id }
        saveAll()
        addAuditLog(action: "delete", detail: "删除凭证: \(number)", entityID: entry.id.uuidString, entityType: "JournalEntry")
        self.objectWillChange.send()
        return true
    }

    // MARK: - 银行账户 CRUD
    func addBankAccount(_ account: BankAccount) {
        bankAccounts.append(account)
        addAuditLog(action: "create", detail: "新增银行账户: \(account.name) (\(account.bankName))",
                    entityID: account.id.uuidString, entityType: "BankAccount")
        saveAll()
        objectWillChange.send()
    }
    
    func deleteBankAccount(_ account: BankAccount) {
        bankAccounts.removeAll { $0.id == account.id }
        bankTransactions.removeAll { $0.bankAccountID == account.id }
        addAuditLog(action: "delete", detail: "删除银行账户: \(account.name)",
                    entityID: account.id.uuidString, entityType: "BankAccount")
        saveAll()
        objectWillChange.send()
    }

    // MARK: - 银行流水 CRUD
    func importBankTransactions(_ transactions: [BankTransaction]) {
        bankTransactions.append(contentsOf: transactions)
        addAuditLog(action: "import", detail: "导入银行流水: \(transactions.count) 条",
                    entityType: "BankTransaction")
        saveAll()
        objectWillChange.send()
    }
    
    func matchTransaction(_ tx: BankTransaction, to entry: JournalEntry) {
        guard let idx = bankTransactions.firstIndex(where: { $0.id == tx.id }) else { return }
        bankTransactions[idx].isMatched = true
        bankTransactions[idx].entryID = entry.id
        addAuditLog(action: "match", detail: "银行流水匹配凭证: \(entry.number)",
                    entityID: tx.id.uuidString, entityType: "BankTransaction")
        saveAll()
        objectWillChange.send()
    }
    
    func unmatchTransaction(_ tx: BankTransaction) {
        guard let idx = bankTransactions.firstIndex(where: { $0.id == tx.id }) else { return }
        bankTransactions[idx].isMatched = false
        bankTransactions[idx].entryID = nil
        addAuditLog(action: "unmatch", detail: "取消银行流水匹配",
                    entityID: tx.id.uuidString, entityType: "BankTransaction")
        saveAll()
        objectWillChange.send()
    }

    // MARK: - 对账记录 CRUD
    func addReconciliation(_ rec: Reconciliation) {
        reconciliations.append(rec)
        addAuditLog(action: "create", detail: "新建对账记录",
                    entityID: rec.id.uuidString, entityType: "Reconciliation")
        saveAll()
        objectWillChange.send()
    }
    
    func completeReconciliation(_ rec: Reconciliation) {
        guard let idx = reconciliations.firstIndex(where: { $0.id == rec.id }) else { return }
        reconciliations[idx].isComplete = true
        addAuditLog(action: "complete", detail: "对账完成: 匹配\(rec.matchedCount)条, 未匹配\(rec.unmatchedCount)条",
                    entityID: rec.id.uuidString, entityType: "Reconciliation")
        saveAll()
        objectWillChange.send()
    }

    // MARK: - 固定资产 CRUD
    func addFixedAsset(_ asset: FixedAsset) {
        fixedAssets.append(asset)
        addAuditLog(action: "create", detail: "新增固定资产: \(asset.name) (\(asset.assetCode))",
                    entityID: asset.id.uuidString, entityType: "FixedAsset")
        saveAll()
        objectWillChange.send()
    }
    
    func updateFixedAsset(_ asset: FixedAsset) {
        guard let idx = fixedAssets.firstIndex(where: { $0.id == asset.id }) else { return }
        fixedAssets[idx] = asset
        addAuditLog(action: "update", detail: "更新固定资产: \(asset.name)",
                    entityID: asset.id.uuidString, entityType: "FixedAsset")
        saveAll()
        objectWillChange.send()
    }
    
    func disposeAsset(_ asset: FixedAsset) {
        guard let idx = fixedAssets.firstIndex(where: { $0.id == asset.id }) else { return }
        fixedAssets[idx].status = .disposed
        addAuditLog(action: "dispose", detail: "处置固定资产: \(asset.name)",
                    entityID: asset.id.uuidString, entityType: "FixedAsset")
        saveAll()
        objectWillChange.send()
    }
    
    func deleteFixedAsset(_ asset: FixedAsset) {
        fixedAssets.removeAll { $0.id == asset.id }
        addAuditLog(action: "delete", detail: "删除固定资产: \(asset.name)",
                    entityID: asset.id.uuidString, entityType: "FixedAsset")
        saveAll()
        objectWillChange.send()
    }

    // MARK: - 银行对账引擎
    /// 自动匹配：按金额 + 时间窗口匹配银行流水和凭证
    func autoMatchTransactions(for bankAccount: BankAccount, daysWindow: Int = 3) -> Int {
        let txs = bankTransactions.filter { !$0.isMatched && $0.bankAccountID == bankAccount.id }
        let entries = journalEntries.filter { $0.isPosted && $0.companyID == bankAccount.companyID }
        var matchCount = 0
        
        for tx in txs {
            // 查找金额匹配且日期在窗口内的已过账凭证
            let matching = entries.filter { entry in
                let absAmount = abs(tx.amount)
                _ = entry.debitTotal  // 借或贷应该匹配
                let amountMatch = entry.debitTotal == absAmount || entry.creditTotal == absAmount
                let dateDiff = abs(entry.date.timeIntervalSince(tx.date))
                return amountMatch && dateDiff <= Double(daysWindow * 86400)
            }
            if let best = matching.first {
                matchTransaction(tx, to: best)
                matchCount += 1
            }
        }
        return matchCount
    }
    @discardableResult
    func reverseEntry(_ entry: JournalEntry, reason: String) -> JournalEntry? {
        // 只能冲销已过账凭证
        guard entry.isPosted else {
            print("凭证 \(entry.number) 未过账，无需冲销")
            return nil
        }
        // 已被冲销的凭证不能再次冲销
        let alreadyReversed = journalEntries.contains { $0.reverseOfID == entry.id }
        guard !alreadyReversed else {
            print("凭证 \(entry.number) 已被冲销")
            return nil
        }
        // 结账后不可冲销
        if let cid = entry.companyID {
            let ey = Calendar.current.component(.year, from: entry.date)
            let em = Calendar.current.component(.month, from: entry.date)
            guard !isPeriodClosed(companyID: cid, year: ey, month: em) else {
                print("⚠️ 该期间已结账，无法冲销凭证")
                return nil
            }
        }
        // 生成红字冲销凭证（金额取反）
        let reversal = JournalEntry(number: nextReversalNumber(for: entry), date: Date(), summary: "冲销凭证: \(entry.number) — \(reason)")
        reversal.isPosted = false
        reversal.companyID = entry.companyID
        reversal.reverseOfID = entry.id
        var revLines: [JournalLine] = []
        for line in entry.lines {
            let rl = JournalLine(summary: "冲销: \(line.summary)", debit: line.credit, credit: line.debit)
            rl.accountID = line.accountID
            rl.entryID = reversal.id
            rl.accountCode = line.accountCode
            rl.accountName = line.accountName
            revLines.append(rl)
        }
        reversal.lines = revLines
        journalEntries.append(reversal)
        saveAll()
        addAuditLog(action: "reverse", detail: "冲销凭证: \(entry.number) → \(reversal.number), 原因: \(reason)", entityID: entry.id.uuidString, entityType: "JournalEntry")
        // 同时记录冲销凭证的审计日志
        addAuditLog(action: "create", detail: "冲销凭证已生成: \(reversal.number), 冲销源: \(entry.number)", entityID: reversal.id.uuidString, entityType: "JournalEntry")
        objectWillChange.send()
        return reversal
    }
    
    /// 生成冲销凭证编号
    private func nextReversalNumber(for entry: JournalEntry) -> String {
        let prefix = "冲-\(entry.number)-"
        let existing = journalEntries.filter { $0.number.hasPrefix(prefix) }
        return "\(prefix)\(existing.count + 1)"
    }
    func togglePosted(_ entry: JournalEntry, reason: String = "") -> Bool {
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
        } else {
            // 反过账检查：是否有后续结转凭证引用了本凭证涉及的分录行
            let ourAccountIDs = Set(entry.lines.compactMap { $0.accountID })
            let subsequentEntries = journalEntries.filter { $0.date > entry.date && $0.number.hasPrefix("结-") && $0.companyID == entry.companyID }
            for subsequent in subsequentEntries {
                let relatedLines = subsequent.lines.filter { ourAccountIDs.contains($0.accountID ?? UUID()) }
                if !relatedLines.isEmpty {
                    print("⚠️ 凭证 \(entry.number) 被结转凭证 \(subsequent.number) 引用，无法反过账")
                    return false
                }
            }
            // Phase 3.2: 反过账需要填写原因
            guard !reason.isEmpty else {
                print("⚠️ 反过账必须填写原因")
                return false
            }
        }
        entry.isPosted.toggle()
        entry.updatedAt = Date()
        // 过账时生成 SHA-256 哈希 + 链指针
        if entry.isPosted {
            entry.hash = JournalEntry.computeHash(for: entry)
            // 找上一张已过账凭证的哈希作为链指针
            let lastPostedHash = journalEntries
                .filter { $0.isPosted && $0.id != entry.id }
                .sorted { $0.date > $1.date || ($0.date == $1.date && $0.number > $1.number) }
                .first?.hash
            entry.previousHash = lastPostedHash
        } else {
            // 反过账时清除哈希
            entry.hash = nil
            entry.previousHash = nil
        }
        let actionLabel = entry.isPosted ? "过账" : "反过账"
        AccountingEngine.syncBalances(for: entry)
        // 增量更新余额缓存
        updateBalanceCache(for: entry)
        saveAll()
        let detail = reason.isEmpty ? "\(actionLabel)凭证: \(entry.number)" : "\(actionLabel)凭证: \(entry.number), 原因: \(reason)"
        addAuditLog(action: entry.isPosted ? "post" : "unpost", detail: detail, entityID: entry.id.uuidString, entityType: "JournalEntry")
        objectWillChange.send()
        return true
    }

    // MARK: - PeriodClose CRUD
    func addPeriodClose(_ pc: PeriodClose) {
        // 防止重复添加同一期间
        if let existing = periodCloses.first(where: { $0.companyID == pc.companyID && $0.year == pc.year && $0.month == pc.month }) {
            let wasClosed = existing.isClosed
            existing.isClosed = pc.isClosed
            existing.closedAt = pc.closedAt
            existing.closedBy = pc.closedBy
            if wasClosed != pc.isClosed {
                addAuditLog(action: pc.isClosed ? "closePeriod" : "unclosePeriod", detail: "\(pc.isClosed ? "结账" : "反结账"): \(pc.year)年\(pc.month)月", entityID: pc.id.uuidString, entityType: "PeriodClose")
            }
        } else {
            periodCloses.append(pc)
            if pc.isClosed {
                addAuditLog(action: "closePeriod", detail: "结账: \(pc.year)年\(pc.month)月", entityID: pc.id.uuidString, entityType: "PeriodClose")
            }
        }
        saveAll()
        objectWillChange.send()
    }

    func isPeriodClosed(companyID: UUID, year: Int, month: Int) -> Bool {
        periodCloses.contains { $0.companyID == companyID && $0.year == year && $0.month == month && $0.isClosed }
    }

    // MARK: - Invoice CRUD
    func addInvoice(_ invoice: Invoice) {
        invoices.append(invoice)
        saveAll()
        addAuditLog(action: "create", detail: "新增发票: \(invoice.invoiceNo) \(invoice.sellerName) ¥\(invoice.totalAmount)", entityID: invoice.id.uuidString, entityType: "Invoice")
        objectWillChange.send()
    }
    func updateInvoice(_ invoice: Invoice) {
        saveAll()
        addAuditLog(action: "update", detail: "更新发票: \(invoice.invoiceNo)", entityID: invoice.id.uuidString, entityType: "Invoice")
        objectWillChange.send()
    }
    func deleteInvoice(_ invoice: Invoice) {
        let no = invoice.invoiceNo
        invoices.removeAll { $0.id == invoice.id }
        saveAll()
        addAuditLog(action: "delete", detail: "删除发票: \(no)", entityID: invoice.id.uuidString, entityType: "Invoice")
        objectWillChange.send()
    }
    func invoices(for companyID: UUID) -> [Invoice] {
        invoices.filter { $0.companyID == companyID }
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

    func createDemoData() {
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
            ("2221.01", "应交增值税", .liability),
            ("2221.01.01", "进项税额", .liability),
            ("2221.01.02", "销项税额", .liability),
            ("2221.01.03", "进项税额转出", .liability),
            ("2221.01.04", "已交税金", .liability),
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
            if code == "1602" { a.balanceDirection = .credit }
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

        // 为 Demo 凭证构建哈希链（审计完整性）
        let demoEntries = [e1, e2, e3]
        var previousHash: String? = nil
        for entry in demoEntries {
            entry.hash = JournalEntry.computeHash(for: entry)
            entry.previousHash = previousHash
            previousHash = entry.hash
        }
        journalEntries = [e1, e2, e3]
        saveAll()
        // 重建余额缓存，确保报表能立即查询到 Demo 数据
        rebuildBalanceCache(for: company.id, year: 2026, month: 6)
    }
}

// MARK: - AI 助手消息

enum AISenderRole: String, Codable, CaseIterable {
    case user
    case assistant
}

struct AIMessage: Identifiable, Codable, Hashable {
    let id: UUID
    let role: AISenderRole
    let content: String
    let timestamp: Date

    init(role: AISenderRole, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }

    init(id: UUID = UUID(), role: AISenderRole, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
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
