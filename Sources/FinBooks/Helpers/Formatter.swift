import Foundation

struct FMT {
    /// 金额格式化 — 两位小数，千分位
    static func amount(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        return formatter.string(from: value as NSDecimalNumber) ?? "0.00"
    }

    /// 日期格式化
    static func date(_ date: Date, format: String = "yyyy-MM-dd") -> String {
        let f = DateFormatter()
        f.dateFormat = format
        return f.string(from: date)
    }

    /// 日期时间格式化
    static func datetime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    /// 颜色 — 借方蓝字，贷方红字，零值灰色
    static func amountColor(_ value: Decimal) -> String {
        if value > 0 { return "debitColor" }
        if value < 0 { return "creditColor" }
        return "zeroColor"
    }
}
