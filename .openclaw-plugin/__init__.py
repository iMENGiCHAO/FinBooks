"""
FinBooks OpenClaw Plugin v2.1
============================================
通过 HTTP 调用 FinBooks Bridge (localhost:9090) 实现财务操作。
OpenClaw Agent 对话中自动注册为 tool。
"""

import json
import urllib.request
import urllib.error
from typing import Any, Optional

BRIDGE_URL = "http://127.0.0.1:9090"


def _call_bridge(endpoint: str, method: str = "GET", data: dict = None) -> dict:
    """调用 Bridge HTTP API"""
    url = f"{BRIDGE_URL}/{endpoint}"
    req = urllib.request.Request(url, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    
    if data is not None:
        req.data = json.dumps(data, ensure_ascii=False).encode()
    
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.URLError as e:
        return {"error": f"Bridge 连接失败: {e.reason}", "status": "down"}
    except Exception as e:
        return {"error": str(e)}


def _fmt_amount(val) -> str:
    if val is None:
        return "¥0.00"
    return f"¥{val:,.2f}"


def finbooks_query_balance(account_code: str) -> str:
    """查询科目余额"""
    result = _call_bridge(f"api/balance?accountCode={account_code}")
    if "error" in result:
        return f"❌ 查询失败: {result['error']}"
    return (
        f"📊 {result['code']} {result['name']}\n"
        f"   类别: {result['category']}\n"
        f"   余额: {_fmt_amount(result['balance'])}"
    )


def finbooks_list_accounts(**kwargs) -> str:
    """列出所有科目"""
    result = _call_bridge("api/accounts")
    if "error" in result:
        return f"❌ {result['error']}"
    accounts = result.get("accounts", [])
    if not accounts:
        return "暂无科目数据"
    lines = []
    for a in accounts:
        lines.append(f"  {a['code']} {a['name']} ({a['category']})")
    return f"共 {len(accounts)} 个科目:\n" + "\n".join(lines)


def finbooks_list_entries(year: int = None, month: int = None, limit: int = 50) -> str:
    """查询凭证列表"""
    params = []
    if year: params.append(f"year={year}")
    if month: params.append(f"month={month}")
    params.append(f"limit={limit}")
    result = _call_bridge(f"api/entries?{'&'.join(params)}")
    if "error" in result:
        return f"❌ {result['error']}"
    entries = result.get("entries", [])
    if not entries:
        return "暂无凭证"
    lines = [f"共 {len(entries)} 张凭证:"]
    for e in entries[:20]:
        status = "已过账" if e.get("isPosted") else "未过账"
        lines.append(
            f"  {e['number']} {e.get('date','')[:10]} "
            f"{e.get('summary','')} "
            f"借¥{e.get('debitTotal',0):,.2f} "
            f"贷¥{e.get('creditTotal',0):,.2f} "
            f"[{status}]"
        )
    return "\n".join(lines)


def finbooks_get_totals(**kwargs) -> str:
    """获取财务核心数据"""
    result = _call_bridge("api/totals")
    if "error" in result:
        return f"❌ {result['error']}"
    t = result.get("totals", {})
    return (
        f"📊 财务数据总览:\n"
        f"  总资产: {_fmt_amount(t.get('assets', 0))}\n"
        f"  总负债: {_fmt_amount(t.get('liabilities', 0))}\n"
        f"  所有者权益: {_fmt_amount(t.get('equity', 0))}\n"
        f"  收入: {_fmt_amount(t.get('revenue', 0))}\n"
        f"  费用: {_fmt_amount(t.get('expense', 0))}\n"
        f"  净利润: {_fmt_amount(t.get('netProfit', 0))}\n"
        f"  科目数: {result.get('accountCount', 0)}, 凭证数: {result.get('entryCount', 0)}"
    )


def finbooks_income_statement(year: int = None, month: int = None) -> str:
    """获取利润表"""
    params = []
    if year: params.append(f"year={year}")
    if month: params.append(f"month={month}")
    result = _call_bridge(f"api/report/income?{'&'.join(params)}")
    if "error" in result:
        return f"❌ {result['error']}"
    lines = [f"📈 利润表 ({result.get('period', '')})"]
    for rev in result.get("revenues", []):
        lines.append(f"  {rev['code']} {rev['name']}: {_fmt_amount(rev['amount'])}")
    lines.append(f"  收入合计: {_fmt_amount(result.get('totalRevenue', 0))}")
    for exp in result.get("expenses", []):
        lines.append(f"  {exp['code']} {exp['name']}: {_fmt_amount(exp['amount'])}")
    lines.append(f"  费用合计: {_fmt_amount(result.get('totalExpense', 0))}")
    lines.append(f"━━━━━━━━━━━━━━━━━")
    lines.append(f"  净利润: {_fmt_amount(result.get('netProfit', 0))}")
    return "\n".join(lines)


def finbooks_balance_sheet(**kwargs) -> str:
    """获取资产负债表"""
    result = _call_bridge("api/report/balance-sheet")
    if "error" in result:
        return f"❌ {result['error']}"
    lines = [f"📋 资产负债表 ({result.get('date', '')})"]
    for asset in result.get("assets", []):
        lines.append(f"  {asset['code']} {asset['name']}: {_fmt_amount(asset['balance'])}")
    lines.append(f"  资产合计: {_fmt_amount(result.get('totalAssets', 0))}")
    for liab in result.get("liabilities", []):
        lines.append(f"  {liab['code']} {liab['name']}: {_fmt_amount(liab['balance'])}")
    for eq in result.get("equities", []):
        lines.append(f"  {eq['code']} {eq['name']}: {_fmt_amount(eq['balance'])}")
    lines.append(f"  负债+权益合计: {_fmt_amount(result.get('totalLE', 0))}")
    return "\n".join(lines)


def finbooks_cash_flow(year: int = None, month: int = None) -> str:
    """获取现金流量表"""
    params = []
    if year: params.append(f"year={year}")
    if month: params.append(f"month={month}")
    result = _call_bridge(f"api/report/cash-flow?{'&'.join(params)}")
    if "error" in result:
        return f"❌ {result['error']}"
    lines = [f"💰 现金流量表 ({result.get('period', '')})"]
    for flow in result.get("operatingInflows", []):
        lines.append(f"  经营流入: {flow.get('name','')} {_fmt_amount(flow.get('amount',0))}")
    for flow in result.get("operatingOutflows", []):
        lines.append(f"  经营流出: {flow.get('name','')} {_fmt_amount(flow.get('amount',0))}")
    lines.append(f"  经营活动净额: {_fmt_amount(result.get('operatingNet', 0))}")
    for flow in result.get("investingInflows", []):
        lines.append(f"  投资流入: {flow.get('name','')} {_fmt_amount(flow.get('amount',0))}")
    for flow in result.get("investingOutflows", []):
        lines.append(f"  投资流出: {flow.get('name','')} {_fmt_amount(flow.get('amount',0))}")
    lines.append(f"  投资活动净额: {_fmt_amount(result.get('investingNet', 0))}")
    for flow in result.get("financingInflows", []):
        lines.append(f"  筹资流入: {flow.get('name','')} {_fmt_amount(flow.get('amount',0))}")
    for flow in result.get("financingOutflows", []):
        lines.append(f"  筹资流出: {flow.get('name','')} {_fmt_amount(flow.get('amount',0))}")
    lines.append(f"  筹资活动净额: {_fmt_amount(result.get('financingNet', 0))}")
    lines.append(f"━━━━━━━━━━━━━━━━━")
    lines.append(f"  现金净增减: {_fmt_amount(result.get('netCashFlow', 0))}")
    return "\n".join(lines)


def finbooks_vat_report(year: int = None, month: int = None) -> str:
    """获取增值税申报表"""
    params = []
    if year: params.append(f"year={year}")
    if month: params.append(f"month={month}")
    result = _call_bridge(f"api/report/vat?{'&'.join(params)}")
    if "error" in result:
        return f"❌ {result['error']}"
    return (
        f"📄 增值税申报表 ({result.get('period', '')})\n"
        f"  销项税额: {_fmt_amount(result.get('outputTax', 0))}\n"
        f"  进项税额: {_fmt_amount(result.get('inputTax', 0))}\n"
        f"  进项税额转出: {_fmt_amount(result.get('transferOut', 0))}\n"
        f"  可抵扣税额: {_fmt_amount(result.get('deductible', 0))}\n"
        f"  应纳增值税: {_fmt_amount(result.get('taxPayable', 0))}\n"
        f"  已预缴: {_fmt_amount(result.get('paidTax', 0))}\n"
        f"  应补(退)税: {_fmt_amount(result.get('stillDue', 0))}"
    )


def finbooks_general_ledger(account_code: str, year: int, month: int) -> str:
    """查询总分类账"""
    result = _call_bridge(
        f"api/report/general-ledger"
        f"?accountCode={account_code}&year={year}&month={month}"
    )
    if "error" in result:
        return f"❌ {result['error']}"
    lines = [
        f"📒 {result.get('accountCode','')} {result.get('accountName','')} 总分类账 "
        f"({year}年{month}月)"
    ]
    for l in result.get("lines", []):
        lines.append(
            f"  {l.get('date','')} {l.get('voucherNumber','')} "
            f"{l.get('summary','')} "
            f"借¥{l.get('debit',0):,.2f} 贷¥{l.get('credit',0):,.2f}"
        )
    lines.append(f"  期末余额: {_fmt_amount(result.get('closingBalance', 0))}")
    return "\n".join(lines)


def finbooks_create_entry(summary: str, lines: list, **kwargs) -> str:
    """创建记账凭证"""
    # 校验借贷平衡
    total_debit = sum(l.get("debit", 0) or 0 for l in lines)
    total_credit = sum(l.get("credit", 0) or 0 for l in lines)
    if abs(total_debit - total_credit) > 0.01:
        return (
            f"⚠️ 借贷不平衡！\n"
            f"   借方合计: ¥{total_debit:,.2f}\n"
            f"   贷方合计: ¥{total_credit:,.2f}\n"
            f"   差额: ¥{abs(total_debit - total_credit):,.2f}\n"
            f"   请调整后重新提交。"
        )
    # 自动获取公司ID
    totals = _call_bridge("api/totals")
    company_id = totals.get("companyId", "")
    if not company_id:
        accounts_resp = _call_bridge("api/accounts")
        if accounts_resp.get("accounts"):
            company_id = accounts_resp["accounts"][0].get("companyID", "")
    payload = {
        "companyId": company_id,
        "summary": summary,
        "lines": lines,
        "debitTotal": total_debit,
        "creditTotal": total_credit,
        "isPosted": True,
    }
    result = _call_bridge("api/entry/create", method="POST", data=payload)
    if "error" in result:
        return f"❌ 创建失败: {result['error']}"
    entry = result.get("entry", {})
    balanced = "✓" if entry.get("balanced") else "✗"
    return (
        f"✅ 凭证已创建!\n"
        f"  编号: {entry.get('number','')}\n"
        f"  借: ¥{entry.get('debitTotal',0):,.2f} 贷: ¥{entry.get('creditTotal',0):,.2f}\n"
        f"  平衡: {balanced}"
    )


def finbooks_create_account(code: str, name: str, category: str, **kwargs) -> str:
    """创建会计科目"""
    totals = _call_bridge("api/totals")
    company_id = totals.get("companyId", "")
    result = _call_bridge("api/account/create", method="POST", data={
        "code": code, "name": name, "category": category, "companyId": company_id
    })
    if "error" in result:
        return f"❌ 创建失败: {result['error']}"
    return f"✅ 科目创建成功! {code} {name} ({category})"


def finbooks_get_anomalies(**kwargs) -> str:
    """检测财务异常"""
    result = _call_bridge("api/anomalies")
    if "error" in result:
        return f"❌ {result['error']}"
    anomalies = result.get("anomalies", [])
    if not anomalies:
        return "✅ 未发现财务异常。"
    lines = ["⚠️ 发现以下财务异常:"]
    for a in anomalies:
        lines.append(f"  • {a.get('type','')}: {a.get('description','')}")
    return "\n".join(lines)


def finbooks_get_audit_logs(limit: int = 20, **kwargs) -> str:
    """获取审计日志"""
    result = _call_bridge(f"api/audit-logs?limit={limit}")
    if "error" in result:
        return f"❌ {result['error']}"
    logs = result.get("logs", [])
    if not logs:
        return "暂无审计日志。"
    lines = [f"📋 最近 {len(logs)} 条审计日志:"]
    for log in logs:
        lines.append(
            f"  {log.get('timestamp','')[:19]} [{log.get('action','')}] {log.get('detail','')}"
        )
    return "\n".join(lines)


def finbooks_export_csv(report_type: str, year: int = None, month: int = None, 
                         account_code: str = None, **kwargs) -> str:
    """导出财务数据为 CSV（税务/审计用）"""
    params = [f"type={report_type}"]
    if year: params.append(f"year={year}")
    if month: params.append(f"month={month}")
    if account_code: params.append(f"account_code={account_code}")
    result = _call_bridge(f"api/export/csv?{'&'.join(params)}")
    if "error" in result:
        return f"❌ 导出失败: {result['error']}"
    output_path = result.get("path", "")
    row_count = result.get("rowCount", 0)
    return (
        f"✅ CSV 导出成功!\n"
        f"  路径: {output_path}\n"
        f"  行数: {row_count}\n"
        f"  可直接导入 Excel/税务软件"
    )


# ── Tool registry (OpenClaw protocol) ──────────────────────────────


def finbooks_trial_balance(year: int = None, month: int = None) -> str:
    """获取试算平衡表 - 所有科目的期末借贷方汇总"""
    params = []
    if year: params.append(f"year={year}")
    if month: params.append(f"month={month}")
    qs = "&".join(params)
    result = _call_bridge(f"api/report/trial-balance?{qs}")
    if "error" in result:
        return f"❌ {result['error']}"
    lines = [f"⚖️ 试算平衡表 ({result.get('period', '')})"]
    for l in result.get("lines", []):
        lines.append(f"  {l['code']} {l['name']}: 借{l.get('debitBalance',0):,.2f} 贷{l.get('creditBalance',0):,.2f}")
    lines.append(f"  借方合计: ¥{result.get('totalDebit',0):,.2f}")
    lines.append(f"  贷方合计: ¥{result.get('totalCredit',0):,.2f}")
    status = "✅ 平衡" if result.get("balanced") else "❌ 不平!"
    lines.append(f"  状态: {status}")
    return "\n".join(lines)


def finbooks_aging_report(year: int = None, month: int = None) -> str:
    """获取应收/应付账龄分析报告"""
    params = []
    if year: params.append(f"year={year}")
    if month: params.append(f"month={month}")
    qs = "&".join(params)
    result = _call_bridge(f"api/report/aging?{qs}")
    if "error" in result:
        return f"❌ {result['error']}"
    lines = [f"📊 账龄分析报告 ({result.get('period', '')})"]
    lines.append(f"\n【应收账款】")
    for r in result.get("receivables", []):
        lines.append(f"  {r['code']} {r['name']}: ¥{r['total']:,.2f}")
        for bucket, amt in r.get("aging", {}).items():
            lines.append(f"    {bucket}: ¥{amt:,.2f}")
    lines.append(f"  应收合计: ¥{result.get('receivableTotal',0):,.2f}")
    lines.append(f"\n【应付账款】")
    for p in result.get("payables", []):
        lines.append(f"  {p['code']} {p['name']}: ¥{p['total']:,.2f}")
        for bucket, amt in p.get("aging", {}).items():
            lines.append(f"    {bucket}: ¥{amt:,.2f}")
    lines.append(f"  应付合计: ¥{result.get('payableTotal',0):,.2f}")
    return "\n".join(lines)



def finbooks_audit_export(year: int = None, month: int = None, format: str = "json", **kwargs) -> str:
    """导出完整审计数据包（满足外部审计需求）"""
    params = []
    if year: params.append(f"year={year}")
    if month: params.append(f"month={month}")
    params.append(f"format={format}")
    result = _call_bridge(f"api/audit/export?{'&'.join(params)}")
    if "error" in result:
        return f"❌ 审计导出失败: {result['error']}"
    output = [f"📋 审计数据包 ({result.get('period','')})"]
    output.append(f"  导出版本: {result.get('exportVersion','')}")
    output.append(f"  导出时间: {result.get('exportedAt','')[:19]}")
    trial = result.get("trialBalance", [])
    output.append(f"  试算平衡表: {len(trial)} 个科目")
    entries = result.get("entries", [])
    output.append(f"  凭证列表: {len(entries)} 张")
    logs = result.get("auditLogs", [])
    output.append(f"  审计日志: {len(logs)} 条")
    output.append(f"  是否平衡: {'✅' if result.get('balanced') else '❌'}")
    if result.get("path"):
        output.append(f"  CSV文件: {result['path']}")
    return "\n".join(output)


def finbooks_tax_export(year: int = None, month: int = None, format: str = "json", **kwargs) -> str:
    """导出增值税申报格式数据（符合中国税务申报要求）"""
    params = []
    if year: params.append(f"year={year}")
    if month: params.append(f"month={month}")
    params.append(f"format={format}")
    result = _call_bridge(f"api/tax/export?{'&'.join(params)}")
    if "error" in result:
        return f"❌ 税务导出失败: {result['error']}"
    sales = result.get("salesSummary", {})
    purchases = result.get("purchaseSummary", {})
    tax = result.get("taxComputation", {})
    return (
        f"🧾 增值税申报导出 ({result.get('period','')})\n"
        f"  应税销售额: ¥{sales.get('taxableSales',0):,.2f}\n"
        f"  销项税额: ¥{tax.get('outputTaxCurrent',0):,.2f}\n"
        f"  进项税额: ¥{tax.get('inputTaxCurrent',0):,.2f}\n"
        f"  应纳增值税: ¥{tax.get('taxPayableCurrent',0):,.2f}\n"
        f"  税率: {result.get('taxRate','13%')}\n"
        f"  是否含CSV: {'✅' if result.get('path') else '仅JSON'}"
    )


TOOLS = {
    "finbooks_query_balance": finbooks_query_balance,
    "finbooks_list_accounts": finbooks_list_accounts,
    "finbooks_list_entries": finbooks_list_entries,
    "finbooks_get_totals": finbooks_get_totals,
    "finbooks_income_statement": finbooks_income_statement,
    "finbooks_balance_sheet": finbooks_balance_sheet,
    "finbooks_cash_flow": finbooks_cash_flow,
    "finbooks_vat_report": finbooks_vat_report,
    "finbooks_general_ledger": finbooks_general_ledger,
    "finbooks_create_entry": finbooks_create_entry,
    "finbooks_create_account": finbooks_create_account,
    "finbooks_get_anomalies": finbooks_get_anomalies,
    "finbooks_get_audit_logs": finbooks_get_audit_logs,
    "finbooks_trial_balance": finbooks_trial_balance,
    "finbooks_aging_report": finbooks_aging_report,
    "finbooks_export_csv": finbooks_export_csv,
    "finbooks_audit_export": finbooks_audit_export,
    "finbooks_tax_export": finbooks_tax_export,
}


def execute_tool(name: str, params: dict) -> str:
    """Execute a tool by name with params. OpenClaw-compatible entry point."""
    func = TOOLS.get(name)
    if not func:
        return f"❌ 未知工具: {name}"
    try:
        return func(**params)
    except Exception as e:
        return f"❌ 执行失败: {e}"


def finbooks_tax_cit(year: int = None, format: str = "json", **kwargs) -> str:
    """企业所得税汇算清缴：获取年度企业所得税汇算数据，符合国家税务总局年度申报A类表要求。"""
    params = []
    if year: params.append(f"year={year}")
    params.append(f"format={format}")
    result = _call_bridge(f"api/tax/corporate-income-tax?{'&'.join(params)}")
    if "error" in result:
        return f"❌ 企业所得税导出失败: {result['error']}"
    return (
        f"🏛️ 企业所得税汇算清缴 ({result.get('fiscalYear','')})\n"
        f"  营业收入总额: ¥{result.get('totalRevenue',0):,.2f}\n"
        f"  营业成本费用: ¥{result.get('totalExpense',0):,.2f}\n"
        f"  会计利润总额: ¥{result.get('accountingProfit',0):,.2f}\n"
        f"  调整后应纳税所得额: ¥{result.get('adjustedTaxableIncome',0):,.2f}\n"
        f"  适用税率: {result.get('taxRate',0.25)*100}%\n"
        f"  应纳所得税额: ¥{result.get('estimatedTaxPayable',0):,.2f}"
    )


def finbooks_audit_working_paper(year: int = None, month: int = None, format: str = "json", limit: int = 500, **kwargs) -> str:
    """导出审计底稿（CAS审计准则）：试算平衡表+凭证抽查+银行余额调节表+审计日志。"""
    params = []
    if year: params.append(f"year={year}")
    if month: params.append(f"month={month}")
    params.append(f"format={format}")
    params.append(f"limit={limit}")
    result = _call_bridge(f"api/audit/working-paper?{'&'.join(params)}")
    if "error" in result:
        return f"❌ 审计底稿导出失败: {result['error']}"
    sections = result.get("sections", {})
    tb = sections.get("B_TrialBalance", [])
    samples = sections.get("C_EntrySampling", [])
    return (
        f"📋 审计底稿 ({result.get('auditStandard','CAS')})\n"
        f"  客户: {result.get('clientName','')}\n"
        f"  审计期间: {result.get('auditPeriod','')}\n"
        f"  试算平衡表科目: {len(tb)}个\n"
        f"  凭证抽查样本: {len(samples)}个"
    )
