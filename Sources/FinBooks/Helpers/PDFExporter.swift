import Foundation
import AppKit
import SwiftUI

// ============================================================
//  PDF 导出引擎 v11 — NSView + NSAttributedString 原生排版
//  修正: isFlipped=true 坐标系下 y 方向
//  1. 使用 NSView.dataWithPDF 机制，确保中文字体正确嵌入
//  2. 资产负债表按标准格式
//  3. 利润表按标准格式
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
    /// 注意：FlippedPDFView 继承 NSView 并 isFlipped=true，
    ///       所以 y=0 在左上角，y 增长方向向下。
    ///       绘制代码应从 y=margin 开始，每次 y += rowH（向下画）。
    private static func _renderCGPDF(filename: String, viewWidth: CGFloat = pageW, viewHeight: CGFloat = pageH,
                                      render: @escaping (CGContext, CGRect) -> Void) -> URL? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("_pdf_\(UUID().uuidString).pdf")

        let pdfView = FlippedPDFView(frame: CGRect(x: 0, y: 0, width: viewWidth, height: viewHeight), renderBlock: render)
        let data = pdfView.dataWithPDF(inside: pdfView.bounds)

        do {
            try data.write(to: tmp)
        } catch {
            print("[PDF] 写入临时文件失败: \(error)")
            return nil
        }

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

    /// 自定义 NSView 子类，Flipped 坐标系确保 NSString.draw(in:) 正确渲染中文
    private class FlippedPDFView: NSView {
        override var isFlipped: Bool { true }
        let renderBlock: (CGContext, CGRect) -> Void
        init(frame: CGRect, renderBlock: @escaping (CGContext, CGRect) -> Void) {
            self.renderBlock = renderBlock
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { nil }
        override func draw(_ dirtyRect: CGRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
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
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setStrokeColor(borderColor)
        ctx.setLineWidth(0.4)
        ctx.stroke(rect)

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

    // MARK: - 资产负债表

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
            var y: CGFloat = margin
            var ox = margin

            // 标题
            drawText("资产负债表", rect: CGRect(x: 0, y: y, width: pageW, height: 26),
                     fontSize: 20, bold: true, alignment: .center)
            y += 26
            drawText("会企01表", rect: CGRect(x: 0, y: y, width: pageW, height: 14),
                     fontSize: 9, alignment: .center)
            y += 16
            drawText("编制单位：\(report.companyName)",
                     rect: CGRect(x: margin, y: y, width: contentW * 0.5, height: 14), fontSize: 9)
            drawText("单位：元", rect: CGRect(x: margin + contentW * 0.5, y: y, width: contentW * 0.5, height: 14),
                     fontSize: 9, alignment: .right)
            y += 16
            drawText("\(FMT.date(report.date))",
                     rect: CGRect(x: margin, y: y, width: contentW, height: 14),
                     fontSize: 9, alignment: .right)
            y += 16

            // 表头行
            ox = margin
            for (t, w) in [("资产", cName), ("行次", cSeq), ("期末余额", cEnd), ("年初余额", cBeg)] {
                drawCell(t, rect: CGRect(x: ox, y: y, width: w, height: rowH), fontSize: 8, bold: true, alignment: .center)
                ox += w
            }
            ox = margin + sideW + gap
            for (t, w) in [("负债及所有者权益", cName), ("行次", cSeq), ("期末余额", cEnd), ("年初余额", cBeg)] {
                drawCell(t, rect: CGRect(x: ox, y: y, width: w, height: rowH), fontSize: 8, bold: true, alignment: .center)
                ox += w
            }
            y += rowH

            // 数据行
            for i in 0..<maxRows {
                let cellY = y
                if i < leftItems.count {
                    let (n, eb, bb) = leftItems[i]
                    drawCell(n, rect: CGRect(x: margin, y: cellY, width: cName, height: rowH), fontSize: 8)
                    drawCell("", rect: CGRect(x: margin + cName, y: cellY, width: cSeq, height: rowH), alignment: .center)
                    drawCell(eb, rect: CGRect(x: margin + cName + cSeq, y: cellY, width: cEnd, height: rowH), fontSize: 8, alignment: .right)
                    drawCell(bb, rect: CGRect(x: margin + cName + cSeq + cEnd, y: cellY, width: cBeg, height: rowH), fontSize: 8, alignment: .right)
                } else {
                    drawCell("", rect: CGRect(x: margin, y: cellY, width: sideW, height: rowH))
                }
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
                y += rowH
            }

            y += 4

            // 合计行
            func drawTotal(rowY: inout CGFloat, leftLabel: String, leftVal: String?, rightLabel: String, rightVal: String) {
                let rY = rowY
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
                rowY += rowH
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
            y += rowH
            drawLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: margin + contentW, y: y), width: 1.0)
            y += 16
            drawText("企业负责人：__________    主管会计：__________    制表人：__________",
                     rect: CGRect(x: margin, y: y, width: contentW, height: 14), fontSize: 9, alignment: .center)
        }
    }

    // MARK: - 利润表

    static func exportIncomeStatement(_ report: IncomeStatementReport) -> URL? {
        let cProj = contentW * 0.34
        let cSeq  = contentW * 0.10
        let cAmt  = contentW * 0.28
        let cCum  = contentW * 0.28

        var rows: [(String, String, String, Bool)] = []
        rows.append(("一、营业收入", rmb(report.totalRevenue), rmb(report.totalRevenueCumulative), true))
        for rev in report.revenues {
            rows.append(("  \(rev.name)", rmb(rev.amount), rmb(rev.cumulativeAmount), false))
        }
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
            var y: CGFloat = margin
            var ox = margin

            drawText("利润表", rect: CGRect(x: 0, y: y, width: pageW, height: 26),
                     fontSize: 20, bold: true, alignment: .center)
            y += 26
            drawText("会企02表", rect: CGRect(x: 0, y: y, width: pageW, height: 14),
                     fontSize: 9, alignment: .center)
            y += 16
            drawText("编制单位：\(report.companyName)",
                     rect: CGRect(x: margin, y: y, width: contentW * 0.5, height: 14), fontSize: 9)
            drawText("单位：元", rect: CGRect(x: margin + contentW * 0.5, y: y, width: contentW * 0.5, height: 14),
                     fontSize: 9, alignment: .right)
            y += 16
            drawText("\(report.year)年\(report.month)月",
                     rect: CGRect(x: margin, y: y, width: contentW, height: 14),
                     fontSize: 9, alignment: .right)
            y += 16

            // 表头
            ox = margin
            for (t, w) in [("项目", cProj), ("行次", cSeq), ("本期金额", cAmt), ("本年累计", cCum)] {
                drawCell(t, rect: CGRect(x: ox, y: y, width: w, height: rowH), fontSize: 8, bold: true, alignment: .center)
                ox += w
            }
            y += rowH

            // 数据行
            for (label, amt, cum, isBold) in rows {
                let rY = y
                drawCell(label, rect: CGRect(x: margin, y: rY, width: cProj, height: rowH), fontSize: 8, bold: isBold)
                drawCell("", rect: CGRect(x: margin + cProj, y: rY, width: cSeq, height: rowH), alignment: .center)
                drawCell(amt, rect: CGRect(x: margin + cProj + cSeq, y: rY, width: cAmt, height: rowH), fontSize: 8, bold: isBold, alignment: .right)
                drawCell(cum, rect: CGRect(x: margin + cProj + cSeq + cAmt, y: rY, width: cCum, height: rowH), fontSize: 8, bold: isBold, alignment: .right)
                y += rowH
            }

            y += rowH
            drawLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: margin + contentW, y: y), width: 1.0)
            y += 16
            drawText("企业负责人：__________    主管会计：__________    制表人：__________",
                     rect: CGRect(x: margin, y: y, width: contentW, height: 14), fontSize: 9, alignment: .center)
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
            var y: CGFloat = margin
            var ox = margin

            drawText("总分类账", rect: CGRect(x: 0, y: y, width: pageW, height: 26),
                     fontSize: 18, bold: true, alignment: .center)
            y += 26
            drawText("科目：\(report.account.code) \(report.account.name)    类别：\(report.account.category.rawValue)",
                     rect: CGRect(x: margin, y: y, width: contentW, height: 14), fontSize: 9)
            y += 16
            drawText("\(report.year)年\(report.month)月",
                     rect: CGRect(x: margin, y: y, width: contentW, height: 14), fontSize: 9, alignment: .right)
            y += 16
            let d0 = report.openingBalance >= 0 ? "借" : "贷"
            drawText("期初余额：\(d0)  \(rmb(abs(report.openingBalance)))",
                     rect: CGRect(x: margin, y: y, width: contentW, height: 14), fontSize: 9)
            y += 18

            // 表头
            let header = ["日期", "凭证号", "摘要", "借方金额", "贷方金额", "方向", "余额"]
            ox = margin
            for (w, t) in zip(cols, header) {
                drawCell(t, rect: CGRect(x: ox, y: y, width: w, height: rowH), fontSize: 8, bold: true, alignment: .center)
                ox += w
            }
            y += rowH

            for line in report.lines {
                let rY = y
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
                y += rowH
            }

            y += 4
            let pd = report.lines.reduce(Decimal.zero) { $0 + $1.debit }
            let pc = report.lines.reduce(Decimal.zero) { $0 + $1.credit }
            let sumY = y
            ox = margin
            drawCell("", rect: CGRect(x: ox, y: sumY, width: cols[0], height: rowH)); ox += cols[0]
            drawCell("", rect: CGRect(x: ox, y: sumY, width: cols[1], height: rowH)); ox += cols[1]
            drawCell("本期合计", rect: CGRect(x: ox, y: sumY, width: cols[2], height: rowH), fontSize: 8, bold: true); ox += cols[2]
            drawCell(rmb(pd), rect: CGRect(x: ox, y: sumY, width: cols[3], height: rowH), fontSize: 8, bold: true, alignment: .right); ox += cols[3]
            drawCell(rmb(pc), rect: CGRect(x: ox, y: sumY, width: cols[4], height: rowH), fontSize: 8, bold: true, alignment: .right); ox += cols[4]
            drawCell("", rect: CGRect(x: ox, y: sumY, width: cols[5], height: rowH)); ox += cols[5]
            drawCell("", rect: CGRect(x: ox, y: sumY, width: cols[6], height: rowH))
            y += rowH

            let d1 = report.closingBalance >= 0 ? "借" : "贷"
            let endY = y
            ox = margin
            drawCell("", rect: CGRect(x: ox, y: endY, width: cols[0], height: rowH)); ox += cols[0]
            drawCell("", rect: CGRect(x: ox, y: endY, width: cols[1], height: rowH)); ox += cols[1]
            drawCell("期末余额", rect: CGRect(x: ox, y: endY, width: cols[2], height: rowH), fontSize: 8, bold: true); ox += cols[2]
            drawCell("", rect: CGRect(x: ox, y: endY, width: cols[3] + cols[4], height: rowH)); ox += cols[3] + cols[4]
            drawCell(d1, rect: CGRect(x: ox, y: endY, width: cols[5], height: rowH), fontSize: 8, bold: true, alignment: .center); ox += cols[5]
            drawCell(rmb(abs(report.closingBalance)), rect: CGRect(x: ox, y: endY, width: cols[6], height: rowH), fontSize: 8, bold: true, alignment: .right)

            y += rowH + 8
            drawLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: margin + contentW, y: y), width: 1.0)
            y += 16
            drawText("企业负责人：__________    主管会计：__________    制表人：__________",
                     rect: CGRect(x: margin, y: y, width: contentW, height: 14), fontSize: 9, alignment: .center)
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
            var y: CGFloat = margin
            var ox = margin

            drawText("记账凭证清单", rect: CGRect(x: 0, y: y, width: pageW, height: 26),
                     fontSize: 18, bold: true, alignment: .center)
            y += 26
            drawText("编制单位：\(companyName)",
                     rect: CGRect(x: margin, y: y, width: contentW, height: 14), fontSize: 9)
            drawText("打印日期：\(FMT.date(Date()))    共 \(entries.count) 张凭证",
                     rect: CGRect(x: margin + contentW * 0.3, y: y, width: contentW * 0.7, height: 14),
                     fontSize: 9, alignment: .right)
            y += 18

            let header = ["日期", "凭证号", "摘要", "借方合计", "贷方合计", "状态", "分录"]
            ox = margin
            for (w, t) in zip(cols, header) {
                drawCell(t, rect: CGRect(x: ox, y: y, width: w, height: rowH), fontSize: 8, bold: true, alignment: .center)
                ox += w
            }
            y += rowH

            for e in entries {
                let rY = y
                ox = margin
                let vals = [FMT.date(e.date), e.number, e.summary,
                            rmb(e.debitTotal), rmb(e.creditTotal),
                            e.isPosted ? "已过账" : "未过账", "\(e.lines.count)条"]
                for (i, v) in vals.enumerated() {
                    let al: NSTextAlignment = i >= 3 ? .right : (i == 5 ? .center : .left)
                    drawCell(v, rect: CGRect(x: ox, y: rY, width: cols[i], height: rowH), fontSize: 8, alignment: al)
                    ox += cols[i]
                }
                y += rowH
            }

            y += 4
            let td = entries.reduce(Decimal.zero) { $0 + $1.debitTotal }
            let tc = entries.reduce(Decimal.zero) { $0 + $1.creditTotal }
            drawText("借方合计：\(rmb(td))    贷方合计：\(rmb(tc))    凭证张数：\(entries.count)",
                     rect: CGRect(x: margin, y: y, width: contentW, height: 16),
                     fontSize: 9, bold: true, alignment: .center)
            y += 22

            drawLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: margin + contentW, y: y), width: 1.0)
            y += 16
            drawText("企业负责人：__________    主管会计：__________    制表人：__________",
                     rect: CGRect(x: margin, y: y, width: contentW, height: 14), fontSize: 9, alignment: .center)
        }
    }

    // MARK: - 增值税申报表

    /// 增值税申报表 PDF 导出（符合一般纳税人申报格式）
    static func exportVATReport(_ report: VATReport) -> URL? {
        let cLabel = contentW * 0.25
        let cAmount = contentW * 0.35
        let cDesc = contentW * 0.40

        let totalRows = 16 + report.rateBreakdown.count + report.inputDetails.count + report.outputDetails.count
        let totalHeight = max(pageH, CGFloat(totalRows) * rowH + 200)

        return _renderCGPDF(filename: "增值税申报表_\(report.year)_\(String(format: "%02d", report.month)).pdf",
                             viewWidth: pageW, viewHeight: totalHeight) { ctx, bounds in
            var y: CGFloat = margin
            var ox = margin

            // 标题
            drawText("增值税申报表", rect: CGRect(x: 0, y: y, width: pageW, height: 26),
                     fontSize: 20, bold: true, alignment: .center)
            y += 26
            drawText("（一般纳税人适用）", rect: CGRect(x: 0, y: y, width: pageW, height: 14),
                     fontSize: 9, alignment: .center)
            y += 16
            drawText("纳税人名称：\(report.companyName)",
                     rect: CGRect(x: margin, y: y, width: contentW * 0.6, height: 14), fontSize: 9)
            drawText("所属期：\(report.period)", rect: CGRect(x: margin + contentW * 0.6, y: y, width: contentW * 0.4, height: 14),
                     fontSize: 9, alignment: .right)
            y += 16
            drawText("单位：元（人民币）", rect: CGRect(x: margin, y: y, width: contentW, height: 14),
                     fontSize: 9, alignment: .right)
            y += 18

            // 税额汇总表
            let summaryRows: [(String, Decimal, String)] = [
                ("一、销项税额", report.outputTotal, "销项税额合计"),
                ("二、进项税额", report.inputTotal, "进项税额合计"),
                ("三、进项税额转出", report.transferOutTotal, ""),
                ("四、可抵扣税额", report.deductible, ""),
                ("五、应纳增值税", report.payable, ""),
                ("六、已预缴税额", report.alreadyPaid, ""),
            ]

            for (label, amount, note) in summaryRows {
                let rY = y
                drawCell(label, rect: CGRect(x: margin, y: rY, width: cLabel, height: rowH), fontSize: 9, bold: true)
                drawCell(rmb(amount), rect: CGRect(x: margin + cLabel, y: rY, width: cAmount, height: rowH), fontSize: 9, alignment: .right)
                drawCell(note, rect: CGRect(x: margin + cLabel + cAmount, y: rY, width: cDesc, height: rowH), fontSize: 8, alignment: .left)
                y += rowH
            }

            // 分隔线
            y += 4
            drawLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: margin + contentW, y: y), width: 1.5)
            y += 12

            // 应补/退税额
            let color: NSColor = report.stillDue > 0 ? .red : (report.stillDue < 0 ? .green : .black)
            drawText("应补（退）税额：\(rmb(abs(report.stillDue)))   \(report.stillDue > 0 ? "应补缴" : report.stillDue < 0 ? "应退税" : "-")",
                     rect: CGRect(x: margin, y: y, width: contentW, height: 20),
                     fontSize: 14, bold: true, alignment: .center, color: color)
            y += 28

            // 税率分档
            if !report.rateBreakdown.isEmpty {
                drawText("按税率分档明细", rect: CGRect(x: margin, y: y, width: contentW, height: 16),
                         fontSize: 11, bold: true, alignment: .left)
                y += 18

                let rateHeader = ["税率", "进项金额", "销项金额", "净额"]
                let rateCols: [CGFloat] = [80, (contentW - 80) / 3, (contentW - 80) / 3, (contentW - 80) / 3]
                ox = margin
                for (i, h) in rateHeader.enumerated() {
                    drawCell(h, rect: CGRect(x: ox, y: y, width: rateCols[i], height: rowH), fontSize: 8, bold: true, alignment: .center)
                    ox += rateCols[i]
                }
                y += rowH

                for rb in report.rateBreakdown {
                    let rY = y
                    ox = margin
                    drawCell(rb.rateDisplay, rect: CGRect(x: ox, y: rY, width: rateCols[0], height: rowH), fontSize: 8, alignment: .center)
                    ox += rateCols[0]
                    drawCell(rmb(rb.inputAmount), rect: CGRect(x: ox, y: rY, width: rateCols[1], height: rowH), fontSize: 8, alignment: .right)
                    ox += rateCols[1]
                    drawCell(rmb(rb.outputAmount), rect: CGRect(x: ox, y: rY, width: rateCols[2], height: rowH), fontSize: 8, alignment: .right)
                    ox += rateCols[2]
                    drawCell(rmb(rb.outputAmount - rb.inputAmount), rect: CGRect(x: ox, y: rY, width: rateCols[3], height: rowH), fontSize: 8, alignment: .right)
                    y += rowH
                }
                y += 8
            }

            // 进项/销项明细（仅输出有数据的一方）
            if !report.inputDetails.isEmpty {
                y += 4
                drawText("进项发票明细", rect: CGRect(x: margin, y: y, width: contentW, height: 16),
                         fontSize: 11, bold: true)
                y += 18

                let detCols: [CGFloat] = [80, 160, contentW - 80 - 160 - 80, 80]
                let detHeaders = ["凭证号", "摘要", "税率", "税额"]
                ox = margin
                for (i, h) in detHeaders.enumerated() {
                    drawCell(h, rect: CGRect(x: ox, y: y, width: detCols[i], height: rowH), fontSize: 8, bold: true, alignment: .center)
                    ox += detCols[i]
                }
                y += rowH

                for det in report.inputDetails.prefix(20) {
                    let rY = y
                    ox = margin
                    drawCell(det.voucherNumber, rect: CGRect(x: ox, y: rY, width: detCols[0], height: rowH), fontSize: 7)
                    ox += detCols[0]
                    drawCell(det.summary, rect: CGRect(x: ox, y: rY, width: detCols[1], height: rowH), fontSize: 7)
                    ox += detCols[1]
                    drawCell(det.rateDisplay, rect: CGRect(x: ox, y: rY, width: detCols[2], height: rowH), fontSize: 7, alignment: .center)
                    ox += detCols[2]
                    drawCell(rmb(det.amount), rect: CGRect(x: ox, y: rY, width: detCols[3], height: rowH), fontSize: 7, alignment: .right)
                    y += rowH
                }
                y += 8
            }

            if !report.outputDetails.isEmpty {
                y += 4
                drawText("销项发票明细", rect: CGRect(x: margin, y: y, width: contentW, height: 16),
                         fontSize: 11, bold: true)
                y += 18

                let detCols: [CGFloat] = [80, 160, contentW - 80 - 160 - 80, 80]
                ox = margin
                for (i, h) in ["凭证号", "摘要", "税率", "税额"].enumerated() {
                    drawCell(h, rect: CGRect(x: ox, y: y, width: detCols[i], height: rowH), fontSize: 8, bold: true, alignment: .center)
                    ox += detCols[i]
                }
                y += rowH

                for det in report.outputDetails.prefix(20) {
                    let rY = y
                    ox = margin
                    drawCell(det.voucherNumber, rect: CGRect(x: ox, y: rY, width: detCols[0], height: rowH), fontSize: 7)
                    ox += detCols[0]
                    drawCell(det.summary, rect: CGRect(x: ox, y: rY, width: detCols[1], height: rowH), fontSize: 7)
                    ox += detCols[1]
                    drawCell(det.rateDisplay, rect: CGRect(x: ox, y: rY, width: detCols[2], height: rowH), fontSize: 7, alignment: .center)
                    ox += detCols[2]
                    drawCell(rmb(det.amount), rect: CGRect(x: ox, y: rY, width: detCols[3], height: rowH), fontSize: 7, alignment: .right)
                    y += rowH
                }
            }

            y += rowH
            drawLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: margin + contentW, y: y), width: 1.0)
            y += 16
            drawText("企业负责人：__________    主管会计：__________    制表人：__________",
                     rect: CGRect(x: margin, y: y, width: contentW, height: 14), fontSize: 9, alignment: .center)
        }
    }

    // MARK: - 构建列表

    private static func buildBalanceItems(_ lines: [BalanceLine]) -> [(String, String, String)] {
        var items: [(String, String, String)] = []
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


    // MARK: - CSV 中国税局标准格式导出

    /// 生成 UTF-8 BOM 带引号的 CSV
    private static func writeCSV(filename: String, headers: [String], rows: [[String]]) -> URL? {
        var csv = "\u{FEFF}"  // UTF-8 BOM for Excel
        csv += headers.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",") + "\n"
        for row in rows {
            csv += row.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",") + "\n"
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dest = downloads.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: dest)
        do {
            try csv.write(to: dest, atomically: true, encoding: String.Encoding.utf8)
            print("[CSV] 已保存: \(dest.path)")
            return dest
        } catch {
            print("[CSV] 保存失败: \(error)")
            return nil
        }
    }

    /// 导出增值税申报 CSV（中国税局标准格式）
    /// 格式: 所属期,税种,项目,金额
    static func exportVATCSV(report: VATReport) -> URL? {
        let headers = ["所属期", "税种", "项目", "金额"]
        var rows: [[String]] = []
        let period = report.period

        // 销项税额明细
        for det in report.outputDetails {
            rows.append([period, "增值税", "销项税额-\(det.rateDisplay)", FMT.amount(det.amount)])
        }
        // 进项税额明细
        for det in report.inputDetails {
            rows.append([period, "增值税", "进项税额-\(det.rateDisplay)", FMT.amount(det.amount)])
        }
        // 汇总行
        rows.append([period, "增值税", "销项税额合计", FMT.amount(report.outputTotal)])
        rows.append([period, "增值税", "进项税额合计", FMT.amount(report.inputTotal)])
        rows.append([period, "增值税", "进项税额转出", FMT.amount(report.transferOutTotal)])
        rows.append([period, "增值税", "应纳增值税", FMT.amount(report.payable)])
        rows.append([period, "增值税", "已预缴税额", FMT.amount(report.alreadyPaid)])
        rows.append([period, "增值税", "应补（退）税额", FMT.amount(abs(report.stillDue))])

        return writeCSV(filename: "增值税申报表_\(period).csv", headers: headers, rows: rows)
    }

    /// 导出试算平衡表 CSV
    @MainActor static func exportTrialBalanceCSV(companyID: UUID, year: Int, month: Int) -> URL? {
        let accounts = DataStore.shared.accounts(for: companyID).filter(\.isActive)
        let headers = ["科目编码", "科目名称", "类别", "期初借方", "期初贷方", "本期借方", "本期贷方", "期末借方", "期末贷方"]
        var rows: [[String]] = []

        for account in accounts.sorted(by: { $0.code < $1.code }) {
            let bal = AccountingEngine.balance(for: account)
            let period = AccountingEngine.periodBalance(for: account, year: year, month: month)
            let cached = AccountingEngine.cachedBalance(for: account, year: year, month: month)

            let opening = cached?.opening ?? 0
            let isDebitDir = account.effectiveBalanceDirection == .debit

            var begDebit = "", begCredit = "", endDebit = "", endCredit = ""
            if isDebitDir {
                begDebit = FMT.amount(opening)
                endDebit = bal >= 0 ? FMT.amount(bal) : ""
                endCredit = bal < 0 ? FMT.amount(abs(bal)) : ""
            } else {
                begCredit = FMT.amount(opening)
                endCredit = bal >= 0 ? FMT.amount(bal) : ""
                endDebit = bal < 0 ? FMT.amount(abs(bal)) : ""
            }

            rows.append([
                account.code, account.name, account.category.rawValue,
                begDebit, begCredit,
                FMT.amount(period.debit), FMT.amount(period.credit),
                endDebit, endCredit
            ])
        }

        return writeCSV(filename: "试算平衡表_\(year)_\(String(format: "%02d", month)).csv", headers: headers, rows: rows)
    }

    /// 导出总分类账 CSV
    @MainActor static func exportGeneralLedgerCSV(entries: [JournalEntry], accountCode: String, accountName: String,
                                        year: Int, month: Int, companyID: UUID) -> URL? {
        let headers = ["日期", "凭证号", "摘要", "借方金额", "贷方金额", "余额"]
        var rows: [[String]] = []
        var runningBalance: Decimal = 0

        // 通过余额缓存获取期初余额
        if let account = DataStore.shared.accounts(for: companyID).first(where: { $0.code == accountCode }),
           let cached = AccountingEngine.cachedBalance(for: account, year: year, month: month) {
            runningBalance = cached.opening
        }

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            for line in entry.lines {

                runningBalance = runningBalance + line.debit - line.credit
                rows.append([
                    FMT.date(entry.date), entry.number, line.summary,
                    line.debit > 0 ? FMT.amount(line.debit) : "",
                    line.credit > 0 ? FMT.amount(line.credit) : "",
                    FMT.amount(abs(runningBalance)) + (runningBalance >= 0 ? "借" : "贷")
                ])
            }
        }

        return writeCSV(filename: "总分类账_\(accountCode)_\(accountName)_\(year)_\(String(format: "%02d", month)).csv",
                        headers: headers, rows: rows)
    }

    /// 导出账龄分析 CSV
    static func exportAgingAnalysisCSV(agingData: [(name: String, buckets: [Decimal], total: Decimal)]) -> URL? {
        let headers = ["往来单位", "0-30天", "31-60天", "61-90天", "90天以上", "合计"]
        var rows: [[String]] = []

        for item in agingData {
            let buckets = item.buckets
            rows.append([
                item.name,
                buckets.count > 0 ? FMT.amount(buckets[0]) : "",
                buckets.count > 1 ? FMT.amount(buckets[1]) : "",
                buckets.count > 2 ? FMT.amount(buckets[2]) : "",
                buckets.count > 3 ? FMT.amount(buckets[3]) : "",
                FMT.amount(item.total)
            ])
        }

        return writeCSV(filename: "账龄分析表_\(FMT.date(Date())).csv", headers: headers, rows: rows)
    }

    /// 导出一条日记账分录 CSV
    @MainActor static func exportJournalEntryCSV(entry: JournalEntry, companyName: String, companyID: UUID) -> URL? {
        let _ = companyName
        let headers = ["凭证号", "日期", "摘要", "科目编码", "科目名称", "借方金额", "贷方金额", "备注"]
        var rows: [[String]] = []

        for line in entry.lines {
            // 安全获取科目信息（避免 @MainActor 跨线程问题）
            let acctCode: String = {
                guard let aid = line.accountID else { return line.accountCode }
                if !line.accountCode.isEmpty { return line.accountCode }
                return DataStore.shared.accounts(for: companyID).first(where: { $0.id == aid })?.code ?? line.accountCode
            }()
            let acctName: String = {
                guard let aid = line.accountID else { return line.accountName }
                if !line.accountName.isEmpty { return line.accountName }
                return DataStore.shared.accounts(for: companyID).first(where: { $0.id == aid })?.name ?? line.accountName
            }()
            rows.append([
                entry.number, FMT.date(entry.date), line.summary,
                acctCode, acctName,
                line.debit > 0 ? FMT.amount(line.debit) : "",
                line.credit > 0 ? FMT.amount(line.credit) : "",
                ""
            ])
        }
        // 合计行
        rows.append(["", "", "合计", "", "", FMT.amount(entry.debitTotal), FMT.amount(entry.creditTotal), ""])

        return writeCSV(filename: "凭证_\(entry.number).csv", headers: headers, rows: rows)
    }

}