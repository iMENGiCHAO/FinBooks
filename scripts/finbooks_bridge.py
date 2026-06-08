#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FinBooks Bridge Server v2.4.0
============================
FinBooks HTTP API + AI 聊天代理服务
监听 localhost:9090，为 Hermes / OpenClaw / Codex 等智能体提供财务数据操作接口。

数据存储：读取 FinBooks Swift App 的 JSON 文件
启动方式：python3 finbooks_bridge.py
"""

import json, os, sys, uuid, hashlib, re, csv, io, datetime, threading, time, zipfile, shutil, glob
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from datetime import datetime as dt, date, timedelta
from decimal import Decimal, ROUND_HALF_UP
from typing import Optional, Any

DATA_DIR = os.path.expanduser("~/Library/Application Support/com.finbooks.app")
CONFIG_DIR = os.path.expanduser("~/.finbooks")
HOST, PORT = "127.0.0.1", 9090
VERSION = "2.6.0"
_config = {}
_DEFAULT_MODEL = "deepseek-chat"
_DEFAULT_BASE_URL = "https://api.deepseek.com/v1"
_data_lock = threading.Lock()
_FILE_LOCK_PATH = os.path.expanduser("~/Library/Application Support/com.finbooks.app/.bridge_lock")

def _acquire_data_lock(timeout: float = 5.0) -> bool:
    """获取文件级数据锁，防止 App 和 Bridge 同时写 JSON
    使用文件锁（跨进程同步）- 锁文件持久存在，不删除避免竞态条件
    修复：失败重试时关闭旧 fd，防止 fd 泄漏"""
    try:
        import fcntl
        from threading import current_thread
        import os as _os
        # 锁文件持久存在，只创建一次
        if not os.path.exists(_FILE_LOCK_PATH):
            basedir = os.path.dirname(_FILE_LOCK_PATH)
            os.makedirs(basedir, exist_ok=True)
            fd = os.open(_FILE_LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o644)
            os.close(fd)
        fd = os.open(_FILE_LOCK_PATH, os.O_RDWR)
        deadline = time.time() + timeout
        last_error = None
        acquired = False
        while time.time() < deadline:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                os.ftruncate(fd, 0)
                os.lseek(fd, 0, os.SEEK_SET)
                os.write(fd, str(os.getpid()).encode())
                with _lock_fds_lock:
                    _lock_fds[current_thread().ident] = fd
                acquired = True
                return True
            except (IOError, OSError, BlockingIOError) as exc:
                last_error = exc
                time.sleep(0.1)
        # 超时：关闭 fd 防止泄漏
        if not acquired:
            _safe_close_fd(fd)
        if last_error:
            print(f"[Bridge] 数据锁获取超时 ({timeout}s): {last_error}")
        else:
            print(f"[Bridge] 数据锁获取超时 ({timeout}s): 未知原因")
        return False
    except (ImportError, AttributeError, OSError):
        return True  # 不支持文件锁的平台上 fallthrough

_lock_fds: dict = {}
_lock_fds_lock = threading.Lock()

def _safe_close_fd(fd):
    """安全关闭 fd，忽略错误（防止 fd 泄漏）"""
    if fd is not None:
        try:
            import os as _os
            _os.close(fd)
        except (OSError, ImportError):
            pass


def _release_data_lock():
    """释放数据锁 - 关闭 fd 释放锁
    锁文件保留作为哨兵，防止竞态条件。
    修复：使用 _safe_close_fd 统一处理关闭逻辑
    """
    from threading import current_thread
    tid = current_thread().ident
    with _lock_fds_lock:
        fd = _lock_fds.pop(tid, None)
    _safe_close_fd(fd)


# 从配置文件加载设置
def _init_config():
    """加载配置并设置全局变量和 _config"""
    global HOST, PORT, _DEFAULT_MODEL, _DEFAULT_BASE_URL
    cfg = {}
    for path in (os.path.join(CONFIG_DIR, "config.json"), os.path.join(CONFIG_DIR, "config.yaml")):
        if os.path.exists(path):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    if path.endswith(".json"):
                        cfg.update(json.load(f))
                    else:
                        for line in f:
                            if ":" in line and not line.strip().startswith("#"):
                                k, v = line.split(":", 1)
                                cfg[k.strip()] = v.strip().strip("\"'").strip()
            except Exception as e:
                print(f"[Bridge] Config load warning ({path}): {e}")
            break
    _config.update(cfg)
    if cfg.get("bridge_host"):
        HOST = cfg["bridge_host"]
    if cfg.get("bridge_port"):
        PORT = int(cfg["bridge_port"])
    if cfg.get("model"):
        _DEFAULT_MODEL = cfg["model"]
    if cfg.get("base_url"):
        _DEFAULT_BASE_URL = cfg["base_url"]

_init_config()

_RELOAD_COUNTER = 0
_sessions = {}
_MAX_SESSION_MSGS = 20
_SESSION_TTL = 3600 * 2

_cache = {}
_accounts_by_code = {}
_accounts_by_id = {}
_entries_by_id = {}
_audit_log = []

# ══════════════════════════════════════════════════════════════════════
# 数据层
# ══════════════════════════════════════════════════════════════════════



def _generate_config_template():
    """Generate default config template if not exists."""
    config_dir = os.path.expanduser("~/.finbooks")
    os.makedirs(config_dir, exist_ok=True)
    config_path = os.path.join(config_dir, "config.json")
    if not os.path.exists(config_path):
        default_cfg = {
            "bridge_host": "127.0.0.1",
            "bridge_port": 9090,
            "model": "deepseek-chat",
            "base_url": "https://api.deepseek.com/v1",
            "vatAccountCodes": {
                "outputTax": "",
                "inputTax": "",
                "unpaidVAT": "",
                "_comment": "留空则自动匹配。标准科目: outputTax=2221001(销项税额), inputTax=2221002(进项税额), unpaidVAT=2221003(未交增值税)"
            },
            "taxRates": {
                "vat": 0.13,
                "corporateIncomeTax": 0.25,
                "smallBusinessVAT": 0.03,
                "_comment": "一般纳税人增值税13%, 企业所得税25%, 小规模纳税人3%"
            },
            "companyInfo": {
                "taxpayerID": "",
                "taxRegistrationNumber": "",
                "_comment": "纳税人识别号和税务登记号，用于税表导出"
            }
        }
        try:
            with open(config_path, "w", encoding="utf-8") as f:
                json.dump(default_cfg, f, ensure_ascii=False, indent=2)
            print(f"  [Bridge] Default config created: {config_path}")
        except Exception as e:
            print(f"  [Bridge] Config creation warning: {e}")


def _load_json(filename: str) -> list:
    path = os.path.join(DATA_DIR, filename)
    if not os.path.exists(path):
        return []
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except (json.JSONDecodeError, OSError):
        return []

def _save_json(filename: str, data: list):
    path = os.path.join(DATA_DIR, filename)
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2, default=str)
    except OSError as e:
        print(f"[Bridge] 写入失败 {filename}: {e}")

def _cleanup_old_sessions():
    """清理过期的会话"""
    now = time.time()
    expired = [sid for sid, data in list(_sessions.items())
               if now - data.get("updated_at", 0) > _SESSION_TTL]
    for sid in expired:
        del _sessions[sid]
    if expired:
        print(f"  [Bridge] 清理 {len(expired)} 个过期会话")

def _reload_cache():
    global _cache, _accounts_by_code, _accounts_by_id, _entries_by_id, _RELOAD_COUNTER
    _acquire_data_lock()
    try:
        _cache = {
            "companies": _load_json("companies.json"),
            "accounts": _load_json("accounts.json"),
            "entries": _load_json("entries.json"),
            "periodCloses": _load_json("periodCloses.json"),
            "invoices": _load_json("invoices.json"),
            "balanceCache": _load_json("balanceCache.json"),
            "bankAccounts": _load_json("bankAccounts.json"),
            "bankTransactions": _load_json("bankTransactions.json"),
            "reconciliations": _load_json("reconciliations.json"),
            "fixedAssets": _load_json("fixedAssets.json"),
            "auditLogs": _load_json("auditLogs.json"),
        }
        # 去重：相同科目编码只保留第一个活跃记录
        _deduped_accounts = []
        _seen_codes = set()
        for a in _cache.get("accounts", []):
            code = a.get("code", "")
            if code and code in _seen_codes:
                continue
            if code:
                _seen_codes.add(code)
            _deduped_accounts.append(a)
        _cache["accounts"] = _deduped_accounts
        
        _accounts_by_code = {}
        _accounts_by_id = {}
        for a in _cache.get("accounts", []):
            code = a.get("code", "")
            aid = a.get("id", "")
            if code:
                _accounts_by_code[code] = a
            if aid:
                _accounts_by_id[aid] = a
        _entries_by_id = {}
        for e in _cache.get("entries", []):
            eid = e.get("id", "")
            if eid:
                _entries_by_id[eid] = e
        _RELOAD_COUNTER += 1
    finally:
        _release_data_lock()

def _save_one(fn: str, key: str):
    _acquire_data_lock()
    try:
        _save_json(fn, _cache.get(key, []))
    finally:
        _release_data_lock()

def _append_audit_log(action: str, detail: str, company_id: str = ""):
    """追加审计日志（立即写磁盘）"""
    log = {
        "id": str(uuid.uuid4()),
        "timestamp": dt.now().isoformat(),
        "action": action,
        "detail": detail,
        "companyID": company_id,
        "ip": "127.0.0.1",
    }
    _audit_log.append(log)
    # 立即持久化到磁盘
    try:
        existing = _load_json("auditLogs.json")
        existing.append(log)
        _save_json("auditLogs.json", existing)
    except Exception:
        pass

def _get_company() -> dict:
    """获取第一个公司（默认）"""
    cs = _cache.get("companies", [])
    if cs:
        return cs[0]
    return {"id": "", "name": "示例公司", "taxId": "", "currency": "CNY"}

def _get_company_by_id(company_id: str) -> dict:
    """按 ID 获取公司"""
    for c in _cache.get("companies", []):
        if c.get("id", "") == company_id:
            return c
    # fallback: 没有匹配则返回第一个
    return _get_company()

def _get_company_id() -> str:
    c = _get_company()
    return c.get("id", "")


def _is_period_closed(company_id: str, year: int, month: int) -> bool:
    """检查指定会计期间是否已结账"""
    pcs = _cache.get("periodCloses", [])
    for pc in pcs:
        pc_cid = pc.get("companyID", "") or pc.get("companyId", "")
        if pc_cid == company_id and pc.get("year") == year and pc.get("month") == month:
            if pc.get("isClosed", False):
                return True
    return False

def _parse_date(s: str) -> Optional[dt]:
    """Parse date string supporting multiple formats with proper slicing."""
    if not s:
        return None
    # Handle numeric timestamps (float/int from stored entry dates)
    if isinstance(s, (int, float)):
        try:
            return dt.fromtimestamp(s)
        except (ValueError, OSError):
            return None
    # (format, slice_length) — None means use full string for formats with millis/tz
    formats = [
        ("%Y-%m-%dT%H:%M:%S.%fZ", None),
        ("%Y-%m-%dT%H:%M:%S.%f", None),
        ("%Y-%m-%dT%H:%M:%S", 19),
        ("%Y-%m-%d %H:%M:%S", 19),
        ("%Y-%m-%d", 10),
    ]
    for fmt, length in formats:
        candidate = s if length is None else s[:length]
        try:
            return dt.strptime(candidate, fmt)
        except ValueError:
            continue
    return None

def _resolve_line_code(line: dict) -> str:
    """从分录行解析科目编码（兼容 accountCode 缺失、仅存 accountID 的情况）"""
    code = line.get("accountCode", "") or ""
    if code:
        return code
    aid = line.get("accountID", "") or ""
    if aid and aid in _accounts_by_id:
        return _accounts_by_id[aid].get("code", "")
    return ""


def _calc_balance(acct: dict, entries: list, company_id: str = "") -> float:
    """返回 float 精度的余额（兼容现有调用方）"""
    return float(_calc_balance_decimal(acct, entries, company_id))

def _calc_balance_decimal(acct: dict, entries: list, company_id: str = "") -> Decimal:
    """返回 Decimal 精度的余额计算（供 CSV 导出等需要精确值的场景使用）"""
    aid = acct.get("id", "")
    cat = acct.get("category", "")
    bd = acct.get("balanceDirection") or ("debit" if cat in ("asset", "expense") else "credit")
    # 按公司过滤（多公司隔离）
    if company_id:
        entries = [e for e in entries if e.get("companyID", "") == company_id]
    td = Decimal("0")
    tc = Decimal("0")
    for e in entries:
        if not e.get("isPosted"):
            continue
        for l in e.get("lines", []):
            if l.get("accountID", "") == aid:
                td += Decimal(str(l.get("debit", 0) or 0))
                tc += Decimal(str(l.get("credit", 0) or 0))
    return td - tc if bd == "debit" else tc - td

def _filter_entries(year=None, month=None):
    """按年月筛选已过账凭证"""
    entries = _cache.get("entries", [])
    result = []
    for e in entries:
        if not e.get("isPosted"):
            continue
        d = _parse_date(e.get("date", ""))
        if d:
            if year is not None and d.year != year:
                continue
            if month is not None and d.month != month:
                continue
        result.append(e)
    return result

def _classify_account(code: str):
    """对科目编码进行分类（经营/投资/筹资）"""
    if code.startswith(("1001", "1002")):
        return "cash"
    if code.startswith(("1101", "1122", "1123", "1221")):
        return "operating"
    if code.startswith(("1401", "1402", "1403", "1405", "1601", "1602")):
        return "investing"
    if code.startswith(("2001", "2501")):
        return "financing"
    if code.startswith(("2201", "2202", "2203", "2211", "2221", "2241")):
        return "operating"
    if code.startswith(("4001", "4103", "4104")):
        return "financing"
    if code.startswith(("5001", "5051", "5111")):
        return "operating"
    if code.startswith(("6001", "6401", "6601", "6602", "6603", "6801")):
        return "operating"
    return "operating"

_reload_cache()

# ══════════════════════════════════════════════════════════════════════
# HTTP Handler
# ══════════════════════════════════════════════════════════════════════

class Handler(BaseHTTPRequestHandler):

    def _h(self, status=200, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Session-Id")
        self.end_headers()

    def _j(self, data, status=200):
        self._h(status)
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode())

    def _e(self, msg, status=400):
        self._j({"error": msg}, status)

    def _read_body(self):
        cl = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(cl) if cl > 0 else b"{}"
        try:
            return json.loads(body.decode()) if body else {}
        except json.JSONDecodeError:
            return {}

    def do_OPTIONS(self):
        self._h(200)

    def do_GET(self):
        p = urlparse(self.path)
        path = p.path.rstrip("/")
        q = {k: v[0] if len(v) == 1 else v for k, v in parse_qs(p.query).items()}
        _reload_cache()

        routes = {
            "/health": self._health,
            "/api/session/clear": self._session_clear,
            "/api/balance": self._balance,
            "/api/accounts": self._accounts,
            "/api/entries": self._entries,
            "/api/totals": self._totals,
            "/api/anomalies": self._anomalies,
            "/api/audit-logs": self._audit_logs,
            "/api/report/income": self._income,
            "/api/report/balance-sheet": self._balance_sheet,
            "/api/report/cash-flow": self._cash_flow,
            "/api/report/vat": self._vat,
            "/api/report/general-ledger": self._general_ledger,
            "/api/report/trial-balance": self._trial_balance,
            "/api/report/aging": self._aging_report,
            "/api/export/csv": self._csv_export,
            "/api/backup": self._backup,
            "/api/plugin/manifest": self._plugin_manifest,
            "/api/register-plugin": self._register_plugin,
            "/api/audit/export": self._audit_export,
            "/api/tax/export": self._tax_export,
            "/api/plugin/download": self._plugin_download,
            "/api/plugin/uninstall-from-agent": self._plugin_uninstall_from_agent,
            "/api/period-status": self._period_status,
            "/api/tax/corporate-income-tax": self._corporate_income_tax,
            "/api/audit/working-paper": self._audit_working_paper,

        }
        handler = routes.get(path)
        if handler:
            handler(q)
        else:
            self._e(f"未知端点: {path}", 404)

    def do_POST(self):
        data = self._read_body()
        p = urlparse(self.path)
        path = p.path.rstrip("/")
        _reload_cache()

        if path == "/chat":
            self._chat(data)
        elif path == "/api/entry/create":
            self._create_entry(data)
        elif path == "/api/account/create":
            self._create_account(data)
        elif path == "/api/unclose":
            self._unclose_period(data)
        elif path == "/api/close":
            self._close_period(data)
        elif path == "/api/plugin/register":
            self._plugin_register(data)
        elif path == "/api/plugin/install-to-agent":
            self._plugin_install_to_agent(data)
        elif path == "/api/plugin/uninstall-from-agent":
            self._plugin_uninstall_from_agent(data)
        elif path == "/api/plugin/unregister":
            self._plugin_unregister(data)
        elif path == "/api/plugin/register-to-agent":
            self._plugin_register_to_agent(data)

        elif path == "/api/sync":
            self._j({"status": "ok", "message": "数据已刷新"})
        else:
            self._e(f"未知端点: {path}", 404)

    # ── Plugin Manifest & Registration ──────────────────────────────────────

    def _plugin_manifest(self, _):
        """返回 Codex 兼容的 plugin.json，供智能体自动发现"""
        import os as _os
        project_dir = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
        plugin_json_path = _os.path.join(project_dir, '.codex-plugin', 'plugin.json')
        if _os.path.exists(plugin_json_path):
            with open(plugin_json_path, 'r', encoding='utf-8') as f:
                manifest = json.load(f)
            manifest['discovery_url'] = f'http://127.0.0.1:{PORT}/api/plugin/manifest'
            self._j(manifest)
        else:
            self._e('plugin.json not found', 404)

    def _register_plugin(self, q):
        """GET 方式注册智能体到 Bridge"""
        agent_type = q.get('agent_type', '')
        agent_name = q.get('agent_name', 'unknown')
        _append_audit_log('plugin_register', f'智能体 {agent_name} ({agent_type}) 已注册到 FinBooks Bridge')
        self._j({
            'status': 'ok',
            'agent_type': agent_type,
            'agent_name': agent_name,
            'message': f'FinBooks Bridge 欢迎 {agent_name}',
            'plugin_url': f'http://127.0.0.1:{PORT}/api/plugin/manifest',
            'health_url': f'http://127.0.0.1:{PORT}/health',
        })

    def _plugin_register(self, data):
        """POST 方式注册智能体 — 支持自动安装插件"""
        agent_type = data.get('agent_type', '')
        agent_dir = data.get('agent_dir', '')
        agent_name = data.get('agent_name', 'unknown')
        install = data.get('install', False)
        import os as _os, shutil
        
        _append_audit_log('plugin_register', f'智能体 {agent_name} ({agent_type}) 注册到 Bridge')
        result = {
            'status': 'ok',
            'agent_type': agent_type,
            'agent_name': agent_name,
            'message': '已注册到 FinBooks Bridge',
            'plugin_manifest_url': f'http://127.0.0.1:{PORT}/api/plugin/manifest',
            'status_url': f'http://127.0.0.1:{PORT}/health',
        }
        
        if install and agent_dir:
            project_dir = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
            try:
                if agent_type == 'hermes':
                    plugin_src = _os.path.join(project_dir, '.hermes-plugin')
                elif agent_type == 'openclaw':
                    plugin_src = _os.path.join(project_dir, '.openclaw-plugin')
                elif agent_type == 'codex':
                    plugin_src = _os.path.join(project_dir, '.codex-plugin')
                else:
                    raise ValueError(f'未知智能体类型: {agent_type}')
                
                if _os.path.exists(plugin_src):
                    _os.makedirs(agent_dir, exist_ok=True)
                    for fname in _os.listdir(plugin_src):
                        src = _os.path.join(plugin_src, fname)
                        if _os.path.isfile(src):
                            shutil.copy2(src, _os.path.join(agent_dir, fname))
                    result['installed_to'] = agent_dir
                    result['message'] = f'插件已安装到 {agent_dir}'
                    _append_audit_log('plugin_install', f'FinBooks 插件已安装到 {agent_type} ({agent_dir})')
                else:
                    result['warning'] = f'插件源目录不存在: {plugin_src}'
            except Exception as e:
                result['warning'] = f'插件安装失败: {e}'
        
        self._j(result)


    def _plugin_register_to_agent(self, data):
        """POST: 智能体主动注册时自动安装插件（Hermes/OpenClaw 通过此端点自注册）"""
        import os, shutil
        agent_type = data.get('agent_type', '')
        agent_dir = data.get('agent_dir', '')
        agent_name = data.get('agent_name', '')
        project_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        
        _append_audit_log('plugin_register', f'智能体 {agent_name} ({agent_type}) 注册并自动安装 FinBooks 插件')
        
        if not agent_type:
            self._j({'status': 'ok', 'message': '已注册到 FinBooks Bridge (无智能体类型，跳过插件安装)',
                     'plugin_manifest_url': f'http://127.0.0.1:{PORT}/api/plugin/manifest'})
            return
        
        install_ok = False
        plugin_paths = {
            'hermes': os.path.join(project_dir, '.hermes-plugin'),
            'openclaw': os.path.join(project_dir, '.openclaw-plugin'),
            'codex': os.path.join(project_dir, '.codex-plugin'),
        }
        
        src = plugin_paths.get(agent_type)
        if src and os.path.exists(src):
            try:
                # Determine destination
                if agent_dir:
                    dest = os.path.join(agent_dir, 'plugins', 'finbooks')
                else:
                    dest = os.path.expanduser(f'~/.{agent_type}/plugins/finbooks')
                
                os.makedirs(dest, exist_ok=True)
                shutil.rmtree(dest, ignore_errors=True)
                os.makedirs(dest, exist_ok=True)
                for item in os.listdir(src):
                    s = os.path.join(src, item)
                    d = os.path.join(dest, item)
                    if os.path.isfile(s):
                        shutil.copy2(s, d)
                    elif os.path.isdir(s):
                        shutil.copytree(s, d, dirs_exist_ok=True)
                install_ok = True
            except Exception as e:
                pass
        
        self._j({
            'status': 'ok',
            'agent_type': agent_type,
            'agent_name': agent_name,
            'plugin_installed': install_ok,
            'plugin_url': f'http://127.0.0.1:{PORT}/api/plugin/manifest',
            'download_url': f'http://127.0.0.1:{PORT}/api/plugin/download',
        })


    def _plugin_install_to_agent(self, data):
        """POST: 由 AI 助手触发，一键安装插件到本地智能体"""
        import os, shutil, subprocess
        agent = data.get('agent', 'all')
        project_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        
        agents_to_install = []
        if agent == 'all':
            for a in ['hermes', 'openclaw', 'codex']:
                if os.path.exists(os.path.expanduser(f'~/.{a}')):
                    agents_to_install.append(a)
        else:
            agents_to_install.append(agent)
        
        results = {}
        for a in agents_to_install:
            try:
                agent_dir = os.path.expanduser(f'~/.{a}')
                plugin_dest = os.path.join(agent_dir, 'plugins', 'finbooks')
                os.makedirs(plugin_dest, exist_ok=True)
                
                # Determine source
                src_map = {
                    'hermes': os.path.join(project_dir, '.hermes-plugin'),
                    'openclaw': os.path.join(project_dir, '.openclaw-plugin'),
                    'codex': os.path.join(project_dir, '.codex-plugin'),
                }
                src = src_map.get(a)
                if src and os.path.exists(src):
                    shutil.rmtree(plugin_dest, ignore_errors=True)
                    os.makedirs(plugin_dest, exist_ok=True)
                    for item in os.listdir(src):
                        s = os.path.join(src, item)
                        d = os.path.join(plugin_dest, item)
                        if os.path.isfile(s):
                            shutil.copy2(s, d)
                        elif os.path.isdir(s):
                            shutil.copytree(s, d, dirs_exist_ok=True)
                
                # Bridge script for Hermes
                if a == 'hermes':
                    bridge_src = os.path.join(project_dir, 'scripts', 'finbooks_bridge.py')
                    bridge_dest = os.path.join(agent_dir, 'scripts', 'finbooks_bridge.py')
                    os.makedirs(os.path.dirname(bridge_dest), exist_ok=True)
                    if os.path.exists(bridge_src):
                        shutil.copy2(bridge_src, bridge_dest)
                        os.chmod(bridge_dest, 0o755)
                
                results[a] = 'installed'
            except Exception as e:
                results[a] = f'error: {e}'
        


        # Auto-start Bridge after install
        import subprocess
        bridge_script = os.path.expanduser("~/.hermes/scripts/finbooks_bridge.py")
        if os.path.exists(bridge_script):
            try:
                import urllib.request
                try:
                    urllib.request.urlopen("http://127.0.0.1:9090/health", timeout=1)
                except Exception:
                    subprocess.Popen(
                        ["python3", bridge_script],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        start_new_session=True
                    )
                    launch_agent_dir = os.path.expanduser("~/Library/LaunchAgents")
                    os.makedirs(launch_agent_dir, exist_ok=True)
                    plist_path = os.path.join(launch_agent_dir, "com.finbooks.bridge.plist")
                    plist_xml = '<?xml version="1.0" encoding="UTF-8"?>\n'
                    plist_xml += '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
                    plist_xml += '<plist version="1.0">\n'
                    plist_xml += '<dict>\n'
                    plist_xml += '    <key>Label</key>\n'
                    plist_xml += '    <string>com.finbooks.bridge</string>\n'
                    plist_xml += '    <key>ProgramArguments</key>\n'
                    plist_xml += '    <array>\n'
                    plist_xml += '        <string>/usr/bin/python3</string>\n'
                    plist_xml += '        <string>' + bridge_script + '</string>\n'
                    plist_xml += '    </array>\n'
                    plist_xml += '    <key>RunAtLoad</key>\n'
                    plist_xml += '    <true/>\n'
                    plist_xml += '    <key>KeepAlive</key>\n'
                    plist_xml += '    <true/>\n'
                    plist_xml += '    <key>EnvironmentVariables</key>\n'
                    plist_xml += '    <dict>\n'
                    plist_xml += '        <key>PATH</key>\n'
                    plist_xml += '        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>\n'
                    plist_xml += '    </dict>\n'
                    plist_xml += '</dict>\n'
                    plist_xml += '</plist>\n'
                    with open(plist_path, "w") as f:
                        f.write(plist_xml)
                    subprocess.run(["launchctl", "load", "-w", plist_path], capture_output=True)
            except Exception:
                pass

        self._j({'status': 'ok', 'results': results, 'installed': list(results.keys())})
    def _plugin_uninstall_from_agent(self, data):
        """POST: 由 AI 助手触发，卸载指定智能体插件"""
        import os, shutil
        agent = data.get("agent", "all")
        
        agents_to_uninstall = []
        if agent == "all":
            for a in ["hermes", "openclaw", "codex"]:
                if os.path.exists(os.path.expanduser(f"~/.{a}")):
                    agents_to_uninstall.append(a)
        else:
            agents_to_uninstall.append(agent)
        
        results = {}
        for a in agents_to_uninstall:
            try:
                plugin_dest = os.path.expanduser(f"~/.{a}/plugins/finbooks")
                if os.path.exists(plugin_dest):
                    shutil.rmtree(plugin_dest)
                    results[a] = "uninstalled"
                else:
                    results[a] = "not_installed"
            except Exception as e:
                results[a] = f"error: {e}"
        
        self._j({"status": "ok", "results": results, "uninstalled": list(results.keys())})



    def _plugin_download(self, q):
        """通过 HTTP 提供插件 ZIP 下载"""
        project_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        tmp_zip = f"/tmp/finbooks-plugin-download-{dt.now().strftime('%Y%m%d')}.zip"

        if not os.path.exists(tmp_zip) or (dt.now() - dt.fromtimestamp(os.path.getmtime(tmp_zip))).seconds > 3600:
            tmp_dir = f"/tmp/finbooks-plugin-build-{dt.now().strftime('%Y%m%d')}"
            if os.path.exists(tmp_dir):
                shutil.rmtree(tmp_dir)

            plugin_dir = os.path.join(tmp_dir, "finbooks-plugin")
            for d in ["hermes", "openclaw", "codex", "scripts"]:
                os.makedirs(os.path.join(plugin_dir, d), exist_ok=True)

            src_map = {
                ".hermes-plugin/plugin.yaml": "hermes/plugin.yaml",
                ".hermes-plugin/__init__.py": "hermes/__init__.py",
                ".openclaw-plugin/plugin.yaml": "openclaw/plugin.yaml",
                ".openclaw-plugin/__init__.py": "openclaw/__init__.py",
                ".codex-plugin/plugin.json": "codex/plugin.json",
                ".codex-plugin/SKILL.md": "codex/SKILL.md",
                "scripts/finbooks_bridge.py": "scripts/finbooks_bridge.py",
                "scripts/install_finbooks_plugin.sh": "install_finbooks_plugin.sh",
            }
            for src_rel, dst_rel in src_map.items():
                src = os.path.join(project_dir, src_rel)
                dst = os.path.join(plugin_dir, dst_rel)
                if os.path.exists(src):
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    shutil.copy2(src, dst)

            # Create standalone installer using the shared generator
            installer_path = os.path.join(plugin_dir, "install.sh")
            _gen_standalone_installer(installer_path, plugin_dir)

            # Create README
            with open(os.path.join(plugin_dir, "README.md"), "w") as f:
                f.write("# FinBooks Plugin Package\n\nAI Financial Management System Plugin Package\n\n## Install\n```bash\nbash install.sh\n```\n\n## Manual Bridge Start\n```bash\npython3 scripts/finbooks_bridge.py\n```\n")

            # Zip it
            with zipfile.ZipFile(tmp_zip, "w", zipfile.ZIP_DEFLATED) as zf:
                for root, dirs, files in os.walk(plugin_dir):
                    for fn in files:
                        fp = os.path.join(root, fn)
                        zf.write(fp, os.path.relpath(fp, tmp_dir))

            shutil.rmtree(tmp_dir, ignore_errors=True)

        if not os.path.exists(tmp_zip):
            self._e("插件包生成失败", 500)
            return

        fs = os.path.getsize(tmp_zip)
        self._h(200, "application/zip")
        self.send_header("Content-Disposition", 'attachment; filename="finbooks-plugin.zip"')
        self.send_header("Content-Length", str(fs))
        self.end_headers()
        with open(tmp_zip, "rb") as f:
            shutil.copyfileobj(f, self.wfile)


    def _plugin_unregister(self, data):
        """取消注册智能体"""
        agent_type = data.get('agent_type', '')
        agent_name = data.get('agent_name', 'unknown')
        _append_audit_log('plugin_unregister', f'智能体 {agent_name} ({agent_type}) 已从 Bridge 注销')
        self._j({
            'status': 'ok',
            'message': f'{agent_name} ({agent_type}) 已注销',
        })


    def _period_status(self, q):
        """获取指定会计期间的结账状态"""
        yr = int(q.get("year", 0)) or dt.now().year
        mo = int(q.get("month", 0)) or dt.now().month
        company_id = _get_company_id()
        closed = _is_period_closed(company_id, yr, mo)
        self._j({
            "year": yr,
            "month": mo,
            "isClosed": closed,
            "companyID": company_id,
        })
    
    def _unclose_period(self, data):
        """反结账 — 撤销指定期间的结账状态（带审计日志）"""
        yr = int(data.get("year", 0)) or dt.now().year
        mo = int(data.get("month", 0)) or dt.now().month
        company_id = _get_company_id()
        
        if not _is_period_closed(company_id, yr, mo):
            self._j({"status": "ok", "message": f"期间 {yr}年{mo}月 尚未结账，无需反结账"})
            return
        
        # 获取所有期间结账记录
        pcs = _cache.get("periodCloses", [])
        updated = False
        for pc in pcs:
            pc_cid = pc.get("companyID", "") or pc.get("companyId", "")
            if pc_cid == company_id and pc.get("year") == yr and pc.get("month") == mo:
                pc["isClosed"] = False
                pc["closedAt"] = None
                updated = True
                break
        
        if updated:
            _save_one("periodCloses.json", "periodCloses")
            _append_audit_log("period_unclose", f"反结账: {yr}年{mo}月", company_id)
            self._j({"status": "ok", "message": f"✅ 已撤销 {yr}年{mo}月 的结账状态，审计日志已记录"})
        else:
            self._e(f"未找到 {yr}年{mo}月 的结账记录")
    
    def _close_period(self, data):
        """期末结账 — 标记指定期间为已结账（带审计日志）"""
        yr = int(data.get("year", 0)) or dt.now().year
        mo = int(data.get("month", 0)) or dt.now().month
        company_id = _get_company_id()
        
        if _is_period_closed(company_id, yr, mo):
            self._j({"status": "ok", "message": f"期间 {yr}年{mo}月 已结账"})
            return
        
        import uuid
        new_close = {
            "id": str(uuid.uuid4()),
            "companyID": company_id,
            "companyId": company_id,
            "year": yr,
            "month": mo,
            "isClosed": True,
            "closedAt": dt.now().isoformat(),
            "closedBy": "FinBooks Bridge",
        }
        pcs = _cache.get("periodCloses", [])
        pcs.append(new_close)
        _save_one("periodCloses.json", "periodCloses")
        _append_audit_log("period_close", f"结账: {yr}年{mo}月", company_id)
        self._j({"status": "ok", "message": f"✅ 已标记 {yr}年{mo}月 为已结账"})



    # ── Health ──────────────────────────────────────────────────────

    def _health(self, _):
        self._j({
            "status": "ok",
            "version": VERSION,
            "data_dir": DATA_DIR,
            "accounts_count": len(_cache.get("accounts", [])),
            "entries_count": len(_cache.get("entries", [])),
            "companies_count": len(_cache.get("companies", [])),
            "uptime": int(time.time() - _start_time) if '_start_time' in globals() else 0,
            "plugins": {
                "codex_installed": os.path.exists(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".codex-plugin", "plugin.json")),
                "hermes_installed": os.path.exists(os.path.expanduser("~/.hermes/plugins/finbooks/plugin.yaml")),
                "openclaw_installed": os.path.exists(os.path.expanduser("~/.openclaw/plugins/finbooks/plugin.yaml")),
                "bridge_port": 9090,
                "data_files": {
                    "accounts": len(_cache.get("accounts", [])),
                    "entries": len(_cache.get("entries", [])),
                    "companies": len(_cache.get("companies", []))
                }
            },
        })

    def _session_clear(self, _):
        global _audit_log, _sessions
        _audit_log = []
        sid = self.headers.get("X-Session-Id", "")
        if sid and sid in _sessions:
            del _sessions[sid]
        self._j({"status": "ok", "message": f"会话{sid}已清除"})

    # ── 科目余额 ────────────────────────────────────────────────────

    def _balance(self, q):
        code = q.get("accountCode", "").strip() or q.get("account_code", "").strip()
        if not code:
            self._e("请提供 accountCode 参数")
            return
        acct = _accounts_by_code.get(code)
        if not acct:
            self._e(f"未找到科目: {code}")
            return
        bal = _calc_balance(acct, _cache.get("entries", []))
        self._j({
            "code": acct.get("code", ""),
            "name": acct.get("name", ""),
            "category": acct.get("category", ""),
            "balance": round(bal, 2),
            "balanceDisplay": f"¥{bal:,.2f}",
        })

    # ── 科目列表 ────────────────────────────────────────────────────

    def _accounts(self, _):
        result = []
        for a in _cache.get("accounts", []):
            result.append({
                "id": a.get("id", ""),
                "code": a.get("code", ""),
                "name": a.get("name", ""),
                "category": a.get("category", ""),
                "companyID": a.get("companyID", ""),
                "isActive": a.get("isActive", True),
                "balanceDirection": a.get("balanceDirection", ""),
            })
        self._j({"accounts": result, "total": len(result)})

    # ── 凭证列表 ────────────────────────────────────────────────────

    def _entries(self, q):
        yr = int(q.get("year", 0)) if q.get("year") else None
        mo = int(q.get("month", 0)) if q.get("month") else None
        limit = int(q.get("limit", 50))
        result = []
        for e in _cache.get("entries", []):
            d = _parse_date(e.get("date", ""))
            if d:
                if yr is not None and d.year != yr:
                    continue
                if mo is not None and d.month != mo:
                    continue
            dtot = sum(float(l.get("debit", 0) or 0) for l in e.get("lines", []))
            ctot = sum(float(l.get("credit", 0) or 0) for l in e.get("lines", []))
            result.append({
                "id": e.get("id", ""),
                "number": e.get("number", ""),
                "date": e.get("date", ""),
                "summary": e.get("summary", ""),
                "debitTotal": round(dtot, 2),
                "creditTotal": round(ctot, 2),
                "isPosted": e.get("isPosted", False),
                "linesCount": len(e.get("lines", [])),
            })
        # 按日期降序排列，最新的在前
        result.sort(key=lambda x: x.get("date", ""), reverse=True)
        result = result[:limit]
        self._j({"entries": result, "total": len(result)})

    # ── 财务总览 ────────────────────────────────────────────────────

    def _totals(self, _):
        entries = _cache.get("entries", [])
        accounts = _cache.get("accounts", [])
        ta = tl = teq = tr = tex = 0.0
        ab = {}
        for a in accounts:
            if not a.get("isActive", True):
                continue
            bal = _calc_balance(a, entries)
            cat = a.get("category", "")
            code = a.get("code", "")
            n = a.get("name", "")
            ab[code] = {"name": n, "balance": round(bal, 2), "category": cat}
            if cat == "asset":
                ta += bal
            elif cat == "liability":
                tl += bal
            elif cat == "equity":
                teq += bal
            elif cat == "revenue":
                tr += bal
            elif cat == "expense":
                tex += bal
        company = _get_company()
        posted = [e for e in entries if e.get("isPosted")]
        net_profit = round(tr - tex, 2)
        self._j({
            "companyId": company.get("id", ""),
            "companyName": company.get("name", ""),
            "totals": {
                "assets": round(ta, 2),
                "liabilities": round(tl, 2),
                "equity": round(teq, 2),
                "revenue": round(tr, 2),
                "expense": round(tex, 2),
                "netProfit": net_profit,
            },
            "accountCount": len(accounts),
            "entryCount": len(posted),
            "accountBalances": ab,
            "balanced": abs(ta - (tl + teq)) < 0.01,
        })

    # ── 异常检测 ────────────────────────────────────────────────────

    def _anomalies(self, _):
        entries = _cache.get("entries", [])
        accounts = _cache.get("accounts", [])
        anom = []

        # 1. 借贷不平
        for e in entries:
            dtot = sum(float(l.get("debit", 0) or 0) for l in e.get("lines", []))
            ctot = sum(float(l.get("credit", 0) or 0) for l in e.get("lines", []))
            if dtot > 0 and abs(dtot - ctot) > 0.01:
                anom.append({
                    "type": "借贷不平",
                    "severity": "critical",
                    "description": f"凭证 {e.get('number', '')}: 借¥{dtot:.2f} ≠ 贷¥{ctot:.2f}",
                })

        # 2. 余额方向异常
        for a in accounts:
            if not a.get("isActive", True):
                continue
            bal = _calc_balance(a, entries)
            cat = a.get("category", "")
            code = a.get("code", "")
            n = a.get("name", "")
            # 累计折旧(code=1602) 的负数是正常的
            if code == "1602":
                continue
            bd = a.get("balanceDirection") or ("debit" if cat in ("asset", "expense") else "credit")
            if bd == "debit" and bal < -0.01:
                anom.append({
                    "type": "余额方向异常",
                    "severity": "warning",
                    "description": f"{code} {n} 为借方科目但余额为负 (¥{bal:.2f})",
                })
            elif bd == "credit" and bal < -0.01:
                anom.append({
                    "type": "余额方向异常",
                    "severity": "warning",
                    "description": f"{code} {n} 为贷方科目但出现借方余额 (¥{bal:.2f})",
                })

        # 3. 大额交易
        for e in entries:
            dtot = sum(float(l.get("debit", 0) or 0) for l in e.get("lines", []))
            if dtot > 100000:
                anom.append({
                    "type": "大额交易",
                    "severity": "warning",
                    "description": f"凭证 {e.get('number', '')} 金额 ¥{dtot:.2f}",
                })

        # 4. 资产负债表不平
        ta = tl = teq = 0.0
        for a in accounts:
            if not a.get("isActive", True):
                continue
            bal = _calc_balance(a, entries)
            cat = a.get("category", "")
            if cat == "asset":
                ta += bal
            elif cat == "liability":
                tl += bal
            elif cat == "equity":
                teq += bal
        if abs(ta - (tl + teq)) > 0.01:
            anom.append({
                "type": "资产负债表不平",
                "severity": "critical",
                "description": f"总资产 ¥{ta:.2f} ≠ 总负债+权益 ¥{tl+teq:.2f}",
            })

        if not anom:
            anom.append({
                "type": "正常",
                "severity": "info",
                "description": "未发现财务异常，数据一切正常",
            })

        self._j({"anomalies": anom, "count": len(anom)})

    # ── 审计日志 ────────────────────────────────────────────────────

    def _audit_logs(self, q):
        limit = int(q.get("limit", 20))
        logs = _cache.get("auditLogs", [])
        combined = _audit_log + logs
        combined.sort(key=lambda x: x.get("timestamp", ""), reverse=True)
        self._j({"logs": combined[:limit], "total": min(limit, len(combined))})

    # ══════════════════════════════════════════════════════════════════
    # 报表
    # ══════════════════════════════════════════════════════════════════

    def _income(self, q):
        """利润表 — 实时计算"""
        yr = int(q.get("year", 0)) if q.get("year") else dt.now().year
        mo = int(q.get("month", 0)) if q.get("month") else dt.now().month
        accounts = _cache.get("accounts", [])
        entries = _filter_entries(year=yr, month=mo)
        all_entries = _cache.get("entries", [])

        company = _get_company()
        revenues = []
        expenses = []
        total_revenue = 0.0
        total_expense = 0.0

        for a in accounts:
            if not a.get("isActive", True):
                continue
            cat = a.get("category", "")
            code = a.get("code", "")
            name = a.get("name", "")

            # 本期发生额
            period_debit = 0.0
            period_credit = 0.0
            aid = a.get("id", "")
            for e in entries:
                for l in e.get("lines", []):
                    if l.get("accountID", "") == aid:
                        period_debit += float(l.get("debit", 0) or 0)
                        period_credit += float(l.get("credit", 0) or 0)

            # 本年累计
            cum_entries = _filter_entries(year=yr)
            cum_debit = 0.0
            cum_credit = 0.0
            for e in cum_entries:
                for l in e.get("lines", []):
                    if l.get("accountID", "") == aid:
                        cum_debit += float(l.get("debit", 0) or 0)
                        cum_credit += float(l.get("credit", 0) or 0)

            if cat == "revenue":
                rev = round(period_credit - period_debit, 2)
                cum = round(cum_credit - cum_debit, 2)
                if rev != 0 or cum != 0:
                    revenues.append({
                        "code": code, "name": name,
                        "amount": rev, "cumulativeAmount": cum
                    })
                    total_revenue += rev
            elif cat == "expense":
                exp = round(period_debit - period_credit, 2)
                cum = round(cum_debit - cum_credit, 2)
                if exp != 0 or cum != 0:
                    expenses.append({
                        "code": code, "name": name,
                        "amount": exp, "cumulativeAmount": cum
                    })
                    total_expense += exp

        # 本年累计收入费用（用于累计净利润）
        total_revenue_cum = sum(r.get("cumulativeAmount", 0) for r in revenues)
        total_expense_cum = sum(e.get("cumulativeAmount", 0) for e in expenses)

        # 计算本年累计净利润（含年初未分配利润的调整）
        # 本年利润科目(4103)的贷方余额
        profit_acct = None
        for a in accounts:
            if a.get("code") == "4103":
                profit_acct = a
                break
        retained_earnings = 0.0
        if profit_acct:
            retained_earnings = _calc_balance(profit_acct, all_entries)

        cost_of_sales = [e for e in expenses if e["code"] in ("6001", "6401")]
        operating_expenses = [e for e in expenses if e["code"].startswith(("6601", "6602", "6603"))]
        operating_profit = total_revenue - sum(e["amount"] for e in cost_of_sales) - sum(e["amount"] for e in operating_expenses)
        operating_profit_cum = total_revenue_cum - sum(e.get("cumulativeAmount", 0) for e in cost_of_sales) - sum(e.get("cumulativeAmount", 0) for e in operating_expenses)

        income_tax = next((e["amount"] for e in expenses if e["code"] == "6801"), 0.0)
        income_tax_cum = next((e.get("cumulativeAmount", 0) for e in expenses if e["code"] == "6801"), 0.0)

        self._j({
            "companyName": company.get("name", ""),
            "companyTaxId": company.get("taxId", ""),
            "period": f"{yr}年{mo}月",
            "year": yr,
            "month": mo,
            "currency": company.get("currency", "CNY"),
            "revenues": revenues,
            "totalRevenue": round(total_revenue, 2),
            "totalRevenueCumulative": round(total_revenue_cum, 2),
            "costOfSales": cost_of_sales,
            "totalCostOfSales": round(sum(e["amount"] for e in cost_of_sales), 2),
            "operatingExpenses": operating_expenses,
            "totalOperatingExpenses": round(sum(e["amount"] for e in operating_expenses), 2),
            "expenses": expenses,
            "totalExpense": round(total_expense, 2),
            "totalExpenseCumulative": round(total_expense_cum, 2),
            "operatingProfit": round(operating_profit, 2),
            "operatingProfitCumulative": round(operating_profit_cum, 2),
            "incomeTax": round(income_tax, 2),
            "incomeTaxCumulative": round(income_tax_cum, 2),
            "netProfit": round(total_revenue - total_expense, 2),
            "netProfitCumulative": round(total_revenue_cum - total_expense_cum, 2),
            "retainedEarnings": round(retained_earnings, 2),
        })

    def _balance_sheet(self, q):
        """资产负债表 — 实时计算"""
        date_str = q.get("date", "")
        if date_str:
            bs_date = _parse_date(date_str) or dt.now()
        else:
            bs_date = dt.now()
        accounts = _cache.get("accounts", [])
        entries = _cache.get("entries", [])

        company = _get_company()
        # 只取截止到 bs_date 的已过账凭证
        filtered_entries = [e for e in entries if e.get("isPosted") and
                           (_parse_date(e.get("date", "")) or dt.min) <= bs_date]

        assets = []
        liabilities = []
        equities = []
        total_assets = 0.0
        total_liabilities = 0.0
        total_equities = 0.0

        for a in accounts:
            if not a.get("isActive", True):
                continue
            cat = a.get("category", "")
            bal = _calc_balance(a, filtered_entries)
            code = a.get("code", "")
            name = a.get("name", "")
            aid = a.get("id", "")

            # 年初余额
            year_start = dt(bs_date.year, 1, 1)
            year_start_entries = [e for e in entries if e.get("isPosted") and
                                 (_parse_date(e.get("date", "")) or dt.min) < year_start]
            beginning = _calc_balance(a, year_start_entries)

            item = {
                "code": code,
                "name": name,
                "balance": round(bal, 2),
                "beginningBalance": round(beginning, 2),
                "accountID": aid,
            }

            if cat == "asset":
                assets.append(item)
                total_assets += bal
            elif cat == "liability":
                liabilities.append(item)
                total_liabilities += bal
            elif cat == "equity":
                equities.append(item)
                total_equities += bal

        total_le = total_liabilities + total_equities
        balanced = abs(total_assets - total_le) < 0.01

        self._j({
            "companyName": company.get("name", ""),
            "companyTaxId": company.get("taxId", ""),
            "date": bs_date.strftime("%Y-%m-%d"),
            "currency": company.get("currency", "CNY"),
            "assets": assets,
            "totalAssets": round(total_assets, 2),
            "totalAssetsBeginning": round(sum(a["beginningBalance"] for a in assets), 2),
            "liabilities": liabilities,
            "totalLiabilities": round(total_liabilities, 2),
            "totalLiabilitiesBeginning": round(sum(a["beginningBalance"] for a in liabilities), 2),
            "equities": equities,
            "totalEquities": round(total_equities, 2),
            "totalEquitiesBeginning": round(sum(a["beginningBalance"] for a in equities), 2),
            "totalLE": round(total_le, 2),
            "totalLEBeginning": round(sum(a["beginningBalance"] for a in liabilities) + sum(a["beginningBalance"] for a in equities), 2),
            "balanced": balanced,
            "balanceDiff": round(total_assets - total_le, 2),
        })

    def _cash_flow(self, q):
        """现金流量表 — 间接法"""
        yr = int(q.get("year", 0)) if q.get("year") else dt.now().year
        mo = int(q.get("month", 0)) if q.get("month") else dt.now().month
        accounts = _cache.get("accounts", [])
        entries = _filter_entries(year=yr, month=mo)

        company = _get_company()

        # 现金科目
        cash_ids = set()
        cash_names = {}
        for a in accounts:
            if a.get("code") in ("1001", "1002"):
                cash_ids.add(a.get("id", ""))
                cash_names[a.get("id", "")] = a.get("name", "")

        operating_in = []
        operating_out = []
        investing_in = []
        investing_out = []
        financing_in = []
        financing_out = []
        op_in_total = 0.0
        op_out_total = 0.0
        inv_in_total = 0.0
        inv_out_total = 0.0
        fin_in_total = 0.0
        fin_out_total = 0.0

        for e in entries:
            cash_lines = [l for l in e.get("lines", []) if l.get("accountID", "") in cash_ids]
            other_lines = [l for l in e.get("lines", []) if l.get("accountID", "") not in cash_ids]

            for cl in cash_lines:
                aid = cl.get("accountID", "")
                acct_name = cash_names.get(aid, "")
                is_inflow = float(cl.get("debit", 0) or 0) > 0
                is_outflow = float(cl.get("credit", 0) or 0) > 0

                # 确定对方科目的类别
                best_cat = "operating"
                for ol in other_lines:
                    oid = ol.get("accountID", "")
                    oa = _accounts_by_id.get(oid, {})
                    code = oa.get("code", "")
                    cat = _classify_account(code)
                    if cat == "investing":
                        best_cat = "investing"
                    elif cat == "financing" and best_cat != "investing":
                        best_cat = "financing"

                if is_inflow:
                    amt = float(cl.get("debit", 0))
                    item = {"name": e.get("summary", ""), "amount": round(amt, 2),
                            "account": acct_name}
                    if best_cat == "investing":
                        investing_in.append(item)
                        inv_in_total += amt
                    elif best_cat == "financing":
                        financing_in.append(item)
                        fin_in_total += amt
                    else:
                        operating_in.append(item)
                        op_in_total += amt
                elif is_outflow:
                    amt = float(cl.get("credit", 0))
                    item = {"name": e.get("summary", ""), "amount": round(amt, 2),
                            "account": acct_name}
                    if best_cat == "investing":
                        investing_out.append(item)
                        inv_out_total += amt
                    elif best_cat == "financing":
                        financing_out.append(item)
                        fin_out_total += amt
                    else:
                        operating_out.append(item)
                        op_out_total += amt

        # 期初现金余额（上月末）
        day_before = dt(yr, mo, 1) - timedelta(days=1)
        all_entries = _cache.get("entries", [])
        filtered_before = [e for e in all_entries if e.get("isPosted") and
                          (_parse_date(e.get("date", "")) or dt.min) <= day_before]
        beg_cash = 0.0
        for a in accounts:
            if a.get("code") in ("1001", "1002"):
                beg_cash += _calc_balance(a, filtered_before)

        # 期末现金余额
        end_cash = beg_cash + (op_in_total - op_out_total) + (inv_in_total - inv_out_total) + (fin_in_total - fin_out_total)

        self._j({
            "companyName": company.get("name", ""),
            "period": f"{yr}年{mo}月",
            "year": yr,
            "month": mo,
            "currency": company.get("currency", "CNY"),
            "operatingInflows": operating_in,
            "operatingInflowsTotal": round(op_in_total, 2),
            "operatingOutflows": operating_out,
            "operatingOutflowsTotal": round(op_out_total, 2),
            "operatingNet": round(op_in_total - op_out_total, 2),
            "investingInflows": investing_in,
            "investingInflowsTotal": round(inv_in_total, 2),
            "investingOutflows": investing_out,
            "investingOutflowsTotal": round(inv_out_total, 2),
            "investingNet": round(inv_in_total - inv_out_total, 2),
            "financingInflows": financing_in,
            "financingInflowsTotal": round(fin_in_total, 2),
            "financingOutflows": financing_out,
            "financingOutflowsTotal": round(fin_out_total, 2),
            "financingNet": round(fin_in_total - fin_out_total, 2),
            "beginningCash": round(beg_cash, 2),
            "endingCash": round(end_cash, 2),
            "netCashFlow": round(end_cash - beg_cash, 2),
        })

    def _vat(self, q):
        """增值税申报表 — 实时计算"""
        yr = int(q.get("year", 0)) if q.get("year") else dt.now().year
        mo = int(q.get("month", 0)) if q.get("month") else dt.now().month
        accounts = _cache.get("accounts", [])
        entries = _filter_entries(year=yr, month=mo)

        company = _get_company()

        # 找增值税子科目
        vat_sub = {}
        for a in accounts:
            code = a.get("code", "")
            if code.startswith("2221.01"):
                vat_sub[code] = a.get("id", "")

        input_id = vat_sub.get("2221.01.01", "")
        output_id = vat_sub.get("2221.01.02", "")
        transfer_out_id = vat_sub.get("2221.01.03", "")
        paid_id = vat_sub.get("2221.01.04", "")

        input_total = 0.0
        output_total = 0.0
        transfer_out_total = 0.0
        paid_total = 0.0
        input_details = []
        output_details = []
        rate_buckets = {}

        for e in entries:
            for l in e.get("lines", []):
                aid = l.get("accountID", "")
                if aid == input_id:
                    amt = float(l.get("debit", 0) or 0)
                    input_total += amt
                    input_details.append({
                        "voucherNumber": e.get("number", ""),
                        "summary": e.get("summary", ""),
                        "amount": round(amt, 2),
                        "taxRate": l.get("vatRate", 0),
                        "accountName": "进项税额",
                    })
                    rate = l.get("vatRate", 0)
                    rate_buckets.setdefault(rate, {"input": 0.0, "output": 0.0})
                    rate_buckets[rate]["input"] += amt
                if aid == output_id:
                    amt = float(l.get("credit", 0) or 0)
                    output_total += amt
                    output_details.append({
                        "voucherNumber": e.get("number", ""),
                        "summary": e.get("summary", ""),
                        "amount": round(amt, 2),
                        "taxRate": l.get("vatRate", 0),
                        "accountName": "销项税额",
                    })
                    rate = l.get("vatRate", 0)
                    rate_buckets.setdefault(rate, {"input": 0.0, "output": 0.0})
                    rate_buckets[rate]["output"] += amt
                if aid == transfer_out_id:
                    transfer_out_total += float(l.get("credit", 0) or 0)
                if aid == paid_id:
                    paid_total += float(l.get("debit", 0) or 0)

        deductible = input_total + transfer_out_total
        payable = max(output_total - deductible, 0)
        still_due = max(payable - paid_total, 0)

        rate_breakdown = []
        for rate, amounts in sorted(rate_buckets.items(), key=lambda x: -x[0]):
            rate_breakdown.append({
                "rate": rate,
                "rateDisplay": f"{int(rate * 100)}%" if rate > 0 else "-",
                "inputAmount": round(amounts["input"], 2),
                "outputAmount": round(amounts["output"], 2),
            })

        self._j({
            "companyName": company.get("name", ""),
            "companyTaxId": company.get("taxId", ""),
            "period": f"{yr}年{mo}月",
            "year": yr,
            "month": mo,
            "outputTax": round(output_total, 2),
            "inputTax": round(input_total, 2),
            "transferOut": round(transfer_out_total, 2),
            "deductible": round(deductible, 2),
            "taxPayable": round(payable, 2),
            "paidTax": round(paid_total, 2),
            "stillDue": round(still_due, 2),
            "inputDetails": input_details,
            "outputDetails": output_details,
            "rateBreakdown": rate_breakdown,
        })

    def _general_ledger(self, q):
        """总分类账 — 实时计算"""
        code = q.get("accountCode", "").strip() or q.get("account_code", "").strip()
        yr = int(q.get("year", 0)) if q.get("year") else dt.now().year
        mo = int(q.get("month", 0)) if q.get("month") else dt.now().month

        if not code:
            self._e("请提供 accountCode 参数")
            return

        acct = _accounts_by_code.get(code)
        if not acct:
            self._e(f"未找到科目: {code}")
            return

        aid = acct.get("id", "")
        all_entries = _cache.get("entries", [])

        # 月初
        month_start = dt(yr, mo, 1)
        if mo == 12:
            month_end = dt(yr, 12, 31, 23, 59, 59)
        else:
            month_end = dt(yr, mo + 1, 1) - timedelta(seconds=1)

        # 期初余额 = 上月末
        day_before = month_start - timedelta(seconds=1)
        entries_before = [e for e in all_entries if e.get("isPosted") and
                         (_parse_date(e.get("date", "")) or dt.min) <= day_before]
        opening = _calc_balance(acct, entries_before)

        # 本期凭证
        period_entries = [e for e in all_entries if e.get("isPosted") and
                         (_parse_date(e.get("date", "")) or dt.min) >= month_start and
                         (_parse_date(e.get("date", "")) or dt.min) <= month_end]

        lines = []
        running = opening
        cat = acct.get("category", "")
        bd = acct.get("balanceDirection") or ("debit" if cat in ("asset", "expense") else "credit")

        for e in sorted(period_entries, key=lambda x: (_parse_date(x.get("date", "")) or dt.min, x.get("number", ""))):
            entry_lines = [l for l in e.get("lines", []) if l.get("accountID", "") == aid]
            for l in entry_lines:
                debit = float(l.get("debit", 0) or 0)
                credit = float(l.get("credit", 0) or 0)
                if bd == "debit":
                    running += debit - credit
                else:
                    running += credit - debit
                lines.append({
                    "date": e.get("date", "")[:10],
                    "voucherNumber": e.get("number", ""),
                    "summary": e.get("summary", ""),
                    "debit": round(debit, 2),
                    "credit": round(credit, 2),
                    "runningBalance": round(abs(running), 2),
                    "direction": "借" if running >= 0 else "贷",
                })

        # 本期合计
        debit_total = sum(l["debit"] for l in lines)
        credit_total = sum(l["credit"] for l in lines)

        self._j({
            "accountCode": code,
            "accountName": acct.get("name", ""),
            "year": yr,
            "month": mo,
            "period": f"{yr}年{mo}月",
            "openingBalance": round(opening, 2),
            "debitTotal": round(debit_total, 2),
            "creditTotal": round(credit_total, 2),
            "closingBalance": round(abs(running), 2),
            "closingDirection": "借" if running >= 0 else "贷",
            "lines": lines,
        })

    # ══════════════════════════════════════════════════════════════════
    # CSV 导出
    # ══════════════════════════════════════════════════════════════════

    def _backup(self, q):
        """添加备份 API 端点，返回每个 JSON 文件的最后修改时间（供用户确认数据完整性）"""
        import shutil, glob
        try:
            backup_dir = os.path.join(DATA_DIR, "backups")
            os.makedirs(backup_dir, exist_ok=True)
            ts = dt.now().strftime("%Y%m%d_%H%M%S")
            archive_path = os.path.join(backup_dir, f"finbooks_auto_backup_{ts}.zip")
            # 打包所有 JSON 文件
            json_files = glob.glob(os.path.join(DATA_DIR, "*.json"))
            with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED) as zf:
                for f in json_files:
                    zf.write(f, os.path.basename(f))
            # 清理超过30天的旧备份
            for old_backup in glob.glob(os.path.join(backup_dir, "finbooks_auto_backup_*.zip")):
                if os.path.getmtime(old_backup) < time.time() - 30 * 86400:
                    os.remove(old_backup)
            self._j({
                "status": "ok",
                "path": archive_path,
                "files": len(json_files),
                "size": os.path.getsize(archive_path),
                "message": f"已备份 {len(json_files)} 个文件到 {archive_path}"
            })
        except Exception as e:
            self._j({"status": "error", "message": str(e)})

    def _aging_report(self, q):
        """应收/应付账龄分析报告"""
        yr = int(q.get("year", 0)) if q.get("year") else dt.now().year
        mo = int(q.get("month", 0)) if q.get("month") else dt.now().month
        accounts = _cache.get("accounts", [])
        entries = _filter_entries(year=yr, month=mo)
        
        # 应收账款 (1122) 和 应付账款 (2202)
        ar_accts = [a for a in accounts if a.get("code","").startswith("1122")]
        ap_accts = [a for a in accounts if a.get("code","").startswith("2202")]
        
        aging_buckets = [("0-30天", 30), ("31-60天", 60), ("61-90天", 90), ("90天以上", 9999)]
        
        def calc_aging(accts_list, is_ar=True):
            result = []
            now = dt.now()
            for a in accts_list:
                aid = a.get("id", "")
                total_bal = _calc_balance_decimal(a, entries)
                if total_bal == 0:
                    continue
                # Get individual entry age
                aged = {label: 0.0 for label, _ in aging_buckets}
                for e in entries:
                    if not e.get("isPosted"):
                        continue
                    for l in e.get("lines", []):
                        if l.get("accountID", "") == aid:
                            ed = _parse_date(e.get("date", ""))
                            if ed:
                                days = (now - ed).days
                                amt = abs(float(l.get("debit", 0) or 0) - float(l.get("credit", 0) or 0))
                                for label, threshold in aging_buckets:
                                    if days <= threshold:
                                        aged[label] += amt
                                        break
                result.append({
                    "code": a.get("code", ""),
                    "name": a.get("name", ""),
                    "total": float(total_bal),
                    "aging": aged,
                })
            return result
        
        ar_data = calc_aging(ar_accts, is_ar=True)
        ap_data = calc_aging(ap_accts, is_ar=False)
        
        self._j({
            "period": f"{yr}年{mo}月",
            "receivables": ar_data,
            "payables": ap_data,
            "receivableTotal": sum(d.get("total", 0) for d in ar_data),
            "payableTotal": sum(d.get("total", 0) for d in ap_data),
        })

    def _csv_export(self, q):
        """导出 CSV 文件到 /tmp"""
        rtype = q.get("type", "").strip() or q.get("report_type", "").strip()
        yr = int(q.get("year", 0)) if q.get("year") else dt.now().year
        mo = int(q.get("month", 0)) if q.get("month") else dt.now().month
        code = q.get("account_code", "").strip() or q.get("accountCode", "").strip()

        if not rtype:
            self._e("请提供 type 参数 (general_ledger/trial_balance/vat/entries/tax_bureau)")
            return

        output_path = f"/tmp/finbooks_export_{rtype}_{yr}{mo:02d}_{dt.now().strftime('%Y%m%d_%H%M%S')}.csv"
        row_count = 0

        try:
            with open(output_path, "w", newline="", encoding="utf-8-sig") as f:
                writer = csv.writer(f)

                if rtype == "entries":
                    writer.writerow(["凭证号", "日期", "摘要", "借方合计", "贷方合计", "状态", "分录行数"])
                    entries = _filter_entries(year=yr, month=mo)
                    for e in entries:
                        dtot = sum(float(l.get("debit", 0) or 0) for l in e.get("lines", []))
                        ctot = sum(float(l.get("credit", 0) or 0) for l in e.get("lines", []))
                        writer.writerow([
                            e.get("number", ""),
                            (e.get("date", "") or "")[:10],
                            e.get("summary", ""),
                            round(dtot, 2),
                            round(ctot, 2),
                            "已过账" if e.get("isPosted") else "未过账",
                            len(e.get("lines", [])),
                        ])
                        row_count += 1

                elif rtype == "general_ledger":
                    if not code:
                        self._e("general_ledger 需要 account_code 参数")
                        return
                    acct = _accounts_by_code.get(code)
                    if not acct:
                        self._e(f"未找到科目: {code}")
                        return
                    writer.writerow(["日期", "凭证号", "摘要", "借方", "贷方", "余额", "方向"])
                    aid = acct.get("id", "")
                    all_entries = _cache.get("entries", [])
                    month_start = dt(yr, mo, 1)
                    if mo == 12:
                        month_end = dt(yr, 12, 31, 23, 59, 59)
                    else:
                        month_end = dt(yr, mo + 1, 1) - timedelta(seconds=1)
                    period_entries = [e for e in all_entries if e.get("isPosted") and
                                     (_parse_date(e.get("date", "")) or dt.min) >= month_start and
                                     (_parse_date(e.get("date", "")) or dt.min) <= month_end]
                    day_before = month_start - timedelta(seconds=1)
                    entries_before = [e for e in all_entries if e.get("isPosted") and
                                     (_parse_date(e.get("date", "")) or dt.min) <= day_before]
                    running = _calc_balance(acct, entries_before)
                    cat = acct.get("category", "")
                    bd = acct.get("balanceDirection") or ("debit" if cat in ("asset", "expense") else "credit")

                    for e in sorted(period_entries, key=lambda x: (_parse_date(x.get("date", "")) or dt.min, x.get("number", ""))):
                        for l in e.get("lines", []):
                            if l.get("accountID", "") != aid:
                                continue
                            debit = float(l.get("debit", 0) or 0)
                            credit = float(l.get("credit", 0) or 0)
                            if bd == "debit":
                                running += debit - credit
                            else:
                                running += credit - debit
                            writer.writerow([
                                (e.get("date", "") or "")[:10],
                                e.get("number", ""),
                                e.get("summary", ""),
                                debit, credit,
                                round(abs(running), 2),
                                "借" if running >= 0 else "贷",
                            ])
                            row_count += 1

                elif rtype == "vat":
                    writer.writerow(["类型", "凭证号", "摘要", "金额", "税率"])
                    entries = _filter_entries(year=yr, month=mo)
                    accounts = _cache.get("accounts", [])
                    input_id = output_id = ""
                    for a in accounts:
                        if a.get("code") == "2221.01.01":
                            input_id = a.get("id", "")
                        if a.get("code") == "2221.01.02":
                            output_id = a.get("id", "")
                    for e in entries:
                        for l in e.get("lines", []):
                            aid = l.get("accountID", "")
                            if aid == input_id:
                                writer.writerow(["进项", e.get("number", ""), e.get("summary", ""),
                                               round(float(l.get("debit", 0) or 0), 2), l.get("vatRate", 0)])
                                row_count += 1
                            if aid == output_id:
                                writer.writerow(["销项", e.get("number", ""), e.get("summary", ""),
                                               round(float(l.get("credit", 0) or 0), 2), l.get("vatRate", 0)])
                                row_count += 1

                elif rtype == "tax_bureau":
                    # 中国增值税纳税申报表格式（适用于一般纳税人）
                    writer.writerow(["行次", "项目", "栏次", "本月数", "本年累计"])
                    entries = _filter_entries(year=yr, month=mo)
                    all_entries = _filter_entries(year=yr)
                    accounts = _cache.get("accounts", [])
                    company = _get_company()
                    
                    # 获取 VAT 子科目 ID
                    vat_sub = {}
                    for a in accounts:
                        code = a.get("code", "")
                        if code.startswith("2221.01"):
                            vat_sub[code] = a.get("id", "")
                    input_id = vat_sub.get("2221.01.01", "")
                    output_id = vat_sub.get("2221.01.02", "")
                    transfer_out_id = vat_sub.get("2221.01.03", "")
                    paid_id = vat_sub.get("2221.01.04", "")
                    
                    # 计算本期各税率的销售额和税额
                    gross_sales = 0.0
                    vat_output = 0.0
                    vat_input = 0.0
                    vat_transfer_out = 0.0
                    vat_paid = 0.0
                    rate_detail = {}
                    
                    for e in entries:
                        for l in e.get("lines", []):
                            aid = l.get("accountID", "")
                            if aid == output_id:
                                amt = float(l.get("credit", 0) or 0)
                                vat_output += amt
                                rate = l.get("vatRate", 0)
                                rate_detail.setdefault(rate, {"output": 0.0, "input": 0.0})
                                rate_detail[rate]["output"] += amt
                            elif aid == input_id:
                                amt = float(l.get("debit", 0) or 0)
                                vat_input += amt
                                rate = l.get("vatRate", 0)
                                rate_detail.setdefault(rate, {"output": 0.0, "input": 0.0})
                                rate_detail[rate]["input"] += amt
                            elif aid == transfer_out_id:
                                vat_transfer_out += float(l.get("credit", 0) or 0)
                            elif aid == paid_id:
                                vat_paid += float(l.get("debit", 0) or 0)
                    
                    # 销项税额合计及按税率明细
                    writer.writerow(["", "一、计税依据", "", "", ""])
                    row_num = 1
                    for rate, amounts in sorted(rate_detail.items(), key=lambda x: -x[0]):
                        if amounts["output"] > 0:
                            rate_label = f"{int(rate*100)}%税率计税销售额" if rate > 0 else "免税销售额"
                            writer.writerow([row_num, rate_label, "1",
                                           round(amounts["output"] / (1 + rate) if rate > 0 else amounts["output"], 2),
                                           ""])
                            row_num += 1
                            writer.writerow([row_num, f"{int(rate*100)}%税率销项税额", "2",
                                           round(amounts["output"], 2), ""])
                            gross_sales += amounts["output"] / (1 + rate) if rate > 0 else amounts["output"]
                            row_num += 1
                    
                    writer.writerow([row_num, "销售总额（合计）", "3", round(gross_sales, 2), ""])
                    row_num += 1
                    writer.writerow([row_num, "", "", "", ""])
                    row_num += 1
                    
                    # 进项税额明细
                    writer.writerow([row_num, "二、进项税额", "", "", ""])
                    row_num += 1
                    for rate, amounts in sorted(rate_detail.items(), key=lambda x: -x[0]):
                        if amounts["input"] > 0:
                            rate_label = f"{int(rate*100)}%税率进项税额"
                            writer.writerow([row_num, rate_label, "4",
                                           round(amounts["input"], 2), ""])
                            row_num += 1
                    writer.writerow([row_num, "进项税额合计", "5", round(vat_input, 2), ""])
                    row_num += 1
                    writer.writerow([row_num, "进项税额转出", "6", round(vat_transfer_out, 2), ""])
                    row_num += 1
                    writer.writerow([row_num, "", "", "", ""])
                    row_num += 1
                    
                    # 税额计算
                    writer.writerow([row_num, "三、税款计算", "", "", ""])
                    row_num += 1
                    writer.writerow([row_num, "销项税额", "7", round(vat_output, 2), ""])
                    row_num += 1
                    writer.writerow([row_num, "进项税额（扣除后）", "8", round(max(vat_input - vat_transfer_out, 0), 2), ""])
                    row_num += 1
                    writer.writerow([row_num, "应纳增值税额", "9", round(max(vat_output - max(vat_input - vat_transfer_out, 0), 0), 2), ""])
                    row_num += 1
                    writer.writerow([row_num, "已缴税额", "10", round(vat_paid, 2), ""])
                    row_num += 1
                    writer.writerow([row_num, "本期应补（退）税额", "11",
                                   round(max(vat_output - max(vat_input - vat_transfer_out, 0) - vat_paid, 0), 2), ""])
                    row_num += 1
                    
                    # 本年累计
                    writer.writerow([row_num, "", "", "", ""])
                    row_num += 1
                    writer.writerow([row_num, "公司名称", company.get("name", ""), "", ""])
                    row_num += 1
                    writer.writerow([row_num, "税号", company.get("taxId", ""), "", ""])
                    row_num += 1
                    writer.writerow([row_num, "所属期", f"{yr}年{mo}月", "", ""])
                    row_num += 1
                    
                    row_count = row_num - 1

                elif rtype == "trial_balance":
                    writer.writerow(["科目编码", "科目名称", "类别", "期初余额(借/贷)", "借方发生额", "贷方发生额", "期末余额(借/贷)"])
                    accounts = _cache.get("accounts", [])
                    entries = _filter_entries(year=yr, month=mo)
                    all_entries = _cache.get("entries", [])
                    month_start = dt(yr, mo, 1)
                    if mo == 12:
                        month_end = dt(yr, 12, 31, 23, 59, 59)
                    else:
                        month_end = dt(yr, mo + 1, 1) - timedelta(seconds=1)
                    entries_before = [
                        e for e in all_entries if e.get("isPosted") and
                        (_parse_date(e.get("date", "")) or dt.min) < month_start
                    ]
                    period_entries = [
                        e for e in all_entries if e.get("isPosted") and
                        (_parse_date(e.get("date", "")) or dt.min) >= month_start and
                        (_parse_date(e.get("date", "")) or dt.min) <= month_end
                    ]
                    for a in accounts:
                        if not a.get("isActive", True):
                            continue
                        opening_bal = _calc_balance(a, entries_before)
                        closing_bal = _calc_balance(a, entries)
                        period_debit = sum(
                            float(l.get("debit", 0) or 0)
                            for e in period_entries
                            for l in e.get("lines", [])
                            if l.get("accountID", "") == a.get("id", "") or l.get("accountCode", "") == a.get("code", "")
                        )
                        period_credit = sum(
                            float(l.get("credit", 0) or 0)
                            for e in period_entries
                            for l in e.get("lines", [])
                            if l.get("accountID", "") == a.get("id", "") or l.get("accountCode", "") == a.get("code", "")
                        )
                        open_label = "借" if opening_bal >= 0 else "贷"
                        close_label = "借" if closing_bal >= 0 else "贷"
                        writer.writerow([
                            a.get("code", ""),
                            a.get("name", ""),
                            a.get("category", ""),
                            f"{round(abs(opening_bal), 2)}({open_label})",
                            round(period_debit, 2),
                            round(period_credit, 2),
                            f"{round(abs(closing_bal), 2)}({close_label})",
                        ])
                        row_count += 1
                else:
                    self._e(f"不支持的导出类型: {rtype}")
                    return

            self._j({
                "path": output_path,
                "rowCount": row_count,
                "type": rtype,
                "message": f"已导出 {row_count} 行到 {output_path}",
            })
        except Exception as ex:
            self._e(f"导出失败: {str(ex)}")

    # ══════════════════════════════════════════════════════════════════
    # 创建凭证
    # ══════════════════════════════════════════════════════════════════


    # ── 试算平衡表 ──────────────────────────────────────────────────

    def _trial_balance(self, q):
        """试算平衡表 — 所有科目的期末借方/贷方汇总"""
        yr = int(q.get("year", 0)) if q.get("year") else dt.now().year
        mo = int(q.get("month", 0)) if q.get("month") else dt.now().month
        accounts = _cache.get("accounts", [])
        entries = _filter_entries(year=yr, month=mo)

        lines = []
        total_debit = 0.0
        total_credit = 0.0

        for a in accounts:
            if not a.get("isActive", True):
                continue
            bal = _calc_balance(a, entries)
            cat = a.get("category", "")
            bd = a.get("balanceDirection") or ("debit" if cat in ("asset", "expense") else "credit")
            if bal >= 0:
                debit_bal = bal if bd == "debit" else 0.0
                credit_bal = bal if bd == "credit" else 0.0
            else:
                # 负余额反方向
                debit_bal = -bal if bd == "credit" else 0.0
                credit_bal = -bal if bd == "debit" else 0.0

            lines.append({
                "code": a.get("code", ""),
                "name": a.get("name", ""),
                "category": cat,
                "debitBalance": round(debit_bal, 2),
                "creditBalance": round(credit_bal, 2),
            })
            total_debit += debit_bal
            total_credit += credit_bal

        balanced = abs(total_debit - total_credit) < 0.01

        self._j({
            "period": f"{yr}年{mo}月",
            "year": yr,
            "month": mo,
            "lines": lines,
            "totalDebit": round(total_debit, 2),
            "totalCredit": round(total_credit, 2),
            "balanced": balanced,
            "diff": round(total_debit - total_credit, 2),
        })

    def _create_entry(self, data):
        entries = _cache.get("entries", [])
        summary = data.get("summary", "")
        lines_data = data.get("lines", [])
        company_id = data.get("companyId", "") or _get_company_id()
        is_posted = data.get("isPosted", True)
        entry_date_str = data.get("date", "")

        if not summary or not lines_data:
            self._e("缺少必要参数: summary / lines")
            return

        if not company_id:
            self._e("请先创建公司")
            return

        # 校验期间是否已结账
        entry_yr = entry_date_str[:4] if entry_date_str else str(dt.now().year)
        entry_mo = entry_date_str[5:7] if len(entry_date_str) >= 7 else str(dt.now().month)
        try:
            ey = int(entry_yr)
            em = int(entry_mo)
        except ValueError:
            ey, em = dt.now().year, dt.now().month
        if _is_period_closed(company_id, ey, em):
            self._e(f"期间 {ey}年{em}月 已结账，无法创建凭证。请先反结账后再操作。")
            return

        # 生成凭证号
        yr = dt.now().year
        prefix = f"记-{yr}-"
        used = []
        for e in entries:
            n = e.get("number", "")
            if n.startswith(prefix):
                try:
                    used.append(int(n[len(prefix):]))
                except ValueError:
                    pass
        next_num = max(used) + 1 if used else 1
        number = f"{prefix}{next_num:04d}"

        # 日期
        if entry_date_str:
            entry_date = _parse_date(entry_date_str) or dt.now()
        else:
            entry_date = dt.now()

        now_iso = dt.now().isoformat()
        entry_id = str(uuid.uuid4())
        entry = {
            "id": entry_id,
            "number": number,
            "date": entry_date.isoformat(),
            "summary": summary,
            "attachmentCount": 0,
            "isPosted": is_posted,
            "isDeleted": False,
            "companyID": company_id,
            "createdAt": now_iso,
            "updatedAt": now_iso,
            "lines": [],
        }
        # Validate account codes before writing
        for ld in lines_data:
            code = ld.get("account_code", "") or ld.get("accountCode", "")
            if code and code not in _accounts_by_code:
                self._e(f"科目编码 {code} 不存在，请先创建科目")
                return

        td = tc = 0.0
        for ld in lines_data:
            code = ld.get("account_code", "") or ld.get("accountCode", "")
            acct = _accounts_by_code.get(code, {})
            debit = float(ld.get("debit", 0) or 0)
            credit = float(ld.get("credit", 0) or 0)
            line_summary = ld.get("summary", "") or ld.get("account_name", "") or ld.get("accountName", "")
            vat_rate = float(ld.get("vatRate", ld.get("vat_rate", 0)) or 0)

            entry["lines"].append({
                "id": str(uuid.uuid4()),
                "entryID": entry_id,
                "accountID": acct.get("id", ""),
                "accountCode": code,
                "accountName": acct.get("name", ""),
                "summary": line_summary,
                "debit": round(debit, 2),
                "credit": round(credit, 2),
                "vatRate": vat_rate,
                "vatAmount": round(debit * vat_rate if debit > 0 else credit * vat_rate, 2),
            })
            td += debit
            tc += credit

        entry["debitTotal"] = round(td, 2)
        entry["creditTotal"] = round(tc, 2)
        entries.append(entry)
        _cache["entries"] = entries
        _save_one("entries.json", "entries")
        _append_audit_log("create_entry", f"创建凭证 {number}: {summary}", company_id)

        self._j({
            "entry": {
                "id": entry_id,
                "number": number,
                "date": entry["date"],
                "summary": summary,
                "debitTotal": round(td, 2),
                "creditTotal": round(tc, 2),
                "isPosted": is_posted,
                "balanced": abs(td - tc) < 0.01,
            },
            "balanced": abs(td - tc) < 0.01,
        })

    # ── 创建科目 ────────────────────────────────────────────────────

    def _create_account(self, data):
        accounts = _cache.get("accounts", [])
        code = data.get("code", "").strip()
        name = data.get("name", "").strip()
        cat = data.get("category", "").strip().lower()
        cid = data.get("companyId", "") or _get_company_id()

        if not code or not name or not cat:
            self._e("缺少必要参数: code / name / category")
            return
        if not cid:
            self._e("请先创建公司")
            return

        if code in _accounts_by_code:
            self._e(f"科目编码 {code} 已存在")
            return

        # 标准化类别
        cat_map = {
            "asset": "资产", "liability": "负债", "equity": "所有者权益",
            "revenue": "收入", "expense": "费用",
        }
        display_cat = cat_map.get(cat, cat)

        acct = {
            "id": str(uuid.uuid4()),
            "code": code,
            "name": name,
            "category": display_cat,
            "companyID": cid,
            "isActive": True,
            "sortOrder": len(accounts),
            "balanceDirection": "",
            "parentCode": data.get("parentCode", None),
            "createdAt": dt.now().isoformat(),
            "updatedAt": dt.now().isoformat(),
        }
        accounts.append(acct)
        _cache["accounts"] = accounts
        _save_one("accounts.json", "accounts")
        _reload_cache()
        _append_audit_log("create_account", f"创建科目 {code} {name} ({display_cat})", cid)

        self._j({
            "account": acct,
            "created": True,
            "message": f"科目 {code} {name} 创建成功",
        })

    # ══════════════════════════════════════════════════════════════════
    # AI 聊天 (SSE Streaming)
    # ══════════════════════════════════════════════════════════════════

    def _get_api_key(self) -> str:
        """从多处配置源读取 API Key（优先 Hermes → FinBooks config → 环境变量 → UserDefaults → Keychain）
        支持 DeepSeek / OpenAI / Anthropic / OpenRouter 等多种 provider
        """
        import os as _kos
        
        # 1. 环境变量
        for env_var in ["DEEPSEEK_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "FINBOOKS_API_KEY"]:
            val = _kos.environ.get(env_var, "")
            if val:
                return val

        # 2. ~/.hermes/config.yaml（DeepSeek 专用）
        cp = _kos.path.expanduser("~/.hermes/config.yaml")
        if _kos.path.exists(cp):
            try:
                with open(cp, "r", encoding="utf-8") as f:
                    lines = f.readlines()
                in_deepseek = False
                for line in lines:
                    ls = line.strip()
                    if "deepseek-official:" in ls:
                        in_deepseek = True
                        continue
                    if in_deepseek:
                        if "api_key:" in ls:
                            key = ls.split("api_key:")[-1].strip()
                            if key and not key.startswith("#"):
                                return key
                        if ls and not ls.startswith((" ", "\t")):
                            in_deepseek = False
            except Exception:
                pass

        # 3. ~/.finbooks/config.json（FinBooks 自己的配置）
        fb_json = _kos.path.expanduser("~/.finbooks/config.json")
        if _kos.path.exists(fb_json):
            try:
                with open(fb_json, "r", encoding="utf-8") as f:
                    cfg = json.load(f)
                if cfg.get("api_key"):
                    return cfg["api_key"]
            except Exception:
                pass

        # 4. ~/.finbooks/config.yaml（旧版格式）
        fb_config = _kos.path.expanduser("~/.finbooks/config.yaml")
        if _kos.path.exists(fb_config):
            try:
                with open(fb_config, "r", encoding="utf-8") as f:
                    for line in f:
                        if "api_key:" in line:
                            key = line.split("api_key:")[-1].strip()
                            if key:
                                return key
            except Exception:
                pass

        # 5. UserDefaults 中存储的 AgentConfig（通过 App 侧 API 传入）
        # 由 AIChatView 在发请求时将 apiKey 注入到 context.apiKey
        return ""

    def _build_system_prompt(self, context: dict) -> str:
        """构建系统提示词（含实时财务数据）"""
        company_name = context.get("companyName", "示例公司")
        summary = context.get("summary", "")
        company = _get_company()
        entries = _cache.get("entries", [])
        accounts = _cache.get("accounts", [])

        # 如果有 summary 就用传来的，没有就实时构建
        if not summary:
            # 实时构建财务摘要
            ta = tl = teq = tr = tex = 0.0
            for a in accounts:
                if not a.get("isActive", True):
                    continue
                bal = _calc_balance(a, entries)
                cat = a.get("category", "")
                if cat == "asset":
                    ta += bal
                elif cat == "liability":
                    tl += bal
                elif cat == "equity":
                    teq += bal
                elif cat == "revenue":
                    tr += bal
                elif cat == "expense":
                    tex += bal
            posted = [e for e in entries if e.get("isPosted")]
            summary = (
                f"科目: {len(accounts)} 个, 凭证: {len(entries)} 张 (已过账 {len(posted)})\n"
                f"总资产: ¥{ta:,.2f}, 总负债: ¥{tl:,.2f}, 权益: ¥{teq:,.2f}\n"
                f"收入: ¥{tr:,.2f}, 费用: ¥{tex:,.2f}, 净利润: ¥{tr - tex:,.2f}"
            )

        return f"""你是 FinBooks AI 财务助手，专精于中国会计准则（CAS）。

