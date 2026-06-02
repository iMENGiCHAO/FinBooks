import Foundation
import AppKit
import SwiftUI

// ============================================================
//  PDF 导出引擎 v10 — NSView + NSAttributedString 原生排版
//  修复:
//  1. 使用 NSView.dataWithPDF 机制，确保中文字体正确嵌入
//  2. 资产负债表按中国会计准则格式（会企01表）
//  3. 利润表按中国会计准则格式（会企02表）
//  4. 所有单元格边框 + 文字居中/右对齐
// ============================================================

struct PDFExporter {

    // MARK: - 常量
    static let margin: CGFloat  = 48
    static let pageW: CGFloat   = 595.28       // A4
    static let pageH: CGFloat   = 841.89
    static var contentW: CGFloat { pageW - margin * 2 }
    static let rowH: CGFloat    = 20

    // MARK: - 金额
    static func rmb(_ val: Decimal) -> String {
        val >= 0 ? "¥\(FMT.amount(val))" : "-¥\(FMT.amount(abs(val)))"
    }

    // MARK: - NSView PDF 核心
    /// 使用 NSView.dataWithPDF 机制，确保中文字体正确嵌入
    private static func _renderCGPDF(filename: String, viewWidth: CGFloat = pageW, viewHeight: CGFloat = pageH,
                                      render: @escaping (CGContext, CGRect) -> Void) -> URL? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("_pdf_\(UUID().uuidString).pdf")

        // 用 NSView.dataWithPDF 生成 PDF，确保中文字体正确嵌入
        let pdfView = FlippedPDFView(frame: CGRect(x: 0, y: 0, width: viewWidth, height: viewHeight), renderBlock: render)
        let data = pdfView.dataWithPDF(inside: pdfView.bounds)

        do {
            try data.write(to: tmp)
        } catch {
            print("[PDF] 写入临时文件失败: \(error)")
            return nil
        }

