import Foundation
import CoreGraphics
import AppKit

// Duplicate the key types to test independently
struct BalanceLine { let code, name: String; let balance, beginningBalance: Decimal }
struct BalanceSheetReport {
    let companyName, currency: String
    let date: Date
    let currentAssets: [BalanceLine]
    let nonCurrentAssets: [BalanceLine]
    let currentLiabilities: [BalanceLine]
    let nonCurrentLiabilities: [BalanceLine]
    let equities: [BalanceLine]
}

struct IncomeLine { let code, name: String; let amount, cumulativeAmount: Decimal }
struct IncomeStatementReport {
    let companyName, currency: String
    let year, month: Int
    let revenues: [IncomeLine]
    let expenses: [IncomeLine]
    let operatingProfit, operatingProfitCumulative: Decimal
    let incomeTax, incomeTaxCumulative: Decimal
}

// Test: Simple page with text
func testSimpleText() {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_simple.pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    guard let consumer = CGDataConsumer(url: tmp as CFURL),
          let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        print("FAIL: Could not create context"); return
    }
    ctx.beginPDFPage(nil)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 595.28, height: 841.89))

    // Draw text at various y positions
    let font = NSFont.systemFont(ofSize: 12)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    ("测试文字 at y=50 (page bottom)" as NSString).draw(in: CGRect(x: 50, y: 50, width: 400, height: 20), withAttributes: attrs)

    let boldFont = NSFont.boldSystemFont(ofSize: 18)
    let boldAttrs: [NSAttributedString.Key: Any] = [.font: boldFont, .foregroundColor: NSColor.black]
    ("资产负债表" as NSString).draw(in: CGRect(x: 50, y: 100, width: 200, height: 25), withAttributes: boldAttrs)

    let blueAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.blue]
    ("¥1,234,567.89 借方金额" as NSString).draw(in: CGRect(x: 50, y: 150, width: 300, height: 18), withAttributes: blueAttrs)

    let smallAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.darkGray]
    ("编制单位：示例科技有限公司    单位：元" as NSString).draw(in: CGRect(x: 50, y: 200, width: 500, height: 14), withAttributes: smallAttrs)

    ("利润表 at y=300" as NSString).draw(in: CGRect(x: 50, y: 300, width: 200, height: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black])

    // Draw a table cell
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
    ctx.setLineWidth(0.5)
    ctx.stroke(CGRect(x: 50, y: 400, width: 100, height: 25))
    ("库存现金" as NSString).draw(in: CGRect(x: 55, y: 404, width: 90, height: 17), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black])

    // Multiple cells in a row
    let cellY: CGFloat = 450
    let cells = ["项目", "行次", "本期金额", "本年累计"]
    let widths: [CGFloat] = [180, 40, 110, 110]
    var cx: CGFloat = 50
    for (i, txt) in cells.enumerated() {
        ctx.stroke(CGRect(x: cx, y: cellY, width: widths[i], height: 25))
        (txt as NSString).draw(in: CGRect(x: cx + 3, y: cellY + 4, width: widths[i] - 6, height: 17),
                              withAttributes: [.font: NSFont.boldSystemFont(ofSize: 9), .foregroundColor: NSColor.black])
        cx += widths[i]
    }

    ctx.endPDFPage()
    ctx.closePDF()
    print("OK: test_simple.pdf → \(tmp.path)")
}

testSimpleText()
