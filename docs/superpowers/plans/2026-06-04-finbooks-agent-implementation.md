# FinBooks AI Agent 对接层 — 实施计划

> **REQUIRED SUB-SKILL:** Use subagent-driven-development or executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 创建一个 Hermes Agent skill（finbooks-agent），让 AI 智能体能读写 FinBooks 的 JSON 数据文件，实现财务操作。

**架构:** Hermes Agent skill 文件（SKILL.md）+ 配套 Python 工具库（finbooks_tools.py）。SKILL.md 定义完整的交互流程和规则，Python 工具库封装 JSON 读写、校验、分析逻辑。Agent 通过 execute_code 调用工具库完成操作。

**Tech Stack:** Python 3 (json, datetime, copy, pathlib), Hermes Agent SKILL.md, JSON 文件系统

**数据路径:** `~/Library/Application Support/com.finbooks.app/`
- companies.json, accounts.json, entries.json, periodCloses.json

**参考代码:** FinBooks 的 Models.swift 中的 DataStore、AccountingEngine 逻辑需要完全复刻到 Python 端

---

### Task 1: 创建 finbooks_tools.py — 核心数据层

**Files:**
- Create: `/Users/zhouchao/.hermes/skills/finbooks-agent/finbooks_tools.py`

**JSON 路径常量:** `~/Library/Application Support/com.finbooks.app/`

**核心函数:**

- [ ] **Step 1: 数据路径与通用 JSON 读写**

```python
import json, datetime, shutil, copy, os, uuid
from decimal import Decimal
from pathlib import Path

FINBOOKS_DIR = Path.home() / "Library/Application Support/com.finbooks.app"

def _read_json(filename) -> list:
    path = FINBOOKS_DIR / filename
    if not path.exists(): return []
    with open(path, 'r') as f: return json.load(f)

def _write_json(filename, data):
    path = FINBOOKS_DIR / filename
    backup(path)  # 自动备份
    with open(path, 'w') as f:
        json.dump(data, f, ensure_ascii=False, indent=2, default=str)

def backup(path):
    ts = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
    bak = path.with_name(f"{path.name}.bak.{ts}")
    shutil.copy2(path, bak)
```

- [ ] **Step 2: 解析 Swift Date (TimeInterval since reference date)**

FinBooks 的 Date 存的是 `timeIntervalSinceReferenceDate`（2001-01-01 00:00:00 UTC 起的秒数）。需要转换函数。

```python
_REFERENCE_DATE = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)

def _parse_swift_date(ts: float) -> datetime.datetime:
    return _REFERENCE_DATE + datetime.timedelta(seconds=ts)

def _to_swift_date(d: datetime.datetime) -> float:
    return (d - _REFERENCE_DATE).total_seconds()
```

- [ ] **Step 3: 公司查询函数**

```python
def list_companies() -> list[dict]:
    return _read_json("companies.json")

def get_company(name_or_id: str) -> dict|None:
    companies = _read_json("companies.json")
    for c in companies:
        if c["name"] == name_or_id or c["id"] == name_or_id:
            return c
    return None
```

- [ ] **Step 4: 科目查询**

```python
def get_accounts(company_id: str = None) -> list[dict]:
    accounts = _read_json("accounts.json")
    if company_id:
        accounts = [a for a in accounts if a.get("companyID") == company_id]
    return accounts

def find_account(accounts: list, code_or_name: str) -> dict|None:
    for a in accounts:
        if a["code"] == code_or_name or a["name"] == code_or_name:
            return a
    return None

def get_accounts_by_category(accounts: list):
    result = {}
    for a in accounts:
        cat = a.get("category", "其他")
        if cat not in result: result[cat] = []
        result[cat].append(a)
    return result
```

- [ ] **Step 5: 凭证编号生成（复用空缺编号）**

```python
def next_voucher_number(company_id: str) -> str:
    year = datetime.datetime.now().year
    prefix = f"记-{year}-"
    entries = _read_json("entries.json")
    company_entries = [e for e in entries if e.get("companyID") == company_id]
    used = []
    for e in company_entries:
        if e.get("number", "").startswith(prefix):
            try: used.append(int(e["number"][len(prefix):]))
            except: pass
    used.sort()
    candidate = 1
    for u in used:
        if candidate < u: break
        candidate = u + 1
    return f"{prefix}{candidate:04d}"
```