        // 复制到目标位置
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dest = downloads.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
            print("[PDF] 已保存: \(dest.path)")
            return dest
        } catch {
            print("[PDF] 保存失败: \(error)")
            return tmp
        }
    }

    /// 自定义 NSView 子类，用标准坐标系渲染 PDF 内容（与原 CGContext 兼容）
    private class FlippedPDFView: NSView {
        let renderBlock: (CGContext, CGRect) -> Void
        init(frame: CGRect, renderBlock: @escaping (CGContext, CGRect) -> Void) {
            self.renderBlock = renderBlock
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { nil }
        override func draw(_ dirtyRect: CGRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            // 白色背景
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(bounds)
            renderBlock(ctx, bounds)
        }
    }

    // MARK: - 文字绘制工具

    /// 用 NSAttributedString 在指定 rect 中绘制文字
    static func drawText(_ text: String, rect: CGRect,
                          fontSize: CGFloat = 9, bold: Bool = false,
                          alignment: NSTextAlignment = .left,
                          color: NSColor = .black, lineBreak: NSLineBreakMode = .byWordWrapping) {
        guard !text.isEmpty else { return }
        // 使用 PingFang SC（苹方）确保中文字体在 PDF 上下文中正确渲染
        let fontName: String = bold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
        let font = NSFont(name: fontName, size: fontSize)
            ?? (bold ? NSFont.boldSystemFont(ofSize: fontSize) : NSFont.systemFont(ofSize: fontSize))
        let ps = NSMutableParagraphStyle()
        ps.alignment = alignment
        ps.lineBreakMode = lineBreak
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: ps
        ]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    /// 绘制带边框的单元格
    static func drawCell(_ text: String, rect: CGRect,
                          fontSize: CGFloat = 8, bold: Bool = false,
                          alignment: NSTextAlignment = .left,
                          color: NSColor = .black,
                          borderColor: CGColor = CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 0.6)) {
        // 边框
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setStrokeColor(borderColor)
        ctx.setLineWidth(0.4)
        ctx.stroke(rect)

        // 文字（留 3pt padding）
        let pr: CGFloat = 3
        let textRect = CGRect(x: rect.minX + pr, y: rect.minY + 1,
                              width: max(0, rect.width - pr * 2),
                              height: max(0, rect.height - 3))
        drawText(text, rect: textRect, fontSize: fontSize, bold: bold,
                 alignment: alignment, color: color, lineBreak: .byTruncatingTail)
    }

    /// 绘制横线
    static func drawLine(from: CGPoint, to: CGPoint, width: CGFloat = 0.8,
                          color: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.7)) {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()
    }

    // MARK: - 资产负债表（会企01表标准格式）

    /// 标准资产负债表格式（左右分栏：资产/负债及所有者权益）
    static func exportBalanceSheet(_ report: BalanceSheetReport) -> URL? {
        let gap: CGFloat = 16
        let sideW = (contentW - gap) / 2
        let cName = sideW * 0.32
        let cSeq  = sideW * 0.12
        let cEnd  = sideW * 0.28
        let cBeg  = sideW * 0.28

        let leftItems = buildBalanceItems(report.currentAssets + report.nonCurrentAssets)
        let rightItems = buildBalanceItems(report.currentLiabilities + report.nonCurrentLiabilities + report.equities)
        let maxRows = max(leftItems.count, rightItems.count) + 5
        let totalHeight = max(pageH, CGFloat(maxRows) * rowH + 160)

        return _renderCGPDF(filename: "资产负债表_\(FMT.date(report.date)).pdf",
                             viewWidth: pageW, viewHeight: totalHeight) { ctx, bounds in
            var y: CGFloat = totalHeight - margin - 26

            // 标题
            drawText("资产负债表", rect: CGRect(x: 0, y: y - 22, width: pageW, height: 26),
                     fontSize: 20, bold: true, alignment: .center)
            y -= 24
            drawText("会企01表", rect: CGRect(x: 0, y: y - 14, width: pageW, height: 14),
                     fontSize: 9, alignment: .center)
            y -= 18
            drawText("编制单位：\(report.companyName)",
                     rect: CGRect(x: margin, y: y - 14, width: contentW * 0.5, height: 14), fontSize: 9)
            drawText("单位：元", rect: CGRect(x: margin + contentW * 0.5, y: y - 14, width: contentW * 0.5, height: 14),
                     fontSize: 9, alignment: .right)
            y -= 18
            drawText("\(FMT.date(report.date))",
                     rect: CGRect(x: margin, y: y - 14, width: contentW, height: 14),
                     fontSize: 9, alignment: .right)
            y -= 18

            // 表头行
            var ox = margin
            for (t, w) in [("资产", cName), ("行次", cSeq), ("期末余额", cEnd), ("年初余额", cBeg)] {
                drawCell(t, rect: CGRect(x: ox, y: y - rowH, width: w, height: rowH), fontSize: 8, bold: true, alignment: .center)
                ox += w
            }
            ox = margin + sideW + gap
            for (t, w) in [("负债及所有者权益", cName), ("行次", cSeq), ("期末余额", cEnd), ("年初余额", cBeg)] {
                drawCell(t, rect: CGRect(x: ox, y: y - rowH, width: w, height: rowH), fontSize: 8, bold: true, alignment: .center)
                ox += w
            }
            y -= rowH

            // 数据行
            for i in 0..<maxRows {
                let cellY = y - rowH
                // 左栏
                if i < leftItems.count {
                    let (n, eb, bb) = leftItems[i]
                    drawCell(n, rect: CGRect(x: margin, y: cellY, width: cName, height: rowH), fontSize: 8)
                    drawCell("", rect: CGRect(x: margin + cName, y: cellY, width: cSeq, height: rowH), alignment: .center)
                    drawCell(eb, rect: CGRect(x: margin + cName + cSeq, y: cellY, width: cEnd, height: rowH), fontSize: 8, alignment: .right)
                    drawCell(bb, rect: CGRect(x: margin + cName + cSeq + cEnd, y: cellY, width: cBeg, height: rowH), fontSize: 8, alignment: .right)
                } else {
                    drawCell("", rect: CGRect(x: margin, y: cellY, width: sideW, height: rowH))
                }
                // 右栏
                if i < rightItems.count {
                    let (n, eb, bb) = rightItems[i]
                    let ro = margin + sideW + gap
                    drawCell(n, rect: CGRect(x: ro, y: cellY, width: cName, height: rowH), fontSize: 8)
                    drawCell("", rect: CGRect(x: ro + cName, y: cellY, width: cSeq, height: rowH), alignment: .center)
                    drawCell(eb, rect: CGRect(x: ro + cName + cSeq, y: cellY, width: cEnd, height: rowH), fontSize: 8, alignment: .right)
                    drawCell(bb, rect: CGRect(x: ro + cName + cSeq + cEnd, y: cellY, width: cBeg, height: rowH), fontSize: 8, alignment: .right)
                } else {
                    let ro = margin + sideW + gap
                    drawCell("", rect: CGRect(x: ro, y: cellY, width: sideW, height: rowH))
                }
                y -= rowH
            }

            y -= 4

            // 合计行
            func drawTotal(rowY: inout CGFloat, leftLabel: String, leftVal: String?, rightLabel: String, rightVal: String) {
                let rY = rowY - rowH
                let ro = margin + sideW + gap
                drawCell(leftLabel, rect: CGRect(x: margin, y: rY, width: cName + cSeq, height: rowH), fontSize: 8, bold: true)
                if let v = leftVal {
                    drawCell(v, rect: CGRect(x: margin + cName + cSeq, y: rY, width: cEnd, height: rowH), fontSize: 8, bold: true, alignment: .right)
                    drawCell("", rect: CGRect(x: margin + cName + cSeq + cEnd, y: rY, width: cBeg, height: rowH))
                } else {
                    drawCell("", rect: CGRect(x: margin + cName + cSeq, y: rY, width: cEnd + cBeg, height: rowH))
                }
                drawCell(rightLabel, rect: CGRect(x: ro, y: rY, width: cName + cSeq, height: rowH), fontSize: 8, bold: true)
                drawCell(rightVal, rect: CGRect(x: ro + cName + cSeq, y: rY, width: cEnd, height: rowH), fontSize: 8, bold: true, alignment: .right)
                drawCell("", rect: CGRect(x: ro + cName + cSeq + cEnd, y: rY, width: cBeg, height: rowH))
                rowY -= rowH
            }

            drawTotal(rowY: &y, leftLabel: "资产总计",
                      leftVal: rmb(report.totalAssets),
                      rightLabel: "负债合计",
                      rightVal: rmb(report.totalLiabilities))
            drawTotal(rowY: &y, leftLabel: "", leftVal: nil,
                      rightLabel: "所有者权益合计",
                      rightVal: rmb(report.totalEquities))
            drawTotal(rowY: &y, leftLabel: "", leftVal: nil,
                      rightLabel: "负债及所有者权益总计",
                      rightVal: rmb(report.totalLE))

            // 签字
            y -= rowH
            drawLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: margin + contentW, y: y), width: 1.0)
            y -= 16
            drawText("企业负责人：__________    主管会计：__________    制表人：__________",
                     rect: CGRect(x: margin, y: y - 12, width: contentW, height: 14), fontSize: 9, alignment: .center)
        }
    }

    // MARK: - 利润表（会企02表标准格式）

    static func exportIncomeStatement(_ report: IncomeStatementReport) -> URL? {
        let cProj = contentW * 0.34
        let cSeq  = contentW * 0.10
        let cAmt  = contentW * 0.28
        let cCum  = contentW * 0.28

        // 构建行
        var rows: [(String, String, String, Bool)] = []
        rows.append(("一、营业收入", rmb(report.totalRevenue), rmb(report.totalRevenueCumulative), true))
        for rev in report.revenues {
            rows.append(("  \(rev.name)", rmb(rev.amount), rmb(rev.cumulativeAmount), false))
        }
        // 固定的标准费用行
        let feeDefs: [(String, String)] = [
            ("减：营业成本", "6001"), ("    税金及附加", "6401"),
            ("    销售费用", "6601"), ("    管理费用", "6602"), ("    财务费用", "6603")
        ]
        for (label, code) in feeDefs {
            if let e = report.expenses.first(where: { $0.code == code }), e.amount != 0 || e.cumulativeAmount != 0 {
                rows.append((label, rmb(e.amount), rmb(e.cumulativeAmount), label.hasPrefix("减：")))
            } else {
                rows.append((label, "", "", label.hasPrefix("减：")))
            }
        }
        rows.append(("二、营业利润", rmb(report.operatingProfit), rmb(report.operatingProfitCumulative), true))
        if report.incomeTax != 0 || report.incomeTaxCumulative != 0 {
            rows.append(("减：所得税费用", rmb(report.incomeTax), rmb(report.incomeTaxCumulative), false))
        }
        rows.append(("三、净利润", rmb(report.netProfit), rmb(report.netProfitCumulative), true))

        let totalRows = rows.count + 6
        let totalHeight = max(pageH, CGFloat(totalRows) * rowH + 180)

        return _renderCGPDF(filename: "利润表_\(report.year)_\(String(format: "%02d", report.month)).pdf",
                             viewWidth: pageW, viewHeight: totalHeight) { ctx, bounds in
            var y: CGFloat = totalHeight - margin - 26

            drawText("利润表", rect: CGRect(x: 0, y: y - 22, width: pageW, height: 26),
                     fontSize: 20, bold: true, alignment: .center)
            y -= 24
            drawText("会企02表", rect: CGRect(x: 0, y: y - 14, width: pageW, height: 14),
                     fontSize: 9, alignment: .center)
            y -= 18
            drawText("编制单位：\(report.companyName)",
                     rect: CGRect(x: margin, y: y - 14, width: contentW * 0.5, height: 14), fontSize: 9)
            drawText("单位：元", rect: CGRect(x: margin + contentW * 0.5, y: y - 14, width: contentW * 0.5, height: 14),
                     fontSize: 9, alignment: .right)
            y -= 18
            drawText("\(report.year)年\(report.month)月",
                     rect: CGRect(x: margin, y: y - 14, width: contentW, height: 14),
                     fontSize: 9, alignment: .right)
            y -= 18

            // 表头
            var ox = margin
            for (t, w) in [("项目", cProj), ("行次", cSeq), ("本期金额", cAmt), ("本年累计", cCum)] {
                drawCell(t, rect: CGRect(x: ox, y: y - rowH, width: w, height: rowH), fontSize: 8, bold: true, alignment: .center)
                ox += w
            }
            y -= rowH

            // 数据行
            for (label, amt, cum, isBold) in rows {
                let rY = y - rowH
                drawCell(label, rect: CGRect(x: margin, y: rY, width: cProj, height: rowH), fontSize: 8, bold: isBold)
                drawCell("", rect: CGRect(x: margin + cProj, y: rY, width: cSeq, height: rowH), alignment: .center)
                drawCell(amt, rect: CGRect(x: margin + cProj + cSeq, y: rY, width: cAmt, height: rowH), fontSize: 8, bold: isBold, alignment: .right)
                drawCell(cum, rect: CGRect(x: margin + cProj + cSeq + cAmt, y: rY, width: cCum, height: rowH), fontSize: 8, bold: isBold, alignment: .right)
                y -= rowH
            }

            y -= rowH
            drawLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: margin + contentW, y: y), width: 1.0)
            y -= 16
            drawText("企业负责人：__________    主管会计：__________    制表人：__________",
                     rect: CGRect(x: margin, y: y - 12, width: contentW, height: 14), fontSize: 9, alignment: .center)
        }
    }

    // MARK: - 总分类账

    static func exportGeneralLedger(_ report: GeneralLedgerReport) -> URL? {
        let colWidths: [CGFloat] = [70, 100, 155, 85, 85, 40, 85]
        let sc = contentW / colWidths.reduce(0, +)
        let cols = colWidths.map { $0 * sc }

        let totalRows = report.lines.count + 8
        let totalHeight = max(pageH, CGFloat(totalRows) * rowH + 180)

        return _renderCGPDF(filename: "总分类账_\(report.account.code)_\(report.account.name).pdf",
                             viewWidth: pageW, viewHeight: totalHeight) { ctx, bounds in
            var y: CGFloat = totalHeight - margin - 26

            drawText("总分类账", rect: CGRect(x: 0, y: y - 22, width: pageW, height: 26),
                     fontSize: 18, bold: true, alignment: .center)
            y -= 26
            drawText("科目：\(report.account.code) \(report.account.name)    类别：\(report.account.category.rawValue)",
                     rect: CGRect(x: margin, y: y - 14, width: contentW, height: 14), fontSize: 9)
            y -= 18
            drawText("\(report.year)年\(report.month)月",
                     rect: CGRect(x: margin, y: y - 14, width: contentW, height: 14), fontSize: 9, alignment: .right)
            y -= 18
            let d0 = report.openingBalance >= 0 ? "借" : "贷"
            drawText("期初余额：\(d0)  \(rmb(abs(report.openingBalance)))",
                     rect: CGRect(x: margin, y: y - 14, width: contentW, height: 14), fontSize: 9)
            y -= 20

            // 表头
            let header = ["日期", "凭证号", "摘要", "借方金额", "贷方金额", "方向", "余额"]
            var ox = margin
            for (w, t) in zip(cols, header) {
                drawCell(t, rect: CGRect(x: ox, y: y - rowH, width: w, height: rowH), fontSize: 8, bold: true, alignment: .center)
                ox += w
            }
            y -= rowH

            for line in report.lines {
                let rY = y - rowH
                ox = margin
                let vals = [FMT.date(line.date), line.voucherNumber, line.summary,
                            line.debit > 0 ? rmb(line.debit) : "",
                            line.credit > 0 ? rmb(line.credit) : "",
                            line.direction, rmb(line.runningBalance)]
                for (i, v) in vals.enumerated() {
                    let al: NSTextAlignment = i >= 3 ? .right : (i == 5 ? .center : .left)
                    drawCell(v, rect: CGRect(x: ox, y: rY, width: cols[i], height: rowH), fontSize: 8, alignment: al)
                    ox += cols[i]
                }
                y -= rowH
            }

            y -= 4
            // 合计
            let pd = report.lines.reduce(Decimal.zero) { $0 + $1.debit }
            let pc = report.lines.reduce(Decimal.zero) { $0 + $1.credit }
            let sumY = y - rowH
            ox = margin
            drawCell("", rect: CGRect(x: ox, y: sumY, width: cols[0], height: rowH)); ox += cols[0]
            drawCell("", rect: CGRect(x: ox, y: sumY, width: cols[1], height: rowH)); ox += cols[1]
            drawCell("本期合计", rect: CGRect(x: ox, y: sumY, width: cols[2], height: rowH), fontSize: 8, bold: true); ox += cols[2]
            drawCell(rmb(pd), rect: CGRect(x: ox, y: sumY, width: cols[3], height: rowH), fontSize: 8, bold: true, alignment: .right); ox += cols[3]
            drawCell(rmb(pc), rect: CGRect(x: ox, y: sumY, width: cols[4], height: rowH), fontSize: 8, bold: true, alignment: .right); ox += cols[4]
            drawCell("", rect: CGRect(x: ox, y: sumY, width: cols[5], height: rowH)); ox += cols[5]
            drawCell("", rect: CGRect(x: ox, y: sumY, width: cols[6], height: rowH))
            y -= rowH

            // 期末
            let d1 = report.closingBalance >= 0 ? "借" : "贷"
            let endY = y - rowH
            ox = margin
            drawCell("", rect: CGRect(x: ox, y: endY, width: cols[0], height: rowH)); ox += cols[0]
            drawCell("", rect: CGRect(x: ox, y: endY, width: cols[1], height: rowH)); ox += cols[1]
            drawCell("期末余额", rect: CGRect(x: ox, y: endY, width: cols[2], height: rowH), fontSize: 8, bold: true); ox += cols[2]
            drawCell("", rect: CGRect(x: ox, y: endY, width: cols[3] + cols[4], height: rowH)); ox += cols[3] + cols[4]
            drawCell(d1, rect: CGRect(x: ox, y: endY, width: cols[5], height: rowH), fontSize: 8, bold: true, alignment: .center); ox += cols[5]
            drawCell(rmb(abs(report.closingBalance)), rect: CGRect(x: ox, y: endY, width: cols[6], height: rowH), fontSize: 8, bold: true, alignment: .right)

            y -= rowH + 8
            drawLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: margin + contentW, y: y), width: 1.0)
            y -= 16
            drawText("企业负责人：__________    主管会计：__________    制表人：__________",
                     rect: CGRect(x: margin, y: y - 12, width: contentW, height: 14), fontSize: 9, alignment: .center)
        }
    }

    // MARK: - 凭证清单

    static func exportVoucherList(entries: [JournalEntry], companyName: String) -> URL? {
        let colWidths: [CGFloat] = [75, 100, 155, 80, 80, 45, 45]
        let sc = contentW / colWidths.reduce(0, +)
        let cols = colWidths.map { $0 * sc }

        let totalRows = entries.count + 6
        let totalHeight = max(pageH, CGFloat(totalRows) * rowH + 180)

        return _renderCGPDF(filename: "凭证清单_\(FMT.date(Date())).pdf",
                             viewWidth: pageW, viewHeight: totalHeight) { ctx, bounds in
            var y: CGFloat = totalHeight - margin - 26

            drawText("记账凭证清单", rect: CGRect(x: 0, y: y - 22, width: pageW, height: 26),
                     fontSize: 18, bold: true, alignment: .center)
            y -= 28
            drawText("编制单位：\(companyName)",
                     rect: CGRect(x: margin, y: y - 14, width: contentW, height: 14), fontSize: 9)
            drawText("打印日期：\(FMT.date(Date()))    共 \(entries.count) 张凭证",
                     rect: CGRect(x: margin + contentW * 0.3, y: y - 14, width: contentW * 0.7, height: 14),
                     fontSize: 9, alignment: .right)
            y -= 20

            let header = ["日期", "凭证号", "摘要", "借方合计", "贷方合计", "状态", "分录"]
            var ox = margin
            for (w, t) in zip(cols, header) {
                drawCell(t, rect: CGRect(x: ox, y: y - rowH, width: w, height: rowH), fontSize: 8, bold: true, alignment: .center)
                ox += w
            }
            y -= rowH

            for e in entries {
                let rY = y - rowH
                ox = margin
                let vals = [FMT.date(e.date), e.number, e.summary,
                            rmb(e.debitTotal), rmb(e.creditTotal),
                            e.isPosted ? "已过账" : "未过账", "\(e.lines.count)条"]
                for (i, v) in vals.enumerated() {
                    let al: NSTextAlignment = i >= 3 ? .right : (i == 5 ? .center : .left)
                    drawCell(v, rect: CGRect(x: ox, y: rY, width: cols[i], height: rowH), fontSize: 8, alignment: al)
                    ox += cols[i]
                }
                y -= rowH
            }

            y -= 4
            let td = entries.reduce(Decimal.zero) { $0 + $1.debitTotal }
            let tc = entries.reduce(Decimal.zero) { $0 + $1.creditTotal }
            drawText("借方合计：\(rmb(td))    贷方合计：\(rmb(tc))    凭证张数：\(entries.count)",
                     rect: CGRect(x: margin, y: y - 16, width: contentW, height: 16),
                     fontSize: 9, bold: true, alignment: .center)
            y -= 24

            drawLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: margin + contentW, y: y), width: 1.0)
            y -= 16
            drawText("企业负责人：__________    主管会计：__________    制表人：__________",
                     rect: CGRect(x: margin, y: y - 12, width: contentW, height: 14), fontSize: 9, alignment: .center)
        }
    }

    // MARK: - 构建列表

    private static func buildBalanceItems(_ lines: [BalanceLine]) -> [(String, String, String)] {
        var items: [(String, String, String)] = []
        // 加小计行
        let groups = Dictionary(grouping: lines) { line -> String in
            if let code = Int(line.code) {
                return String(code / 100)
            }
            return "0"
        }
        for key in groups.keys.sorted() {
            if let group = groups[key] {
                if group.count > 1 {
                    let total = group.reduce(Decimal.zero) { $0 + $1.balance }
                    let totalBeg = group.reduce(Decimal.zero) { $0 + $1.beginningBalance }
                    items.append(("  \(group.first?.name.prefix(2) ?? "")类合计", rmb(total), rmb(totalBeg)))
                }
                for item in group {
                    items.append(("  \(item.name)", rmb(item.balance), rmb(item.beginningBalance)))
                }
            }
        }
        return items
    }
}