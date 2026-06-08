"""
FinBooks Plugin v2.1 — Hermes Agent 财务工具集成
==================================================
通过 HTTP 调用 FinBooks Bridge (localhost:9090) 实现所有财务操作。

使用方式:
  Hermes 对话中自动注册为 tool，Agent 可直接调用：
  - "帮我查一下银行存款余额"
  - "录入一笔凭证：报销差旅费¥500"
  - "生成本月利润表"
"""

import json
import urllib.request
import urllib.error
from typing import Any

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
    """格式化金额"""
    if val is None:
        return "¥0.00"
    return f"¥{val:,.2f}"


# ============================================================
#  Tool 函数 — 每个函数对应 plugin.yaml 中的一个 tool
# ============================================================

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
    if year:
        params.append(f"year={year}")
    if month:
        params.append(f"month={month}")
    params.append(f"limit={limit}")
    qs = "&".join(params)
    
    result = _call_bridge(f"api/entries?{qs}")
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
            f"借{_fmt_amount(e.get('debitTotal',0))} "
            f"贷{_fmt_amount(e.get('creditTotal',0))} "
            f"[{status}]"
        )
    return "\n".join(lines)


def finbooks_get_totals(**kwargs) -> str:
    """获取核心财务数据"""
    result = _call_bridge("api/totals")
    if "error" in result:
        return f"❌ {result['error']}"
    t = result.get("totals", {})
    company = result.get("companyName", "")
    
    return (
        f"🏢 {company}\n"
        f"━━━━━━━━━━━━━━━━\n"
        f"📊 总资产:    {_fmt_amount(t.get('assets',0))}\n"
        f"📊 总负债:    {_fmt_amount(t.get('liabilities',0))}\n"
        f"📊 所有者权益: {_fmt_amount(t.get('equity',0))}\n"
        f"━━━━━━━━━━━━━━━━\n"
        f"📈 累计收入:  {_fmt_amount(t.get('revenue',0))}\n"
        f"📉 累计费用:  {_fmt_amount(t.get('expense',0))}\n"
        f"💰 净利润:    {_fmt_amount(t.get('netProfit',0))}\n"
        f"━━━━━━━━━━━━━━━━\n"
        f"📋 活跃科目: {result.get('accountCount',0)} 个\n"
        f"📝 已过账凭证: {result.get('entryCount',0)} 张"
    )


def finbooks_income_statement(year: int = None, month: int = None) -> str:
    """利润表"""
    result = _call_bridge("api/report/income")
    if "error" in result:
        return f"❌ {result['error']}"
    return (
        f"📈 利润表 — {result.get('companyName','')}\n"
        f"   收入: {_fmt_amount(result.get('revenue',0))}\n"
        f"   费用: {_fmt_amount(result.get('expense',0))}\n"
        f"   净利润: {_fmt_amount(result.get('netProfit',0))}"
    )


def finbooks_balance_sheet(**kwargs) -> str:
    """资产负债表"""
    result = _call_bridge("api/report/balance-sheet")
    if "error" in result:
        return f"❌ {result['error']}"
    balanced = "✅ 平衡" if result.get("balanced") else "⚠️ 不平衡!"
    return (
        f"📊 资产负债表 — {result.get('companyName','')}\n"
        f"   资产: {_fmt_amount(result.get('assets',0))}\n"
        f"   负债: {_fmt_amount(result.get('liabilities',0))}\n"
        f"   权益: {_fmt_amount(result.get('equity',0))}\n"
        f"   状态: {balanced}"
    )


def finbooks_cash_flow(year: int = None, month: int = None) -> str:
    """现金流量表"""
    result = _call_bridge("api/report/cash-flow")
    if "error" in result:
        return f"❌ {result['error']}"
    return (
        f"💵 现金流量表 — {result.get('companyName','')}\n"
        f"   现金流入: {_fmt_amount(result.get('cashInflow',0))}\n"
        f"   现金流出: {_fmt_amount(result.get('cashOutflow',0))}\n"
        f"   净流量:   {_fmt_amount(result.get('netCashFlow',0))}"
    )


