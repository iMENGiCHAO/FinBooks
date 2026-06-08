#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FinBooks Demo Data Generator v2.2
===================================
生成完整的示例财务数据（含科目、凭证、公司、固定资产等）
方便用户开箱即用地体验 FinBooks 财务管理功能。

用法:
  python3 finbooks_demo_data.py           # 生成 demo 数据
  python3 finbooks_demo_data.py --clean   # 先清理再生成
  python3 finbooks_demo_data.py --append  # 追加更多凭证
"""

import json, os, sys, uuid, datetime, random, shutil

DATA_DIR = os.path.expanduser("~/Library/Application Support/com.finbooks.app")

def uid():
    return str(uuid.uuid4())

def now_iso():
    return datetime.datetime.now().isoformat()

def date_str(year, month, day):
    return datetime.datetime(year, month, day).isoformat()

def clean_data():
    """清理旧数据"""
    if os.path.exists(DATA_DIR):
        shutil.rmtree(DATA_DIR)
    os.makedirs(DATA_DIR, exist_ok=True)
    print("  ✓ 旧数据已清理")

def save(filename, data):
    path = os.path.join(DATA_DIR, filename)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, default=str)
    print(f"  ✓ {filename}: {len(data)} 条")

def generate():
    """生成完整示例数据"""
    print("\n生成 FinBooks 示例数据...\n")
    
    company_id = uid()
    now = now_iso()
    
    # ─── 公司 ────────────────────────────────────────────────────
    companies = [{
        "id": company_id,
        "name": "北京智慧科技有限公司",
        "legalName": "北京智慧科技有限公司",
        "taxId": "91110108MA7N2ABC3D",
        "address": "北京市海淀区中关村大街1号",
        "phone": "010-88886666",
        "fiscalYearStart": "01-01",
        "currency": "CNY",
        "createdAt": now,
        "updatedAt": now,
    }]
    save("companies.json", companies)
    
    # ─── 科目 ────────────────────────────────────────────────────
    accounts_data = [
        ("1001", "库存现金", "资产"),
        ("1002", "银行存款", "资产"),
        ("1122", "应收账款", "资产"),
        ("1123", "预付账款", "资产"),
        ("1221", "其他应收款", "资产"),
        ("1403", "原材料", "资产"),
        ("1405", "库存商品", "资产"),
        ("1601", "固定资产", "资产"),
        ("1602", "累计折旧", "资产"),
        ("2001", "短期借款", "负债"),
        ("2202", "应付账款", "负债"),
        ("2203", "预收账款", "负债"),
        ("2211", "应付职工薪酬", "负债"),
        ("2221", "应交税费", "负债"),
        ("2221.01", "应交增值税", "负债"),
        ("2221.01.01", "进项税额", "负债"),
        ("2221.01.02", "销项税额", "负债"),
        ("2221.01.03", "进项税额转出", "负债"),
        ("2221.01.04", "已交税金", "负债"),
        ("2241", "其他应付款", "负债"),
        ("2501", "长期借款", "负债"),
        ("4001", "实收资本", "所有者权益"),
        ("4103", "本年利润", "所有者权益"),
        ("4104", "利润分配", "所有者权益"),
        ("5001", "主营业务收入", "收入"),
        ("5051", "其他业务收入", "收入"),
        ("5111", "投资收益", "收入"),
        ("6001", "主营业务成本", "费用"),
        ("6401", "税金及附加", "费用"),
        ("6601", "销售费用", "费用"),
        ("6602", "管理费用", "费用"),
        ("6603", "财务费用", "费用"),
        ("6801", "所得税费用", "费用"),
    ]
    
    accounts = []
    for idx, (code, name, cat) in enumerate(accounts_data):
        aid = uid()
        bal_dir = ""
        if code == "1602":
            bal_dir = "credit"
        accounts.append({
            "id": aid,
            "code": code,
            "name": name,
            "category": cat,
            "parentCode": None,
            "isActive": True,
            "sortOrder": idx,
            "balanceDirection": bal_dir,
            "createdAt": now,
            "updatedAt": now,
            "companyID": company_id,
        })
    save("accounts.json", accounts)
    
    # 构建科目映射
    acct_by_code = {a["code"]: a for a in accounts}
    
    # ─── 凭证 ────────────────────────────────────────────────────
    entries = []
    entry_id_counter = [0]
    
    def make_entry(date, summary, lines):
        entry_id_counter[0] += 1
        n = entry_id_counter[0]
        eid = uid()
        entry = {
            "id": eid,
            "number": f"记-2026-{n:04d}",
            "date": date,
            "summary": summary,
            "attachmentCount": 0,
            "isPosted": True,
            "isDeleted": False,
            "companyID": company_id,
            "createdAt": now,
            "updatedAt": now,
            "lines": [],
        }
        for l in lines:
            entry["lines"].append({
                "id": uid(),
                "entryID": eid,
                "accountID": acct_by_code[l[0]]["id"],
                "accountCode": l[0],
                "accountName": acct_by_code[l[0]]["name"],
                "summary": l[3] if len(l) > 3 else summary,
                "debit": round(l[1], 2),
                "credit": round(l[2], 2),
                "vatRate": l[4] if len(l) > 4 else 0,
                "vatAmount": 0,
            })
        entries.append(entry)
    
    # 1. 实收资本（期初）
    make_entry("2026-01-01T08:00:00",
        "收到股东投资款",
        [("1002", 500000.00, 0, "收到投资款", 0), ("4001", 0, 500000.00, "实收资本", 0)])
    
    # 2. 购买原材料
    make_entry("2026-01-05T09:00:00",
        "采购原材料一批",
        [("1403", 80000.00, 0, "原材料采购", 0), ("2221.01.01", 10400.00, 0, "进项税额", 0.13), ("1002", 0, 90400.00, "银行存款支付", 0)])
    
    # 3. 购买固定资产
    make_entry("2026-01-08T10:00:00",
        "购入办公设备",
        [("1601", 60000.00, 0, "办公设备", 0), ("2221.01.01", 7800.00, 0, "进项税额", 0.13), ("1002", 0, 67800.00, "银行存款支付", 0)])
    
    # 4. 销售商品
    make_entry("2026-01-10T14:00:00",
        "销售商品一批",
        [("1002", 150000.00, 0, "收到货款", 0), ("5001", 0, 132743.36, "销售收入", 0), ("2221.01.02", 0, 17256.64, "销项税额", 0.13)])
    
    # 5. 结转成本
    make_entry("2026-01-10T14:30:00",
        "结转销售成本",
        [("6001", 50000.00, 0, "商品成本", 0), ("1405", 0, 50000.00, "库存商品减少", 0)])
    
    # 6. 支付工资
    make_entry("2026-01-15T09:00:00",
        "发放1月员工工资",
        [("2211", 0, 45000.00, "应付职工薪酬", 0), ("1002", 45000.00, 0, "工资发放", 0)])
    
    # 7. 计提工资
    make_entry("2026-01-15T09:00:00",
        "计提1月管理费用工资",
        [("6602", 30000.00, 0, "管理人员工资", 0), ("6601", 15000.00, 0, "销售人员工资", 0), ("2211", 0, 45000.00, "应付职工薪酬", 0)])
    
    # 8. 支付房租
    make_entry("2026-01-20T10:00:00",
        "支付1-3月办公室租金",
        [("6602", 30000.00, 0, "房租费用", 0), ("1002", 0, 30000.00, "银行支付", 0)])
    
    # 9. 支付水电费
    make_entry("2026-01-22T11:00:00",
        "支付1月水电费",
        [("6602", 5000.00, 0, "水电费", 0), ("1002", 0, 5000.00, "银行支付", 0)])
    
    # 10. 差旅报销
    make_entry("2026-01-25T14:00:00",
        "报销差旅费",
        [("6602", 8000.00, 0, "差旅费", 0), ("1001", 0, 8000.00, "现金支付", 0)])
    
    # 11. 2月工资
    make_entry("2026-02-15T09:00:00",
        "发放2月员工工资",
        [("2211", 0, 45000.00, "应付职工薪酬", 0), ("1002", 45000.00, 0, "工资发放", 0)])
    
    make_entry("2026-02-15T09:00:00",
        "计提2月工资",
        [("6602", 30000.00, 0, "管理人员工资", 0), ("6601", 15000.00, 0, "销售人员工资", 0), ("2211", 0, 45000.00, "应付职工薪酬", 0)])
    
    # 12. 2月销售
    make_entry("2026-02-20T14:00:00",
        "销售商品一批（2月）",
        [("1002", 200000.00, 0, "收到货款", 0), ("5001", 0, 176991.15, "销售收入", 0), ("2221.01.02", 0, 23008.85, "销项税额", 0.13)])
    
    make_entry("2026-02-20T14:30:00",
        "结转2月销售成本",
        [("6001", 70000.00, 0, "商品成本", 0), ("1405", 0, 70000.00, "库存商品减少", 0)])
    
    # 13. 支付房租
    make_entry("2026-02-25T10:00:00",
        "支付2月办公费用",
        [("6602", 8000.00, 0, "办公费", 0), ("1002", 0, 8000.00, "银行支付", 0)])
    
    # 14. 3月销售
    make_entry("2026-03-10T14:00:00",
        "销售商品一批（3月）",
        [("1002", 180000.00, 0, "收到货款", 0), ("5001", 0, 159292.04, "销售收入", 0), ("2221.01.02", 0, 20707.96, "销项税额", 0.13)])
    
    make_entry("2026-03-10T14:30:00",
        "结转3月销售成本",
        [("6001", 60000.00, 0, "商品成本", 0), ("1405", 0, 60000.00, "库存商品减少", 0)])
    
    # 15. 支付增值税
    make_entry("2026-03-15T10:00:00",
        "缴纳1月增值税",
        [("2221.01.04", 17256.64, 0, "已交税金", 0), ("1002", 0, 17256.64, "银行支付", 0)])
    
    # 16. 3月工资
    make_entry("2026-03-15T09:00:00",
        "发放3月员工工资",
        [("2211", 0, 48000.00, "应付职工薪酬", 0), ("1002", 48000.00, 0, "工资发放", 0)])
    
    make_entry("2026-03-15T09:00:00",
        "计提3月工资",
        [("6602", 32000.00, 0, "管理人员工资", 0), ("6601", 16000.00, 0, "销售人员工资", 0), ("2211", 0, 48000.00, "应付职工薪酬", 0)])
    
    # 17. 支付租金
    make_entry("2026-03-20T10:00:00",
        "支付4-6月办公室租金",
        [("1123", 36000.00, 0, "预付房租", 0), ("1002", 0, 36000.00, "银行支付", 0)])
    
    # 18. 设备折旧
    # 固定资产60,000，残值5%，使用5年=60月，月折旧=60000*0.95/60=950
    make_entry("2026-03-31T23:59:00",
        "计提1-3月设备折旧",
        [("6602", 2850.00, 0, "1-3月折旧费用", 0), ("1602", 0, 2850.00, "累计折旧(950*3)", 0)])
    
    # 19. 银行利息
    make_entry("2026-03-31T23:59:00",
        "银行季度结息",
        [("1002", 1500.00, 0, "利息收入", 0), ("6603", 0, 1500.00, "利息收入(负费用)", 0)])
    
    # 20. 4月业务
    make_entry("2026-04-05T09:00:00",
        "采购原材料（4月）",
        [("1403", 100000.00, 0, "原材料", 0), ("2221.01.01", 13000.00, 0, "进项税额", 0.13), ("2202", 0, 113000.00, "应付账款", 0)])
    
    make_entry("2026-04-10T14:00:00",
        "销售商品（4月）",
        [("1002", 220000.00, 0, "收到货款", 0), ("5001", 0, 194690.27, "销售收入", 0), ("2221.01.02", 0, 25309.73, "销项税额", 0.13)])
    
    make_entry("2026-04-10T14:30:00",
        "结转4月销售成本",
        [("6001", 75000.00, 0, "商品成本", 0), ("1405", 0, 75000.00, "库存商品减少", 0)])
    
    # 预收账款
    make_entry("2026-04-15T10:00:00",
        "收到客户预付款",
        [("1002", 50000.00, 0, "预收款项", 0), ("2203", 0, 50000.00, "预收账款", 0)])
    
    make_entry("2026-04-15T09:00:00",
        "发放4月员工工资",
        [("2211", 0, 48000.00, "应付工资", 0), ("1002", 48000.00, 0, "工资发放", 0)])
    
    make_entry("2026-04-15T09:00:00",
        "计提4月工资",
        [("6602", 32000.00, 0, "管理工资", 0), ("6601", 16000.00, 0, "销售工资", 0), ("2211", 0, 48000.00, "应付工资", 0)])
    
    # 21. 支付应付账款
    make_entry("2026-04-25T10:00:00",
        "支付前期货款",
        [("2202", 113000.00, 0, "偿还货款", 0), ("1002", 0, 113000.00, "银行支付", 0)])
    
    save("entries.json", entries)
    print(f"  ✓ 生成了 {len(entries)} 张会计凭证")
    
    # ─── 银行账户 ────────────────────────────────────────────────
    bank_accounts = [
        {
            "id": uid(), "companyID": company_id, "accountName": "基本户-工商银行",
            "accountNumber": "1102021319000666888", "bankName": "中国工商银行北京中关村支行",
            "currency": "CNY", "openingBalance": 500000.00, "currentBalance": 0.0,
            "isActive": True, "createdAt": now, "updatedAt": now,
        },
        {
            "id": uid(), "companyID": company_id, "accountName": "现金日记账",
            "accountNumber": "CASH-001", "bankName": "库存现金",
            "currency": "CNY", "openingBalance": 10000.00, "currentBalance": 0.0,
            "isActive": True, "createdAt": now, "updatedAt": now,
        },
    ]
    save("bankAccounts.json", bank_accounts)
    
    # ─── 固定资产 ────────────────────────────────────────────────
    assets = [
        {
            "id": uid(), "companyID": company_id, "code": "ZC-2026-001",
            "name": "联想 ThinkPad X1 Carbon",
            "category": "电子设备",
            "originalValue": 15000.0, "residualValue": 750.0,
            "usefulLife": 60, "depreciationMethod": "straightLine",
            "startDepreciationDate": "2026-01-08T00:00:00",
            "status": "active", "location": "财务部",
            "depreciationAccountID": acct_by_code["1602"]["id"],
            "expenseAccountID": acct_by_code["6602"]["id"],
            "accumulatedDepreciation": 0.0,
            "purchaseDate": "2026-01-08T00:00:00", "vendor": "京东",
            "createdAt": now, "updatedAt": now,
        },
        {
            "id": uid(), "companyID": company_id, "code": "ZC-2026-002",
            "name": "HP LaserJet Pro 打印机",
            "category": "办公设备",
            "originalValue": 5000.0, "residualValue": 250.0,
            "usefulLife": 60, "depreciationMethod": "straightLine",
            "startDepreciationDate": "2026-01-08T00:00:00",
            "status": "active", "location": "行政部",
            "depreciationAccountID": acct_by_code["1602"]["id"],
            "expenseAccountID": acct_by_code["6602"]["id"],
            "accumulatedDepreciation": 0.0,
            "purchaseDate": "2026-01-08T00:00:00", "vendor": "京东",
            "createdAt": now, "updatedAt": now,
        },
    ]
    save("fixedAssets.json", assets)
    
    # ─── 审计日志 ────────────────────────────────────────────────
    logs = []
    actions = [
        ("公司创建", "创建公司：北京智慧科技有限公司"),
        ("创建科目", "初始化默认科目表（33个科目）"),
        ("创建凭证", "记-2026-0001 收到股东投资款"),
        ("创建凭证", "记-2026-0002 采购原材料一批"),
        ("创建凭证", "记-2026-0003 购入办公设备"),
        ("创建凭证", "记-2026-0004 销售商品一批"),
        ("过账", "批量过账凭证 0001-0010"),
        ("创建凭证", "记-2026-0011 发放2月工资"),
        ("创建凭证", "记-2026-0017 支付房租"),
        ("创建凭证", "记-2026-0020 采购原材料"),
    ]
    for action, detail in actions:
        logs.append({
            "id": uid(),
            "timestamp": now,
            "action": action,
            "detail": detail,
            "companyID": company_id,
            "ip": "127.0.0.1",
        })
    save("auditLogs.json", logs)
    
    # ─── 期间结账 ────────────────────────────────────────────────
    period_closes = []
    for m in range(1, 4):
        period_closes.append({
            "id": uid(),
            "companyID": company_id,
            "year": 2026,
            "month": m,
            "isClosed": False,
            "closedAt": None,
            "closedBy": "",
            "createdAt": now,
        })
    save("periodCloses.json", period_closes)
    
    # ─── 银行流水 ────────────────────────────────────────────────
    bank_transactions = [
        {"id": uid(), "bankAccountID": bank_accounts[0]["id"], "date": "2026-01-01T08:00:00",
         "description": "期初余额", "amount": 500000.00, "type": "deposit",
         "status": "cleared", "reference": "OPENING", "createdAt": now, "updatedAt": now},
    ]
    save("bankTransactions.json", bank_transactions)
    
    print(f"\n{'='*50}")
    print("✅ 示例数据生成完成！")
    print(f"{'='*50}")
    print(f"")
    print(f"  公司: 北京智慧科技有限公司")
    print(f"  税号: 91110108MA7N2ABC3D")
    print(f"  科目: {len(accounts)} 个")
    print(f"  凭证: {len(entries)} 张")
    print(f"  固定资产: {len(assets)} 项")
    print(f"  银行账户: {len(bank_accounts)} 个")
    print(f"")
    print(f"  数据目录: {DATA_DIR}")
    print(f"")
    print(f"  提示: 启动 Bridge 后即可用 AI 助手查询")
    print(f"  python3 finbooks_bridge.py")

if __name__ == "__main__":
    if "--clean" in sys.argv:
        clean_data()
    generate()
    if "--append" in sys.argv:
        print("\n追加模式: 如需更多数据请修改此脚本中的凭证生成逻辑")