- [ ] **Step 6: 结账状态检查**

```python
def check_period_closed(company_id: str, year: int, month: int) -> bool:
    closes = _read_json("periodCloses.json")
    for c in closes:
        if (c.get("companyID") == company_id and 
            c.get("year") == year and 
            c.get("month") == month and 
            c.get("isClosed", False)):
            return True
    return False
```

- [ ] **Step 7: 借贷平衡校验**

```python
def validate_balance(lines: list[dict]) -> tuple[bool, Decimal, Decimal]:
    total_debit = sum(Decimal(str(l.get("debit", 0))) for l in lines)
    total_credit = sum(Decimal(str(l.get("credit", 0))) for l in lines)
    return total_debit == total_credit, total_debit, total_credit
```

- [ ] **Step 8: 创建凭证（完整流程）**

```python
def create_voucher(company_name: str, date_str: str, summary: str, lines: list[dict]) -> dict:
    """
    lines: [{accountCode, accountName, debit, credit, lineSummary}]
    
    返回: {"success": bool, "entry": dict|None, "error": str|None}
    """
    # 1. 找公司
    company = get_company(company_name)
    if not company: return {"success": False, "error": f"公司 '{company_name}' 不存在"}
    
    # 2. 解析日期
    try:
        dt = datetime.datetime.strptime(date_str, "%Y-%m-%d")
        date_ts = _to_swift_date(dt)
    except:
        return {"success": False, "error": "日期格式错误，请使用 YYYY-MM-DD"}
    
    # 3. 校验借贷平衡
    balanced, total_d, total_c = validate_balance(lines)
    if not balanced:
        diff = abs(total_d - total_c)
        return {"success": False, "error": f"借贷不平！借方={total_d} 贷方={total_c} 差额={diff}"}
    
    # 4. 校验科目存在
    accounts = get_accounts(company["id"])
    for l in lines:
        ac = find_account(accounts, l.get("accountCode", ""))
        if not ac:
            ac = find_account(accounts, l.get("accountName", ""))
        if not ac:
            return {"success": False, "error": f"科目 '{l.get('accountCode', l.get('accountName', ''))}' 不存在"}
        l["accountID"] = ac["id"]
        l["accountName"] = ac["name"]
        l["accountCode"] = ac["code"]
    
    # 5. 检查结账
    year, month = dt.year, dt.month
    if check_period_closed(company["id"], year, month):
        return {"success": False, "error": f"{year}年{month}月已结账，无法新增凭证"}
    
    # 6. 生成凭证号
    number = next_voucher_number(company["id"])
    
    # 7. 创建凭证
    entry_id = str(uuid.uuid4())
    now_ts = _to_swift_date(datetime.datetime.now(datetime.timezone.utc))
    
    entry = {
        "id": entry_id,
        "number": number,
        "date": date_ts,
        "summary": summary,
        "attachmentCount": 0,
        "isPosted": False,
        "createdAt": now_ts,
        "updatedAt": now_ts,
        "companyID": company["id"],
        "lines": []
    }
    
    for l in lines:
        debit = float(Decimal(str(l.get("debit", 0))))
        credit = float(Decimal(str(l.get("credit", 0))))
        entry["lines"].append({
            "id": str(uuid.uuid4()),
            "entryID": entry_id,
            "accountID": l["accountID"],
            "accountCode": l["accountCode"],
            "accountName": l["accountName"],
            "debit": debit,
            "credit": credit,
            "summary": l.get("lineSummary", summary)
        })
    
    # 8. 写入
    entries = _read_json("entries.json")
    entries.append(entry)
    _write_json("entries.json", entries)
    
    return {"success": True, "entry": entry}
```

- [ ] **Step 9: 余额计算**