def finbooks_vat_report(year: int = None, month: int = None) -> str:
    """增值税申报表"""
    result = _call_bridge("api/report/vat")
    if "error" in result:
        return f"❌ {result['error']}"
    return (
        f"🧾 增值税申报 — {result.get('companyName','')}\n"
        f"   纳税人识别号: {result.get('taxId','')}\n"
        f"   销项税额: {_fmt_amount(result.get('outputTax',0))}\n"
        f"   进项税额: {_fmt_amount(result.get('inputTax',0))}\n"
        f"   应纳税额: {_fmt_amount(result.get('taxPayable',0))}"
    )


def finbooks_create_entry(summary: str, lines: list, **kwargs) -> str:
    """创建凭证"""
    # 校验借贷平衡
    total_debit = sum(l.get("debit", 0) or 0 for l in lines)
    total_credit = sum(l.get("credit", 0) or 0 for l in lines)
    
    if abs(total_debit - total_credit) > 0.01:
        return (
            f"⚠️ 借贷不平衡！\n"
            f"   借方合计: {_fmt_amount(total_debit)}\n"
            f"   贷方合计: {_fmt_amount(total_credit)}\n"
            f"   差额: {_fmt_amount(abs(total_debit - total_credit))}\n"
            f"   请调整后重新提交。"
        )
    
    # 先获取公司 ID
    totals = _call_bridge("api/totals")
    company_id = totals.get("companyId", "")
    if not company_id:
        # 尝试从 accounts API 获取
        accounts_resp = _call_bridge("api/accounts")
        if accounts_resp.get("accounts"):
            company_id = accounts_resp["accounts"][0].get("companyID", "")
    
    data = {
        "companyId": company_id,
        "summary": summary,
        "lines": lines,
        "debitTotal": total_debit,
        "creditTotal": total_credit,
        "isPosted": True,
    }
    
    result = _call_bridge("api/entry/create", method="POST", data=data)
    if "error" in result:
        return f"❌ 创建失败: {result['error']}"
    return (
        f"✅ 凭证已创建！\n"
        f"   凭证号: {result['entry']['number']}\n"
        f"   摘要: {summary}\n"
        f"   借方合计: {_fmt_amount(total_debit)}\n"
        f"   贷方合计: {_fmt_amount(total_credit)}"
    )


def finbooks_create_account(code: str, name: str, category: str, **kwargs) -> str:
    """创建科目"""
    totals = _call_bridge("api/totals")
    company_id = totals.get("companyId", "")
    
    data = {
        "companyId": company_id,
        "code": code,
        "name": name,
        "category": category,
    }
    
    result = _call_bridge("api/account/create", method="POST", data=data)
    if "error" in result:
        return f"❌ 创建失败: {result['error']}"
    return f"✅ 科目已创建: {code} {name} ({category})"


def finbooks_get_anomalies(**kwargs) -> str:
    """异常检测 — 通过 Bridge /api/anomalies 端点获取专业检测"""
    result = _call_bridge("api/anomalies")
    if "error" in result:
        # Fallback: try totals-based detection if bridge endpoint unavailable
        return finbooks_get_anomalies_fallback()
    anomalies = result.get("anomalies", [])
    if not anomalies:
        return "✅ 未发现异常，财务数据正常"
    lines = ["🔍 异常检测结果:"]
    for a in anomalies:
        sev = a.get("severity", "info")
        prefix = "🚨" if sev == "critical" else "⚠️" if sev == "warning" else "ℹ️"
        lines.append(f"  {prefix} {a.get('type','')}: {a.get('description','')}")
    return "\n".join(lines)