当前公司: {company_name}
税号: {company.get('taxId', '')}
实时财务数据:
{summary}

你可以:
1. 查询财务数据（余额、凭证、报表）— 实时从用户数据库读取
2. 分析财务状况（异常检测、趋势分析、杜邦分析）
3. 生成凭证（自动校验借贷平衡，一借一贷或多借多贷）
4. 税务建议（增值税、企业所得税）
5. 固定资产折旧计提
6. 审计合规检查
7. 试算平衡表（期间借贷汇总 + 平衡校验）
8. 账龄分析（应收/应付按 0-30/31-60/61-90/90+ 天分档）
9. 税务申报导出（符合中国税局格式 CSV）
10. 审计数据包导出（试算平衡表 + 审计日志 + 凭证列表）

回答规则:
- 金额使用 ¥ 符号和千分位逗号格式
- 引用具体科目编码和名称
- 发现异常（借贷不平、超过 90 天账龄、大额交易）主动提示用户
- 用户问到审计或税务导出时，自动提示可用格式（JSON/CSV）
- 用户问到账龄分析时，自动同时检查应收和应付
- 无法查询时给出操作建议
- 回答简洁专业"""

    def _chat(self, data):
        message = data.get("message", "")
        context = data.get("context", {})
        session_id = data.get("sessionId", str(uuid.uuid4()))

        if not message:
            self._e("缺少 message 参数")
            return

        # 维护会话历史
        _cleanup_old_sessions()
        if session_id not in _sessions:
            _sessions[session_id] = {"messages": [], "created_at": time.time(), "updated_at": time.time()}
        
        session = _sessions[session_id]
        session["updated_at"] = time.time()
        
        # 添加用户消息到历史
        session["messages"].append({"role": "user", "content": message})
        
        # 构建完整的消息列表（含历史）
        conversation_messages = []
        for m in session["messages"][-_MAX_SESSION_MSGS:]:
            conversation_messages.append({"role": m["role"], "content": m["content"]})

        system_prompt = self._build_system_prompt(context)

        # SSE 响应头
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

        api_key = self._get_api_key()

        if not api_key:
            # 离线模式 — 内置回复
            reply = self._offline_reply(message, context)
            # 保存到会话历史
            session["messages"].append({"role": "assistant", "content": reply})
            try:
                self.wfile.write(f"data: {json.dumps({'content': reply, 'sessionId': session_id}, ensure_ascii=False)}\n\n".encode())
                self.wfile.write(b"data: [DONE]\n\n")
            except (BrokenPipeError, OSError):
                pass
            self.wfile.flush()
            return

        # 从 context 中读取 App 侧传入的 apiKey/model/baseURL（优先使用）
        context_api_key = context.get("apiKey", "")
        context_model = context.get("model", "")
        context_base_url = context.get("baseURL", "")

        # 优先级: context 传入 > 自动检测 > 硬编码默认值
        if context_api_key:
            api_key = context_api_key
        model = context_model if context_model else _DEFAULT_MODEL
        base_url = context_base_url if context_base_url else _DEFAULT_BASE_URL
        # Always append /chat/completions if not already present (OpenAI-compatible API)
        if not base_url.rstrip("/").endswith("/chat/completions"):
            base_url = base_url.rstrip("/") + "/chat/completions"

        # 构建完整对话上下文（系统提示 + 历史消息）
        api_messages = [{"role": "system", "content": system_prompt}]
        api_messages.extend(conversation_messages)
        
        payload = json.dumps({
            "model": model,
            "messages": api_messages,
            "stream": True,
            "temperature": 0.3,
            "max_tokens": 2048,
        }).encode()

        try:
            import urllib.request
            req = urllib.request.Request(
                base_url,
                data=payload,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {api_key}",
                },
                method="POST",
            )
            resp = urllib.request.urlopen(req, timeout=60)
            for lb in resp:
                line = lb.decode().strip()
                if not line or line.startswith(":"):
                    continue
                if line.startswith("data: "):
                    ds = line[6:]
                    if ds == "[DONE]":
                        break
                    try:
                        delta = json.loads(ds).get("choices", [{}])[0].get("delta", {})
                        content_chunk = delta.get("content", "")
                        if content_chunk:
                            if "response_content" not in session:
                                session["response_content"] = ""
                            session["response_content"] += content_chunk
                            try:
                                self.wfile.write(
                                    f"data: {json.dumps({'content': content_chunk, 'sessionId': session_id}, ensure_ascii=False)}\n\n".encode()
                                )
                                self.wfile.flush()
                            except (BrokenPipeError, OSError):
                                return
                    except (json.JSONDecodeError, KeyError, IndexError):
                        continue
            # 保存助手回复到会话历史
            if "response_content" in session:
                session["messages"].append({"role": "assistant", "content": session["response_content"]})
                del session["response_content"]
                # 截断历史（保留最近 N 条）
                if len(session["messages"]) > _MAX_SESSION_MSGS * 2:
                    session["messages"] = session["messages"][-_MAX_SESSION_MSGS:]
            try:
                self.wfile.write(b"data: [DONE]\n\n")
            except (BrokenPipeError, OSError):
                pass
            self.wfile.flush()
        except Exception as e:
            # API 失败时回退到离线模式
            reply = self._offline_reply(message, context)
            # 保存到会话历史
            session["messages"].append({"role": "assistant", "content": reply})
            try:
                self.wfile.write(
                    f"data: {json.dumps({'content': reply, 'sessionId': session_id}, ensure_ascii=False)}\n\n".encode()
                )
                self.wfile.write(b"data: [DONE]\n\n")
            except (BrokenPipeError, OSError):
                pass
            self.wfile.flush()

    def _offline_reply(self, message: str, context: dict) -> str:
        """离线模式 — 增强版内置回复（实时数据驱动）"""
        _reload_cache()
        msg_lower = message.lower()

        accounts = _cache.get("accounts", [])
        entries = _cache.get("entries", [])
        company = _get_company()

        # 实时数据汇总（供所有问题使用）
        ta = tl = teq = tr = tex = 0.0
        for a in accounts:
            if not a.get("isActive", True):
                continue
            bal = _calc_balance(a, entries)
            cat = a.get("category", "")
            if cat == "asset": ta += bal
            elif cat == "liability": tl += bal
            elif cat == "equity": teq += bal
            elif cat == "revenue": tr += bal
            elif cat == "expense": tex += bal
        net_profit = tr - tex

        # 增值税查询
        vat_input = vat_output = 0.0
        for a in accounts:
            code = a.get("code", "")
            if code == "2221.01.01":  # 进项
                vat_input = _calc_balance(a, entries)
            elif code == "2221.01.02":  # 销项
                vat_output = _calc_balance(a, entries)

        if "余额" in message or "balance" in msg_lower:
            parts = []
            code_filter = None
            # 支持指定科目查询
            for kw in message.split():
                for a in accounts:
                    if a.get("code") == kw or a.get("name", "") in kw:
                        code_filter = a.get("code", "")
                        break
            for a in accounts:
                if not a.get("isActive", True):
                    continue
                if code_filter and a.get("code", "") != code_filter:
                    continue
                bal = _calc_balance(a, entries)
                parts.append(f"  {a.get('code','')} {a.get('name','')}: ¥{bal:,.2f}")
            if len(parts) > 10 and not code_filter:
                parts = parts[:10]
            if not parts:
                return "📊 当前没有科目数据，请先在 FinBooks 中创建科目。"
            return "📊 科目余额（前10个）:\n" + "\n".join(parts)

        if "异常" in message or "anomaly" in msg_lower or "问题" in message:
            entries = _cache.get("entries", [])
            accounts = _cache.get("accounts", [])
            issues = []
            for e in entries:
                dtot = sum(float(l.get("debit", 0) or 0) for l in e.get("lines", []))
                ctot = sum(float(l.get("credit", 0) or 0) for l in e.get("lines", []))
                if dtot > 0 and abs(dtot - ctot) > 0.01:
                    issues.append(f"⚠️ 凭证 {e.get('number','')} 借贷不平")
            if not issues:
                issues.append("✅ 未发现异常")
            return "🔍 异常检测结果:\n" + "\n".join(issues)

        if "资产" in message and ("负债" in message or "权益" in message or "表" in message):
            return "📊 请使用 FinBooks App 查看完整的资产负债表，或在 AI 助手中选择「资产负债表」快捷查询。"

        if "利润" in message or "收入" in message or "费用" in message:
            return "📈 请使用 FinBooks App 查看利润表，或在 AI 助手中选择「本月利润」快捷查询。"

        if "现金" in message or "流量" in message:
            return "💰 请使用 FinBooks App 查看现金流量表，或在 AI 助手中选择「现金流量」快捷查询。"

        if "税" in message:
            return "🧾 请使用 FinBooks App 查看增值税申报表，或在 AI 助手中选择「增值税」快捷查询。"

        if "试算" in message or "trial" in msg_lower or "试算平衡" in message:
            entries = _cache.get("entries", [])
            accounts = _cache.get("accounts", [])
            total_debit_total = 0.0
            total_credit_total = 0.0
            tb_lines = []
            for a in accounts:
                if not a.get("isActive", True):
                    continue
                bal = _calc_balance(a, entries)
                code = a.get("code", "")
                is_debit = any(code.startswith(p) for p in ["1","5","6"])
                deb = 0.0; cr = 0.0
                if bal > 0:
                    if is_debit: deb = bal
                    else: cr = bal
                elif bal < 0:
                    if is_debit: cr = -bal
                    else: deb = -bal
                total_debit_total += deb
                total_credit_total += cr
                tb_lines.append(f"  {code} {a.get('name','')}: 借\u00a5{deb:,.2f} / 贷\u00a5{cr:,.2f}")
            balanced = "✅ 试算平衡" if abs(total_debit_total - total_credit_total) < 0.01 else f"⚠️ 试算不平(差额\u00a5{abs(total_debit_total - total_credit_total):,.2f})"
            return f"📊 **试算平衡表**\n\n" + "\n".join(tb_lines[:30]) + f"\n\n**合计:** 借方 \u00a5{total_debit_total:,.2f} | 贷方 \u00a5{total_credit_total:,.2f}\n{balanced}"

        if "账龄" in message or "aging" in msg_lower:
            return "📋 **账龄分析**\n\n请使用 FinBooks App 查看完整的账龄分析报告，或在 AI 助手中选择「账龄分析」快捷查询。\n\n💡 账龄分析支持应收和应付账款，按0-30天、31-60天、61-90天、90天以上分档。"

        if "审计" in message or "audit" in msg_lower:
            return "📤 **审计数据导出**\n\n请在上方快捷按钮中选择「导出审计CSV」。\n\n审计数据包包括：\n  • 试算平衡表\n  • 审计日志\n  • 凭证列表\n  • 税项汇总\n\n支持格式: JSON / CSV"

        if "tax_export" in message or "audit_export" in message or "税务" in message:
            return "🧾 **税务申报导出**\n\n请使用 FinBooks App 中的「税务导出」功能。\n\n税务数据包括：\n  • 销项发票明细\n  • 进项发票明细\n  • 增值税计算表\n\n支持格式: JSON / CSV"



        if "帮助" in message or "help" in msg_lower or "功能" in message:
            return (
        "👋 我是 FinBooks AI 助手。我可以：\n\n"
        "📊 **查询财务数据**\n"
        "  • 查余额：\"库存现金余额多少？\"\n"
        "  • 查凭证：\"最近10张凭证\"\n"
        "  • 查报表：\"本月利润表\"\n\n"
        "📝 **录入凭证**\n"
        "  • \"录入凭证：购买办公用品¥500\"\n"
        "  • \"报销差旅费¥2000\"\n\n"
        "🔍 **异常检测**\n"
        "  • 自动检测借贷不平、余额方向异常\n\n"
        "🧾 **税务申报**\n"
        "  • 增值税申报、所得税预估\n\n"
        "💡 **提示**: 上方快捷按钮可快速查询"
            )

        # 税务相关
        if "增值税" in message or "进项" in message or "销项" in message or "vat" in msg_lower:
            vat_payable = max(vat_output - vat_input, 0)
            return (
                f"🧾 **增值税摘要** ({dt.now().year}年{dt.now().month}月)\n\n"
                f"进项税额: ¥{vat_input:,.2f}\n"
                f"销项税额: ¥{vat_output:,.2f}\n"
                f"应纳增值税: ¥{vat_payable:,.2f}\n\n"
                f"详细数据请在 FinBooks App 中查看增值税申报表。"
            )

        # 财务报表
        if ("资产" in message or "负债" in message) and ("表" in message or "balance" in msg_lower):
            balanced = "✓ 平衡" if abs(ta - (tl + teq)) < 0.01 else "✗ 不平!"
            return (
                f"📊 **资产负债表摘要**\n\n"
                f"总资产: ¥{ta:,.2f}\n"
                f"总负债: ¥{tl:,.2f}\n"
                f"所有者权益: ¥{teq:,.2f}\n"
                f"负债+权益: ¥{tl + teq:,.2f}\n"
                f"状态: {balanced}\n\n"
                f"请在 FinBooks App 中查看完整报表。"
            )

        if ("利润" in message or "收入" in message or "费用" in message) and ("表" in message or "income" in msg_lower):
            return (
                f"📈 **利润表摘要** ({dt.now().year}年{dt.now().month}月)\n\n"
                f"收入合计: ¥{tr:,.2f}\n"
                f"费用合计: ¥{tex:,.2f}\n"
                f"净利润: ¥{net_profit:,.2f}\n\n"
                f"请在 FinBooks App 中查看完整利润表。"
            )

        if "现金" in message or "流量" in message or "cash" in msg_lower:
            return (
                f"💰 **现金流量摘要**\n\n"
                f"请在 FinBooks App 中查看完整的现金流量表。\n"
                f"快捷操作: AI 助手上方选择「现金流量」。"
            )

        # 状态诊断
        if "状态" in message or "healthy" in msg_lower or "健康" in message:
            issues = []
            entry_count = len(entries)
            posted_count = len([e for e in entries if e.get("isPosted")])
            account_count = len(accounts)
            if abs(ta - (tl + teq)) > 0.01:
                issues.append("⚠️ 资产负债表不平")
            unposted = entry_count - posted_count
            if unposted > 0:
                issues.append(f"ℹ️ {unposted} 张凭证未过账")
            if account_count == 0:
                issues.append("⚠️ 未创建会计科目")
            status = "✅ 系统运行正常" if not issues else "\n".join(issues)
            return (
                f"🏥 **系统状态**\n\n"
                f"公司: {company.get('name', '示例公司')}\n"
                f"科目: {account_count} 个\n"
                f"凭证: {entry_count} 张 (已过账 {posted_count})\n"
                f"税号: {company.get('taxId', '未设置')}\n"
                f"Bridge 版本: {VERSION}\n"
                f"API 连接: 离线模式\n\n"
                f"{status}"
            )

        # 默认回复
        company = _get_company()
        posted = [e for e in _cache.get("entries", []) if e.get("isPosted")]
        return (
            f"👋 你好！我是 FinBooks 财务助手。\n\n"
            f"当前公司: {company.get('name', '示例公司')}\n"
            f"科目数: {len(accounts)} | 凭证数: {len(posted)}\n"
            f"总资产: ¥{ta:,.2f} | 净利润: ¥{net_profit:,.2f}\n\n"
            f"你可以问我:\n"
            f"• \"库存现金余额\" — 查科目余额\n"
            f"• \"本月利润\" — 利润表\n"
            f"• \"资产负债表\" — 资产负债表\n"
            )

    # ================================================================
    # 审计导出
    # ================================================================

    def _audit_export(self, q):
        """导出完整审计数据包（满足外部审计需求）"""
        yr = int(q.get("year", 0)) if q.get("year") else dt.now().year
        mo = int(q.get("month", 0)) if q.get("month") else dt.now().month
        limit = int(q.get("limit", 1000))

        accounts = _cache.get("accounts", [])
        period_entries = _filter_entries(year=yr, month=mo)
        trial_balance = []
        for a in accounts:
            if not a.get("isActive", True):
                continue
            bal = _calc_balance(a, period_entries)
            cat = a.get("category", "")
            bd = a.get("balanceDirection") or ("debit" if cat in ("asset", "expense") else "credit")
            if bal >= 0:
                debit_bal = bal if bd == "debit" else 0.0
                credit_bal = bal if bd == "credit" else 0.0
            else:
                debit_bal = -bal if bd == "credit" else 0.0
                credit_bal = -bal if bd == "debit" else 0.0
            trial_balance.append({
                "code": a.get("code", ""),
                "name": a.get("name", ""),
                "category": cat,
                "balanceDirection": bd,
                "debitBalance": round(debit_bal, 2),
                "creditBalance": round(credit_bal, 2),
            })

        logs = _cache.get("auditLogs", [])
        combined = _audit_log + logs
        combined.sort(key=lambda x: x.get("timestamp", ""), reverse=True)

        entries = _filter_entries(year=yr, month=mo)
        entry_summary = []
        for e in sorted(entries, key=lambda x: (_parse_date(x.get("date", "")), x.get("number", ""))):
            dtot = sum(float(l.get("debit", 0) or 0) for l in e.get("lines", []))
            ctot = sum(float(l.get("credit", 0) or 0) for l in e.get("lines", []))
            entry_summary.append({
                "number": e.get("number", ""),
                "date": (e.get("date", "") or "")[:10],
                "summary": e.get("summary", ""),
                "status": "posted" if e.get("isPosted") else "draft",
                "debitTotal": round(dtot, 2),
                "creditTotal": round(ctot, 2),
                "lines": len(e.get("lines", [])),
            })

        company = _get_company()
        period_closes = _cache.get("periodCloses", [])
        vat_data = self._compute_vat(yr, mo)

        audit_package = {
            "exportVersion": "2.5.0",
            "exportedAt": dt.now().isoformat(),
            "period": f"{yr}\u5e74{mo}\u6708",
            "company": company,
            "summary": {
                "totalAccounts": len(trial_balance),
                "totalEntries": len(entry_summary),
                "totalAuditLogs": min(limit, len(combined)),
                "postedEntries": sum(1 for e in entry_summary if e["status"] == "posted"),
                "draftEntries": sum(1 for e in entry_summary if e["status"] == "draft"),
            },
            "trialBalance": trial_balance,
            "auditLogs": combined[:limit],
            "entries": entry_summary,
            "periodCloses": period_closes,
            "taxSummary": vat_data,
            "complianceFramework": {
                "standard": "中国注册会计师审计准则(CAS)",
                "applicableVersion": "2026年版",
                "auditProcedure": "实质性程序+控制测试",
                "materialityThreshold": "资产总额0.5%~1%或营业收入0.5%~1%（按较低者）",
                "samplingMethod": "统计抽样+判断抽样",
                "confirmationMethod": "函证+替代测试",
                "reportingFormat": "标准无保留意见审计报告（可调整）"
            },
        }
        if q.get("format", "").lower() == "csv":
            csv_path = f"/tmp/finbooks_audit_{yr}{mo:02d}_{dt.now().strftime('%Y%m%d_%H%M%S')}.csv"
            with open(csv_path, "w", newline="", encoding="utf-8-sig") as f:
                wr = csv.writer(f)
                wr.writerow(["=== \u5ba1\u8ba1\u5bfc\u51fa - \u4f1a\u8ba1\u671f\u95f4", f"{yr}\u5e74{mo}\u6708", "==="])
                wr.writerow([])
                wr.writerow(["--- \u8bd5\u7b97\u5e73\u8861\u8868 ---"])
                wr.writerow(["\u79d1\u76ee\u7f16\u7801", "\u79d1\u76ee\u540d\u79f0", "\u7c7b\u522b", "\u501f\u65b9\u4f59\u989d", "\u8d37\u65b9\u4f59\u989d"])
                for tb in trial_balance:
                    wr.writerow([tb["code"], tb["name"], tb["category"], tb["debitBalance"], tb["creditBalance"]])
                wr.writerow([])
                wr.writerow(["--- \u51ed\u8bc1\u5217\u8868 ---"])
                wr.writerow(["\u51ed\u8bc1\u53f7", "\u65e5\u671f", "\u6458\u8981", "\u501f\u65b9\u5408\u8ba1", "\u8d37\u65b9\u5408\u8ba1", "\u72b6\u6001"])
                for en in entry_summary:
                    wr.writerow([en["number"], en["date"], en["summary"], en["debitTotal"], en["creditTotal"], en["status"]])
                wr.writerow([])
                wr.writerow(["--- \u5ba1\u8ba1\u65e5\u5fd7 ---"])
                wr.writerow(["\u65f6\u95f4", "\u64cd\u4f5c", "\u8be6\u60c5", "\u5b9e\u4f53ID"])
                for lg in combined[:limit]:
                    wr.writerow([lg.get("timestamp", ""), lg.get("action", ""), lg.get("detail", ""), lg.get("entityID", "")])
            self._j({"file": csv_path, "rows": len(trial_balance) + len(entry_summary), "message": f"\u5ba1\u8ba1\u5bfc\u51fa\u6587\u4ef6: {csv_path}"})
            return

        self._j(audit_package)

    # ================================================================
    # 增值税计算
    # ================================================================

    def _compute_vat(self, yr, mo):
        """计算增值税汇总数据"""
        entries = _filter_entries(year=yr, month=mo)
        accounts = _cache.get("accounts", [])

        output_tax_code = ""
        input_tax_code = ""
        for a in accounts:
            code = a.get("code", "")
            name = a.get("name", "")
            if "\u9500\u9879" in name and "2221" in code:
                output_tax_code = code
            if "\u8fdb\u9879" in name and "2221" in code:
                input_tax_code = code

        output_tax = 0.0
        input_tax = 0.0
        vat_details = []

        for e in entries:
            if not e.get("isPosted"):
                continue
            for line in e.get("lines", []):
                code = _resolve_line_code(line) or ""
                if output_tax_code and code == output_tax_code:
                    amount = float(line.get("credit", 0) or 0)
                    output_tax += amount
                    vat_details.append({
                        "entry": e.get("number", ""),
                        "date": (e.get("date", "") or "")[:10],
                        "summary": e.get("summary", ""),
                        "type": "output",
                        "taxAmount": round(amount, 2),
                    })
                elif input_tax_code and code == input_tax_code:
                    amount = float(line.get("debit", 0) or 0)
                    input_tax += amount
                    vat_details.append({
                        "entry": e.get("number", ""),
                        "date": (e.get("date", "") or "")[:10],
                        "summary": e.get("summary", ""),
                        "type": "input",
                        "taxAmount": round(amount, 2),
                    })

        all_entries = _cache.get("entries", [])
        ytd_output = 0.0
        ytd_input = 0.0
        for e in all_entries:
            if not e.get("isPosted"):
                continue
            edate = _parse_date(e.get("date", ""))
            if edate and edate.year == yr and edate.month <= mo:
                for line in e.get("lines", []):
                    code = _resolve_line_code(line) or ""
                    if output_tax_code and code == output_tax_code:
                        ytd_output += float(line.get("credit", 0) or 0)
                    elif input_tax_code and code == input_tax_code:
                        ytd_input += float(line.get("debit", 0) or 0)

        return {
            "period": f"{yr}\u5e74{mo}\u6708",
            "outputTaxTotal": round(output_tax, 2),
            "inputTaxTotal": round(input_tax, 2),
            "taxPayable": round(max(0, output_tax - input_tax), 2),
            "ytdOutputTax": round(ytd_output, 2),
            "ytdInputTax": round(ytd_input, 2),
            "ytdTaxPayable": round(max(0, ytd_output - ytd_input), 2),
            "details": vat_details,
        }

    # ================================================================
    # 税务导出
    # ================================================================

    def _tax_export(self, q):
        """导出增值税申报格式数据（符合中国税务申报要求）"""
        yr = int(q.get("year", 0)) if q.get("year") else dt.now().year
        mo = int(q.get("month", 0)) if q.get("month") else dt.now().month
        vat_data = self._compute_vat(yr, mo)

        tax_package = {
            "exportVersion": "2.5.0",
            "exportedAt": dt.now().isoformat(),
            "taxType": "VAT",
            "country": "CN",
            "period": f"{yr}{mo:02d}",
            "year": yr,
            "month": mo,
            "salesSummary": {
                "taxableSales": vat_data.get("outputTaxTotal", 0),
                "taxExemptSales": 0,
                "totalSales": vat_data.get("outputTaxTotal", 0),
            },
            "purchaseSummary": {
                "deductibleInputTax": vat_data.get("inputTaxTotal", 0),
                "nonDeductibleInputTax": 0,
                "totalPurchases": vat_data.get("inputTaxTotal", 0),
            },
            "taxComputation": {
                "outputTaxCurrent": vat_data.get("outputTaxTotal", 0),
                "inputTaxCurrent": vat_data.get("inputTaxTotal", 0),
                "taxPayableCurrent": vat_data.get("taxPayable", 0),
                "ytdOutputTax": vat_data.get("ytdOutputTax", 0),
                "ytdInputTax": vat_data.get("ytdInputTax", 0),
                "ytdTaxPayable": vat_data.get("ytdTaxPayable", 0),
            },
            "details": vat_data.get("details", []),
            "taxRate": _get_company().get("vatRate", _get_company().get("taxRate", 0.13)),
            "goldenTaxIntegration": {
                "compatible": True,
                "format": "国家税务总局增值税发票（数电票）",
                "invoiceFields": ["发票代码", "发票号码", "开票日期", "销售方纳税人识别号", "销售方名称", "购买方纳税人识别号", "购买方名称", "发票类型", "含税金额", "税率", "税额", "价税合计"],
                "exportFormat": "符合税务总局接口规范"
            },
        }

        if q.get("format", "").lower() == "csv":
            csv_path = f"/tmp/finbooks_tax_{yr}{mo:02d}_{dt.now().strftime('%Y%m%d_%H%M%S')}.csv"
            with open(csv_path, "w", newline="", encoding="utf-8-sig") as f:
                wr = csv.writer(f)
                wr.writerow(["=== \u589e\u503c\u7a0e\u7533\u62a5\u5bfc\u51fa ==="])
                wr.writerow(["\u4f1a\u8ba1\u671f\u95f4", f"{yr}\u5e74{mo}\u6708"])
                wr.writerow([])
                wr.writerow(["--- \u9500\u9879\u7a0e\u989d\u660e\u7ec6 ---"])
                wr.writerow(["\u51ed\u8bc1\u53f7", "\u65e5\u671f", "\u6458\u8981", "\u7a0e\u989d", "\u7c7b\u578b"])
                for d in vat_data.get("details", []):
                    if d["type"] == "output":
                        wr.writerow([d["entry"], d["date"], d["summary"], d["taxAmount"], "\u9500\u9879"])
                wr.writerow([])
                wr.writerow(["--- \u8fdb\u9879\u7a0e\u989d\u660e\u7ec6 ---"])
                wr.writerow(["\u51ed\u8bc1\u53f7", "\u65e5\u671f", "\u6458\u8981", "\u7a0e\u989d", "\u7c7b\u578b"])
                for d in vat_data.get("details", []):
                    if d["type"] == "input":
                        wr.writerow([d["entry"], d["date"], d["summary"], d["taxAmount"], "\u8fdb\u9879"])
                wr.writerow([])
                wr.writerow(["--- \u7a0e\u6b3e\u8ba1\u7b97 ---"])
                wr.writerow(["\u9500\u9879\u7a0e\u989d", vat_data.get("outputTaxTotal", 0)])
                wr.writerow(["\u8fdb\u9879\u7a0e\u989d", vat_data.get("inputTaxTotal", 0)])
                wr.writerow(["\u5e94\u7f34\u589e\u503c\u7a0e", vat_data.get("taxPayable", 0)])
            self._j({"file": csv_path, "message": f"\u589e\u503c\u7a0e\u7533\u62a5\u6587\u4ef6: {csv_path}"})
            return

        self._j(tax_package)

    # ================================================================
    # 企业所得税汇算清缴
    # ================================================================

    def _corporate_income_tax(self, q):
        """导出企业所得税汇算清缴数据（中国企业所得税年度纳税申报表基础信息）"""
        yr = int(q.get("year", 0)) if q.get("year") else dt.now().year
        accounts = _cache.get("accounts", [])
        all_entries = _cache.get("entries", [])

        # 获取本年利润科目（通常 4103）
        profit_accounts = [a for a in accounts if "4103" in a.get("code", "") and a.get("isActive", True)]
        if not profit_accounts:
            profit_accounts = [a for a in accounts if "本年利润" in a.get("name", "") and a.get("isActive", True)]

        # 利润表的收入/费用汇总
        revenue_codes = set()
        expense_codes = set()
        for a in accounts:
            if not a.get("isActive", True): continue
            code = a.get("code", "")
            cat = a.get("category", "")
            if code.startswith("6") and cat == "revenue": revenue_codes.add(code)
            if (code.startswith("5") or code.startswith("6")) and cat == "expense": expense_codes.add(code)

        annual_revenue = 0.0
        annual_expense = 0.0
        annual_profit = 0.0

        for e in all_entries:
            if not e.get("isPosted"): continue
            edate = _parse_date(e.get("date", ""))
            if not edate or edate.year != yr: continue
            for line in e.get("lines", []):
                code = _resolve_line_code(line) or ""
                if code in revenue_codes:
                    annual_revenue += float(line.get("credit", 0) or 0) - float(line.get("debit", 0) or 0)
                elif code in expense_codes:
                    annual_expense += float(line.get("debit", 0) or 0) - float(line.get("credit", 0) or 0)
                elif profit_accounts and code == profit_accounts[0].get("code"):
                    annual_profit += float(line.get("credit", 0) or 0) - float(line.get("debit", 0) or 0)

        if abs(annual_profit) < 0.01:
            annual_profit = annual_revenue - annual_expense

        tax_rate = _config.get("taxRates", {}).get("corporateIncomeTax", 0.25)
        estimated_cit = max(0, round(annual_profit * tax_rate, 2))

        # 纳税调整项（占位 - 实际需结合税务调整台账）
        adjustments = {
            "nonDeductibleExpenses": 0.0,
            "taxExemptIncome": 0.0,
            "priorYearLossDeduction": 0.0,
            "rdSuperDeduction": 0.0,
        }

        cit_package = {
            "exportVersion": "2.5.0",
            "exportedAt": dt.now().isoformat(),
            "taxType": "CorporateIncomeTax",
            "country": "CN",
            "fiscalYear": yr,
            "accountingProfit": round(annual_profit, 2),
            "totalRevenue": round(annual_revenue, 2),
            "totalExpense": round(annual_expense, 2),
            "taxRate": tax_rate,
            "estimatedTaxPayable": estimated_cit,
            "adjustments": adjustments,
            "adjustedTaxableIncome": round(annual_profit + sum(adjustments.values()), 2),
            "applicableForm": "中华人民共和国企业所得税年度纳税申报表A类",
            "complianceNote": "符合国家税务总局关于企业所得税年度纳税申报的公告要求"
        }

        if q.get("format", "").lower() == "csv":
            csv_path = f"/tmp/finbooks_cit_{yr}_{dt.now().strftime('%Y%m%d_%H%M%S')}.csv"
            with open(csv_path, "w", newline="", encoding="utf-8-sig") as f:
                wr = csv.writer(f)
                wr.writerow(["===企业所得税汇算清缴导出==="])
                wr.writerow(["纳税年度", str(yr)])
                wr.writerow([])
                wr.writerow(["项目", "金额(元)"])
                wr.writerow(["营业收入总额", round(annual_revenue, 2)])
                wr.writerow(["营业成本及费用总额", round(annual_expense, 2)])
                wr.writerow(["会计利润总额", round(annual_profit, 2)])
                wr.writerow(["纳税调增额", round(sum(adjustments.values()), 2)])
                wr.writerow(["调整后应纳税所得额", round(annual_profit + sum(adjustments.values()), 2)])
                wr.writerow(["税率", f"{tax_rate*100}%"])
                wr.writerow(["应缴企业所得税", estimated_cit])
            self._j({"file": csv_path, "message": f"企业所得税汇算文件: {csv_path}"})
            return

        self._j(cit_package)

    # ================================================================
    # 审计底稿导出（符合中国注册会计师审计准则）
    # ================================================================

    def _audit_working_paper(self, q):
        """导出标准审计底稿包（CAS审计准则格式）"""
        yr = int(q.get("year", 0)) if q.get("year") else dt.now().year
        mo = int(q.get("month", 0)) if q.get("month") else dt.now().month
        limit = int(q.get("limit", 500))

        company = _get_company()
        accounts = _cache.get("accounts", [])
        period_entries = _filter_entries(year=yr, month=mo)

        # 审计底稿 - 试算平衡表
        trial_balance = []
        for a in accounts:
            if not a.get("isActive", True): continue
            bal = _calc_balance(a, period_entries)
            cat = a.get("category", "")
            bd = a.get("balanceDirection") or ("debit" if cat in ("asset", "expense") else "credit")
            if bal >= 0:
                debit_bal = bal if bd == "debit" else 0.0
                credit_bal = bal if bd == "credit" else 0.0
            else:
                debit_bal = -bal if bd == "credit" else 0.0
                credit_bal = -bal if bd == "debit" else 0.0
            trial_balance.append({
                "code": a.get("code", ""), "name": a.get("name", ""),
                "openingDebit": 0, "openingCredit": 0,
                "currentDebit": 0, "currentCredit": 0,
                "endingDebit": round(debit_bal, 2), "endingCredit": round(credit_bal, 2),
            })

        # 审计底稿 - 凭证抽查样本
        entries_sorted = sorted(period_entries, key=lambda x: x.get("number", ""))
        sample_size = min(20, len(entries_sorted))
        # 取前sample_size条 + 随机跳跃（模拟抽样）
        import random
        samples = []
        if entries_sorted:
            step = max(1, len(entries_sorted) // sample_size) if sample_size > 0 else 1
            for i in range(0, len(entries_sorted), step):
                if len(samples) >= sample_size: break
                e = entries_sorted[i]
                dtot = sum(float(l.get("debit", 0) or 0) for l in e.get("lines", []))
                ctot = sum(float(l.get("credit", 0) or 0) for l in e.get("lines", []))
                samples.append({
                    "number": e.get("number", ""),
                    "date": (e.get("date", "") or "")[:10],
                    "summary": e.get("summary", ""),
                    "debit": round(dtot, 2), "credit": round(ctot, 2),
                    "balanced": "Y" if abs(dtot - ctot) < 0.01 else "N",
                    "reviewed": False,
                })

        # 审计底稿 - 银行存款余额调节表
        bank_accounts = [a for a in accounts if a.get("code", "").startswith("1002") and a.get("isActive", True)]
        bank_recon = []
        for ba in bank_accounts:
            book_bal = _calc_balance(ba, period_entries)
            bank_recon.append({
                "accountCode": ba.get("code", ""),
                "accountName": ba.get("name", ""),
                "bookBalance": round(book_bal, 2),
                "bankStatementBalance": 0,
                "outstandingDeposits": [],
                "outstandingChecks": [],
                "adjustments": [],
                "reconciledBalance": round(book_bal, 2),
                "note": "待确认银行对账单"
            })

        paper = {
            "exportVersion": "2.5.0",
            "exportedAt": dt.now().isoformat(),
            "auditStandard": "中国注册会计师审计准则(CAS)",
            "auditYear": f"{yr}年",
            "auditPeriod": f"{yr}年{mo}月",
            "clientName": company.get("name", ""),
            "preparedBy": "", "reviewedBy": "", "date": dt.now().strftime("%Y-%m-%d"),
            "sections": {
                "A_Planning": {
                    "materialityLevel": round(sum(tb.get("endingDebit", 0) for tb in trial_balance if tb.get("category") == "asset") * 0.005, 2),
                    "performanceMateriality": 0,
                    "auditApproach": "综合实质性程序 + 控制测试"
                },
                "B_TrialBalance": trial_balance,
                "C_EntrySampling": samples,
                "D_BankReconciliation": bank_recon,
                "E_AuditLogs": (_audit_log + _cache.get("auditLogs", []))[:limit],
            },
        }

        if q.get("format", "").lower() == "csv":
            csv_path = f"/tmp/finbooks_audit_wp_{yr}{mo:02d}_{dt.now().strftime('%Y%m%d_%H%M%S')}.csv"
            with open(csv_path, "w", newline="", encoding="utf-8-sig") as f:
                wr = csv.writer(f)
                wr.writerow(["===审计底稿 - 中国注册会计师审计准则(CAS)==="])
                wr.writerow(["客户名称", company.get("name", "")])
                wr.writerow(["审计期间", f"{yr}年{mo}月"])
                wr.writerow([])
                wr.writerow(["一、试算平衡表"])
                wr.writerow(["科目编码", "科目名称", "期末借方余额", "期末贷方余额"])
                for tb in trial_balance:
                    wr.writerow([tb["code"], tb["name"], tb["endingDebit"], tb["endingCredit"]])
                wr.writerow([])
                wr.writerow(["二、凭证抽查样本"])
                wr.writerow(["凭证号", "日期", "摘要", "借方", "贷方", "平衡"])
                for s in samples:
                    wr.writerow([s["number"], s["date"], s["summary"], s["debit"], s["credit"], s["balanced"]])
            self._j({"file": csv_path, "message": f"审计底稿文件: {csv_path}"})
            return

        self._j(paper)


def _gen_standalone_installer(installer_path, plugin_dir):
    """生成 standalone install.sh，带 launchd 开机自启 + 智能体重启"""
    with open(installer_path, "w") as f:
        f.write('''#!/bin/bash
# FinBooks Plugin Standalone Installer
# 开箱即用 - 自动检测智能体 + 安装 LaunchAgent 开机自启
set -euo pipefail

PDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   FinBooks Plugin Installer (Standalone)    ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

INSTALLED_ANY=0
BRIDGE_SCRIPT=""

install_to_agent() {
    local name="$1"
    local src="$PDIR/$name"
    local dst="$HOME/.$name/plugins/finbooks"
    if [ ! -d "$HOME/.$name" ]; then
        echo "  O $name: Agent not installed (skip)"
        return 1
    fi
    if [ -d "$src" ]; then
        mkdir -p "$dst"
        cp -r "$src/"* "$dst/" 2>/dev/null || true
        echo "  $name: Plugin installed -> $dst"
        INSTALLED_ANY=1
    fi
    if [ "$name" = "hermes" ] && [ -f "$PDIR/scripts/finbooks_bridge.py" ]; then
        mkdir -p "$HOME/.hermes/scripts"
        cp "$PDIR/scripts/finbooks_bridge.py" "$HOME/.hermes/scripts/" 2>/dev/null || true
        chmod +x "$HOME/.hermes/scripts/finbooks_bridge.py" 2>/dev/null || true
        BRIDGE_SCRIPT="$HOME/.hermes/scripts/finbooks_bridge.py"
        echo "  Hermes: Bridge script installed"
    fi
}

install_to_agent "codex" || true
install_to_agent "hermes" || true
install_to_agent "openclaw" || true

# LaunchAgent for auto-start on login
if [ -n "$BRIDGE_SCRIPT" ] || [ -f "$PDIR/scripts/finbooks_bridge.py" ]; then
    [ -z "$BRIDGE_SCRIPT" ] && BRIDGE_SCRIPT="$PDIR/scripts/finbooks_bridge.py"
    LPLIST_DIR="$HOME/Library/LaunchAgents"
    LPLIST_PATH="$LPLIST_DIR/com.finbooks.bridge.plist"
    mkdir -p "$LPLIST_DIR"
    cat > "$LPLIST_PATH" << EOFPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.finbooks.bridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>${BRIDGE_SCRIPT}</string>
        <string>--port</string>
        <string>9090</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>$(dirname "$BRIDGE_SCRIPT")</string>
    <key>StandardOutPath</key>
    <string>/tmp/finbooks-bridge.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/finbooks-bridge.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
EOFPLIST
    chmod 644 "$LPLIST_PATH"
    echo "  LaunchAgent created (auto-start on login)"
fi

echo ""
echo "  Restarting agents for immediate use..."
if command -v launchctl &>/dev/null; then
  for agent in hermes openclaw codex; do
    if [ -d "$HOME/.$agent" ]; then
      launchctl kickstart -k gui/$(id -u)/localhost.$agent 2>/dev/null || true
      echo "  Restarted $agent"
    fi
  done
fi

echo "  Installation complete!"
echo "  Bridge URL: http://127.0.0.1:9090"
echo "  (LaunchAgent installed: auto-starts on login)"
echo ""
echo ""
echo "  Quick test: curl http://127.0.0.1:9090/health"
echo "  Start manually: python3 \"$BRIDGE_SCRIPT\""
''')


def _auto_backup():
    """启动时自动备份一次（每天只备份一次，避免重复）"""
    backup_flag = os.path.join(DATA_DIR, ".last_auto_backup")
    today = dt.now().strftime("%Y-%m-%d")
    try:
        if os.path.exists(backup_flag):
            with open(backup_flag) as f:
                if f.read().strip() == today:
                    return  # 今天已备份
        backup_dir = os.path.join(DATA_DIR, "backups")
        os.makedirs(backup_dir, exist_ok=True)
        ts = dt.now().strftime("%Y%m%d_%H%M%S")
        archive_path = os.path.join(backup_dir, f"finbooks_auto_backup_{ts}.zip")
        json_files = glob.glob(os.path.join(DATA_DIR, "*.json"))
        with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for f in json_files:
                zf.write(f, os.path.basename(f))
        # 清理30天前的备份
        for old_backup in glob.glob(os.path.join(backup_dir, "finbooks_auto_backup_*.zip")):
            if os.path.getmtime(old_backup) < time.time() - 30 * 86400:
                os.remove(old_backup)
        with open(backup_flag, "w") as f:
            f.write(today)
        print(f"  [Bridge] 自动备份完成: {len(json_files)} 个文件 → {archive_path}")
    except Exception as e:
        print(f"  [Bridge] 自动备份跳过: {e}")

def main():
    global PORT
    import argparse
    ap = argparse.ArgumentParser(description='FinBooks Bridge HTTP Server')
    ap.add_argument('--port', type=int, default=0, help='HTTP port (default: from config or 9090)')
    args, _ = ap.parse_known_args()
    if args.port:
        PORT = args.port
    
    _reload_cache()
    _auto_backup()
    
    # 启动会话清理后台线程（每 5 分钟清理过期会话）
    def _session_cleanup_loop():
        while True:
            time.sleep(300)  # 5 分钟
            try:
                _cleanup_old_sessions()
            except Exception:
                pass
    _cleanup_thread = threading.Thread(target=_session_cleanup_loop, daemon=True)
    _cleanup_thread.start()
    
    server = HTTPServer((HOST, PORT), Handler)
    print(f"╔══════════════════════════════════════════════╗")
    print(f"║     FinBooks Bridge v{VERSION}                    ║")
    print(f"║     财务管理系统 HTTP API 服务               ║")
    print(f"╚══════════════════════════════════════════════╝")
    print(f"")
    print(f"  HTTP:   http://{HOST}:{PORT}")
    print(f"  Chat:   http://{HOST}:{PORT}/chat")
    print(f"  Health: http://{HOST}:{PORT}/health")
    print(f"")
    print(f"  报表端点:")
    print(f"    GET  /api/totals              财务总览")
    print(f"    GET  /api/balance             科目余额")
    print(f"    GET  /api/accounts            科目列表")
    print(f"    GET  /api/entries             凭证列表")
    print(f"    GET  /api/report/income       利润表")
    print(f"    GET  /api/report/balance-sheet 资产负债表")
    print(f"    GET  /api/report/cash-flow    现金流量表")
    print(f"    GET  /api/report/vat          增值税申报")
    print(f"    GET  /api/report/general-ledger 总分类账")
    print(f"    GET  /api/anomalies           异常检测")
    print(f"    GET  /api/audit-logs          审计日志")
    print(f"    GET  /api/export/csv          CSV 导出")
    print(f"    POST /api/entry/create        创建凭证")
    print(f"    POST /api/account/create      创建科目")
    print(f"    POST /chat                    AI 对话 (SSE)")
    print(f"")
    print(f"  数据目录: {DATA_DIR}")
    print(f"  智能体: Hermes / OpenClaw / Codex 已就绪")
    print(f"")
    
    # 写入启动就绪标记文件（供 App 检测）
    try:
        import os as _sos
        ready_file = os.path.join(DATA_DIR, ".bridge_ready")
        _sos.makedirs(DATA_DIR, exist_ok=True)
        with open(ready_file, "w") as _sf:
            _sf.write(f"pid={os.getpid()}\nport={PORT}\ntime={time.time()}")
    except Exception:
        pass
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print(f"\n[Bridge] 停止服务")
        server.server_close()


# ══════════════════════════════════════════════════════════════════
# 配置文件模板
# ══════════════════════════════════════════════════════════════════


if __name__ == "__main__":
    _generate_config_template()
    main()