```python
def calc_balance(company_id: str, account_id: str, up_to: datetime.datetime = None) -> Decimal:
    if up_to is None: up_to = datetime.datetime.now(datetime.timezone.utc)
    up_to_ts = _to_swift_date(up_to)
    
    entries = _read_json("entries.json")
    company_entries = [e for e in entries 
                       if e.get("companyID") == company_id 
                       and e.get("isPosted", False)
                       and e.get("date", 0) <= up_to_ts]
    
    # 找这个科目的 nature
    accounts = get_accounts(company_id)
    account = next((a for a in accounts if a["id"] == account_id), None)
    if not account: return Decimal(0)
    
    # 根据 AccountCategory 判断方向
    nature_is_debit = account["category"] in ("资产", "费用")
    
    total_debit = Decimal(0)
    total_credit = Decimal(0)
    for entry in company_entries:
        for line in entry.get("lines", []):
            if line.get("accountID") == account_id:
                total_debit += Decimal(str(line.get("debit", 0)))
                total_credit += Decimal(str(line.get("credit", 0)))
    
    if nature_is_debit:
        return total_debit - total_credit
    else:
        return total_credit - total_debit
```

- [ ] **Step 10: 报表生成**

```python
def income_statement(company_name: str, year: int, month: int) -> dict:
    company = get_company(company_name)
    if not company: return {"error": f"公司 '{company_name}' 不存在"}
    
    accounts = get_accounts(company["id"])
    rev_codes = {"5001", "5051", "5111"}
    
    revenues = [a for a in accounts if a["code"] in rev_codes and a.get("isActive", True)]
    expenses = [a for a in accounts if a["category"] == "费用" and a.get("isActive", True)]
    
    # 计算期间发生额
    # ... (完整逻辑见 AccountingEngine.incomeStatement)
```

- [ ] **Step 11: main() 函数 — CLI 入口**

提供 CLI 入口方便调试和测试：
```python
def main():
    import sys
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    if cmd == "list-companies":
        for c in list_companies():
            print(f"{c['name']} ({c['id']})")
    elif cmd == "show-company":
        c = get_company(sys.argv[2])
        print(json.dumps(c, ensure_ascii=False, indent=2))
    # ...

if __name__ == "__main__":
    main()
```

---

### Task 2: 创建 finbooks-agent SKILL.md — Agent 交互层

**Files:**
- Create: `/Users/zhouchao/.hermes/skills/finbooks-agent/SKILL.md`

Agent 技能文件，定义完整的交互规则、数据模型、财务规则。内容应包括：
- 数据路径说明
- JSON 数据结构（Company, Account, JournalEntry, JournalLine, PeriodClose）
- 财务规则铁律（借贷平衡、结账锁定、科目存在、编号连续、操作前备份）
- 每个技能函数的调用指南（何时调用、参数格式、返回值处理）
- 安全交互流程（展示→确认→执行→验证）

---

### Task 3: 端到端测试

**Files:**
- Modify: `/Users/zhouchao/.hermes/skills/finbooks-agent/finbooks_tools.py` (如果有问题)
- Testing on real data

- [ ] Step 1: 测试 list_companies() 返回"示例科技有限公司"
- [ ] Step 2: 测试 get_accounts() 返回 28 个科目
- [ ] Step 3: 测试 create_voucher() 创建有效凭证
- [ ] Step 4: 测试 create_voucher() 拒绝不平凭证
- [ ] Step 5: 测试 next_voucher_number() 正确编号
- [ ] Step 6: 测试 calc_balance() 返回正确余额
- [ ] Step 7: 测试 income_statement() 返回正确利润表
- [ ] Step 8: 测试 balance_sheet() 返回正确资产负债表
- [ ] Step 9: 在 FinBooks App 中打开验证 Agent 写入的数据

---

### Task 4: 实现智能分析查询

**Files:**
- Append to: `/Users/zhouchao/.hermes/skills/finbooks-agent/finbooks_tools.py`

- [ ] Step 1: 异常检测（大额异常、重复凭证、不平凭证）
- [ ] Step 2: 趋势分析（费用月度对比、收入趋势）
- [ ] Step 3: Top N 分析（前十大费用科目）

---

### Task 5: 导入 CSV 能力

**Files:**
- Append to: `/Users/zhouchao/.hermes/skills/finbooks-agent/finbooks_tools.py`

- [ ] Step 1: 解析 CSV（支持银行流水格式自动检测）
- [ ] Step 2: 科目自动匹配（基于关键字）
- [ ] Step 3: 生成凭证草稿供用户确认