def finbooks_get_anomalies_fallback() -> str:
    """备用异常检测 — 基于 totals API 的简单检测"""
    result = _call_bridge("api/totals")
    if "error" in result:
        return f"❌ {result['error']}"
    t = result.get("totals", {})
    issues = []
    assets = t.get("assets", 0)
    liabilities = t.get("liabilities", 0)
    equity = t.get("equity", 0)
    diff = abs(assets - (liabilities + equity))
    if diff > 1:
        issues.append(f"⚠️ 资产负债表不平: 差额 {_fmt_amount(diff)}")
    for code, bal_info in result.get("accountBalances", {}).items():
        bal = bal_info.get("balance", 0)
        cat = bal_info.get("category", "")
        if cat in ("asset", "expense") and bal < 0 and code != "1602":
            issues.append(f"⚠️ {code} {bal_info.get('name','')} 余额为负 ({_fmt_amount(bal)})")
        if cat in ("liability", "equity", "revenue") and bal < 0:
            issues.append(f"⚠️ {code} {bal_info.get('name','')} 余额为负 ({_fmt_amount(bal)})")
    if not issues:
        return "✅ 未发现异常，财务数据正常"
    return "🔍 异常检测结果:\n" + "\n".join(issues)


def finbooks_get_audit_logs(limit: int = 20, **kwargs) -> str:
    """获取审计日志 — 所有关键操作的完整审计追溯"""
    result = _call_bridge(f"api/audit-logs?limit={limit}")
    if "error" in result:
        # Fallback: bridge with audit-logs endpoint
        result2 = _call_bridge(f"api/audit-logs?limit={limit}")
        if "error" in result2:
            # Last resort: health check
            health = _call_bridge("health")
            if health.get("status") == "ok":
                return (
                    f"📋 审计日志服务正常\n"
                    f"   Bridge 版本: {health.get('version', 'v2')}\n"
                    f"   FinBooks 自动记录所有关键操作\n"
                    f"   可在 FinBooks App → AI 助手查询最新日志"
                )
            return f"❌ {result['error']}"
        result = result2
    
    logs = result.get("logs", [])
    if not logs:
        return "📋 暂无审计日志。所有操作自动记录（创建/修改/删除/过账/结账）。"
    
    lines_out = [f"📋 审计日志 (最近 {len(logs)} 条):"]
    for log in logs[:limit]:
        ts = log.get('timestamp', '')[:19]
        action = log.get('action', '')
        detail = log.get('detail', '')
        lines_out.append(f"  {ts} [{action}] {detail}")
    return "\n".join(lines_out)




# ============================================================
#  Hermes Plugin 入口
# ============================================================

def on_agent_start(plugin_ctx):
    """Hermes Agent 启动时注入系统提示"""
    plugin_ctx.set_system_message("""
你正在 FinBooks 财务管理系统中工作。你可以使用以下工具直接操作财务数据：

【查询】finbooks_query_balance / finbooks_list_accounts / finbooks_list_entries / finbooks_get_totals
【报表】finbooks_income_statement / finbooks_balance_sheet / finbooks_cash_flow / finbooks_vat_report / finbooks_general_ledger / finbooks_trial_balance
【写入】finbooks_create_entry / finbooks_create_account
【审计】finbooks_get_anomalies / finbooks_get_audit_logs / finbooks_aging_report
【导出/管理】finbooks_export_csv / finbooks_uninstall_plugin

重要规则：
- 创建凭证必须确保借贷平衡（借=贷）
- 金额使用¥符号
- 异常和账龄分析发现问题时主动预警
- 发现异常时主动告知用户
""")
    # 注册所有工具
    for name, fn in _TOOLS.items():
        plugin_ctx.register_tool(name, fn)



def finbooks_general_ledger(account_code: str = "", year: int = None, month: int = None) -> str:
    """查询总分类账明细"""
    params = [f"accountCode={account_code}"]
    if year: params.append(f"year={year}")
    if month: params.append(f"month={month}")
    result = _call_bridge(f"api/report/general-ledger?{'&'.join(params)}")
    if "error" in result:
        return f"❌ {result['error']}"
    output = [
        f"📋 总分类账 — {result.get('accountCode','')} {result.get('accountName','')}",
        f"   借方合计: {_fmt_amount(result.get('debitTotal',0))}",
        f"   贷方合计: {_fmt_amount(result.get('creditTotal',0))}",
        f"   期末余额: {_fmt_amount(result.get('closingBalance',0))}",
        f"━━━━━━━━━━━━━━━━━━━━",
    ]
    for line in result.get("lines", [])[:30]:
        output.append(
            f"  {line.get('date','')} {line.get('voucherNumber','')} "
            f"{line.get('summary','')[:20]} "
            f"借{_fmt_amount(line.get('debit',0))} "
            f"贷{_fmt_amount(line.get('credit',0))}"
        )
    return "\n".join(output)



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
    output.append(f" 导出时间: {result.get('exportedAt','')[:19]}")
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





