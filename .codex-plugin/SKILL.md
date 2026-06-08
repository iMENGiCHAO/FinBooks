# FinBooks Codex Plugin Skill

Install FinBooks as a local Codex plugin that gives your agent financial management capabilities.

## Prerequisites

- Python 3.8+ on the machine
- FinBooks app installed (download `.app` and open once to initialize data)

## Installation

1. **One-Click Install (Recommended)**
   Open FinBooks app → AI Assistant → Click "安装全部" button.
   This installs:
   - Bridge HTTP service (auto-starts on login)
   - Codex plugin
   - Hermes plugin (if Hermes detected)
   - OpenClaw plugin (if OpenClaw detected)

2. **Manual Install via Terminal**
   ```bash
   bash /path/to/FinBooks/scripts/install_finbooks_plugin.sh
   ```

3. **Manual Start Bridge**
   ```bash
   python3 /path/to/FinBooks/scripts/finbooks_bridge.py
   ```

## What This Plugin Provides

The Bridge runs on `http://localhost:9090` and offers these tools:

### Financial Queries
- `finbooks_query_balance` — Real-time account balance
- `finbooks_list_accounts` — Chart of accounts
- `finbooks_list_entries` — Journal entries filtered by period
- `finbooks_get_totals` — Core financial summary

### Financial Reports
- `finbooks_income_statement` — Income statement (P&L)
- `finbooks_balance_sheet` — Balance sheet
- `finbooks_cash_flow` — Cash flow statement
- `finbooks_vat_report` — VAT tax report
- `finbooks_general_ledger` — General ledger detail

### Data Entry
- `finbooks_create_entry` — Create journal entries (auto-validates balance)
- `finbooks_create_account` — Create accounts

### Audit & Export
- `finbooks_get_anomalies` — Scan for anomalies
- `finbooks_get_audit_logs` — Audit trail
- `finbooks_export_csv` — Export for tax/audit (CSV)

## Testing After Install

```bash
# Check if Bridge is running
curl http://localhost:9090/health

# Query balance
curl "http://localhost:9090/api/balance?accountCode=1001"

# Get total assets
curl http://localhost:9090/api/totals

# Create a journal entry
curl -X POST http://localhost:9090/api/entry/create \
  -H "Content-Type: application/json" \
  -d '{"companyId":"...","summary":"test","lines":[{"account_code":"1001","account_name":"现金","debit":100,"credit":0}],"debitTotal":100,"creditTotal":100,"isPosted":true}'
```

## Troubleshooting

- **"Bridge 连接失败"**: Start bridge via `python3 scripts/finbooks_bridge.py`
- **Port conflict**: Kill existing process: `kill $(lsof -t -i :9090)`
- **Data not loading**: App saves to `~/Library/Application Support/com.finbooks.app/`
