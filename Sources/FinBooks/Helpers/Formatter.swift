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


    /// 百分数格式化（如 0.13 → "13.00%"）
    static func percent(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "0.00%"
    }

    /// 税率显示（如 0.13 → "13%"）
    static func taxRate(_ rate: Double) -> String {
        guard rate > 0 else { return "-" }
        let pct = Int(rate * 100)
        return "\(pct)%"
    }

    /// 大写金额（人民币，用于正式票据）
    /// 大写金额（人民币，用于正式票据 — 简化版）
    static func amountChinese(_ value: Decimal) -> String {
        let digits = ["零","壹","贰","叁","肆","伍","陆","柒","捌","玖"]
        let units = ["","拾","佰","仟"]
        let bigUnits = ["","万","亿"]
        
        let nsVal = value as NSDecimalNumber
        let yuanPart = nsVal.intValue
        let decPart = Int(round((nsVal.doubleValue - Double(yuanPart)) * 100))
        let jiao = decPart / 10
        let fen = decPart % 10
        
        guard yuanPart > 0 || jiao > 0 || fen > 0 else { return "零元整" }
        
        func convertSegment(_ n: Int) -> String {
            var s = n, r = "", zero = false
            for i in 0..<4 {
                let d = s % 10
                if d == 0 {
                    zero = true
                } else {
                    if zero { r = "零" + r; zero = false }
                    r = digits[d] + units[i] + r
                }
                s /= 10
            }
            return r
        }
        
        var result = "", yi = yuanPart, bigPos = 0, zeroSeg = false
        while yi > 0 {
            let seg = yi % 10000
            if seg == 0 {
                zeroSeg = true
            } else {
                if zeroSeg && bigPos > 0 { result = "零" + result }
                zeroSeg = false
                result = convertSegment(seg) + bigUnits[bigPos] + result
            }
            yi /= 10000
            bigPos += 1
        }
        
        result += "元"
        if jiao == 0 && fen == 0 {
            result += "整"
        } else {
            result += digits[jiao] + "角" + digits[fen] + "分"
        }
        return result
    }

    /// 金额缩写（用于 Dashboard 展示）
    static func amountShort(_ value: Decimal) -> String {
        let absVal = abs(value)
        if absVal >= 100_000_000 {
            return String(format: "%.2f亿", Double(truncating: NSDecimalNumber(decimal: value)) / 100_000_000.0)
        } else if absVal >= 10_000 {
            return String(format: "%.2f万", Double(truncating: NSDecimalNumber(decimal: value)) / 10_000.0)
        }
        return amount(value)
    }



    /// 税号格式化：自动匹配 15/18/20 位中国纳税人识别号格式
    /// - 15位: XXX XXXXX XXXXX XXX (3-5-5-2)
    /// - 18位: XX XXXXX XXXXX XXXXX (2-5-5-5-1, 组织机构代码格式) 
    ///        或 XXXXXXXX X XXXXXXXX X (8-1-8-1, 旧税务登记)
    /// - 20位: XXX XXXXX XXXXX XXXXX XXX (3-5-5-5-2, 统一社会信用代码)
    static func taxID(_ raw: String) -> String {
        let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !digits.isEmpty else { return raw }
        switch digits.count {
        case 15:
            // 旧税务登记号: XXX-XXXXX-XXXXX-XX (3-5-5-2)
            let parts = [
                String(digits.prefix(3)),
                String(digits.dropFirst(3).prefix(5)),
                String(digits.dropFirst(8).prefix(5)),
                String(digits.dropFirst(13))
            ]
            return parts.joined(separator: "-")
        case 18:
            // 组织机构代码或旧格式: XX-XXXXX-XXXXX-XXXXX-X (2-5-5-5-1)
            let parts = [
                String(digits.prefix(2)),
                String(digits.dropFirst(2).prefix(5)),
                String(digits.dropFirst(7).prefix(5)),
                String(digits.dropFirst(12).prefix(5)),
                String(digits.dropFirst(17))
            ]
            return parts.joined(separator: "-")
        case 20:
            // 统一社会信用代码（最新标准）: XXX-XXXXX-XXXXX-XXXXX-XXX (3-5-5-5-2)
            let parts = [
                String(digits.prefix(3)),
                String(digits.dropFirst(3).prefix(5)),
                String(digits.dropFirst(8).prefix(5)),
                String(digits.dropFirst(13).prefix(5)),
                String(digits.dropFirst(18))
            ]
            return parts.joined(separator: "-")
        default:
            // 无法识别长度，每4位一组
            if digits.count > 8 {
                return stride(from: 0, to: digits.count, by: 4).map { i in
                    String(digits.dropFirst(i).prefix(4))
                }.joined(separator: "-")
            }
            return digits
        }
    }

}