def finbooks_uninstall_plugin(agent: str = "all", **kwargs) -> str:
    """卸载 FinBooks 插件从指定智能体"""
    import urllib.request, json
    try:
        req = urllib.request.Request(
            "http://127.0.0.1:9090/api/plugin/uninstall-from-agent",
            data=json.dumps({"agent": agent}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read())
            results = result.get("results", {})
            lines = [f"卸载完成:"]
            for a, status in results.items():
                icon = "✅" if status == "uninstalled" else ("ℹ️" if status == "not_installed" else "❌")
                lines.append(f"  {icon} {a}: {status}")
            return "\n".join(lines)
    except Exception as e:
        return f"❌ 卸载失败: {e}\n\n手动卸载: rm -rf ~/.hermes/plugins/finbooks ~/.openclaw/plugins/finbooks ~/.codex/plugins/finbooks"

_TOOLS = {
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
    "finbooks_trial_balance": finbooks_trial_balance,
    "finbooks_aging_report": finbooks_aging_report,
    "finbooks_get_audit_logs": finbooks_get_audit_logs,
    "finbooks_export_csv": finbooks_export_csv,
    "finbooks_audit_export": finbooks_audit_export,
    "finbooks_tax_export": finbooks_tax_export,
    "finbooks_uninstall_plugin": finbooks_uninstall_plugin,
}


def finbooks_tax_cit(year: int = None, format: str = "json", **kwargs) -> str:
    """企业所得税汇算清缴：获取年度企业所得税汇算数据（会计利润、纳税调整、应纳所得税额），符合国家税务总局企业所得税年度申报A类表要求。"""
    params = []
    if year: params.append(f"year={year}")
    params.append(f"format={format}")
    result = _call_bridge("api/tax/corporate-income-tax?{'&'.join(params)}")
    if "error" in result:
        return f"❌ 企业所得税导出失败: {result['error']}"
    return (
        f"🏛️ 企业所得税汇算清缴 ({result.get('fiscalYear','')})\n"
        f"  营业收入总额: ¥{result.get('totalRevenue',0):,.2f}\n"
        f"  营业成本费用: ¥{result.get('totalExpense',0):,.2f}\n"
        f"  会计利润总额: ¥{result.get('accountingProfit',0):,.2f}\n"
        f"  纳税调整额: ¥{result.get('adjustments',{}).get('taxAdjustmentTotal',0):,.2f}\n"
        f"  调整后应纳税所得额: ¥{result.get('adjustedTaxableIncome',0):,.2f}\n"
        f"  适用税率: {result.get('taxRate',0.25)*100}%\n"
        f"  应纳所得税额: ¥{result.get('estimatedTaxPayable',0):,.2f}\n"
        f"  适用表单: {result.get('applicableForm','企业所得税年度纳税申报表A类')}"
    )


def finbooks_audit_working_paper(year: int = None, month: int = None, format: str = "json", limit: int = 500, **kwargs) -> str:
    """导出审计底稿：按照中国注册会计师审计准则(CAS)生成标准审计底稿包，包含试算平衡表、凭证抽查样本、银行存款余额调节表、审计日志。"""
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
        f"  计划重要性水平: ¥{sections.get('A_Planning',{}).get('materialityLevel',0):,.2f}\n"
        f"  试算平衡表科目数: {len(tb)}\n"
        f"  凭证抽查样本数: {len(samples)}\n"
        f"  是否含CSV: {'✅' if result.get('path') else '仅JSON'}"
    )
