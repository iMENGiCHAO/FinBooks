# FinBooks — 中小微企业财务管理软件

<p align="center">
  <b>macOS 原生 · 轻量离线 · 数据自主可控 · AI Agent 智能协同</b>
  <br>
  <i>符合会计准则 · 支持多公司 · 一键 PDF 导出 · 操作审计日志</i>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.0%2B-blue" alt="macOS">
  <img src="https://img.shields.io/badge/Swift-5.10-orange" alt="Swift">
  <img src="https://img.shields.io/badge/架构-Universal%20Binary-brightgreen" alt="Universal">
  <img src="https://img.shields.io/badge/AI%20Agent-Hermes%20%7C%20Claude%20Code%20%7C%20Codex-8A2BE2" alt="Agent">
  <img src="https://img.shields.io/badge/许可-MIT-green" alt="License">
  <img src="https://img.shields.io/badge/版本-v1.2.1-red" alt="Version">
  <img src="https://img.shields.io/badge/语言-SwiftUI-f05138" alt="SwiftUI">
</p>

---

## 📸 界面预览

| 首页总览 | 资产负债表 | 利润表 |
|---|---|---|
| ![](screenshots/dashboard.png) | ![](screenshots/balance_sheet.png) | ![](screenshots/income_statement.png) |

---

## ✨ 为什么选择 FinBooks？

**FinBooks** 是一套专为中小微企业设计的 macOS 原生财务管理软件。它不只是一个"记账工具"，而是一个**符合会计规范、数据完全自主、支持 AI Agent 协同**的专业级财务平台。

| 痛点 | FinBooks 的解法 |
|---|---|
| 📋 纸质账本/Excel 难管理 | 结构化凭证体系，借贷自动平衡，编号自动连续 |
| 🔒 云端财务软件数据泄漏风险 | 完全离线，数据存本地，零网络依赖 |
| 💰 专业财务软件年费高昂 | 开源免费，MIT 许可，零商业限制 |
| 🤖 AI 时代不知道怎么用 | 原生 AI Agent 集成，自然语言操作财务数据 |
| 💻 界面体验粗糙 | 纯 SwiftUI 原生，macOS 设计规范，约 50MB 内存 |

---

## 🌟 核心特性

### 📊 多公司管理
同一应用内管理多家公司账簿，数据完全隔离，互不干扰。每家公司独立科目表、独立凭证、独立结账周期。

### 📋 标准科目表
基于会计准则的完整科目编码体系（1001~6901），新建公司自动建账。支持自定义科目，删除引用中的科目自动拦截。

### 📝 凭证管理
- **新增凭证** — 多分录借贷行，金额实时汇总，默认一借一贷
- **自动编号** — 格式「记-2026-0001」，单调递增，删除不补号（审计合规）
- **借贷平衡校验** — 录入和保存时强制检查，不平自动提示差额
- **过账锁定** — 已过账凭证不可修改/删除，防止数据篡改

### 🔒 期末结账
- 自动结转损益至本年利润
- **结账期间锁定** — 已结账期间不可新增/修改/删除凭证
- **重复结账防护** — 已结账期间再次操作时安全拒绝
- 支持反结账恢复

### 📄 报表导出（PDF）
基于 NSView 原生渲染引擎，中文字体完美嵌入：

| 报表 | 格式 | 特点 |
|---|---|---|
| 资产负债表 | 左右分栏（资产/负债及权益） | 期末余额 + 年初余额，大类小计 |
| 利润表 | 上下结构 | 本期金额 + 本年累计，标准费用分类 |
| 总分类账 | 逐笔流水 | 期初→本期发生→期末余额 |
| 凭证清单 | 全部汇总 | 每张凭证借贷金额 + 分录条数 |

### 🛡️ 审计日志
v1.2.0 新增 `AuditLog` 模型，记录全部关键操作：
- 凭证创建/修改/删除/过账/反过账
- 公司创建/删除
- 期间结账/反结账
- 保留最近 1000 条，不可篡改

### 🖥️ 原生体验
- SwiftUI + AppKit 纯原生，支持 macOS 深色/浅色模式
- 内存占用约 50MB，启动毫秒级
- Universal Binary 同时支持 Intel + Apple Silicon

---

## 🤖 AI Agent 集成

FinBooks 是**业界首个原生支持 AI Agent 的财务管理软件**。数据以 JSON 格式存储在本地，Agent 可直接读取写入，App 一键刷新。

### 工作原理

```
FinBooks App                 AI Agent (Hermes / Claude Code / Codex)
    │                                │
    │  Cmd+Shift+R 刷新              │  自然语言操作
    │  refreshFromDisk()             │  finbooks_tools.py
    │                                │  直接读写 JSON
    └──────────┬─────────────────────┘
               ▼
    ~/Library/Application Support/com.finbooks.app/
    ├── companies.json      → 公司数据
    ├── accounts.json       → 科目表
    ├── entries.json        → 凭证数据
    ├── periodCloses.json   → 结账记录
    ├── auditLogs.json      → 审计日志
    └── backups/            → 自动备份
```

### 支持的操作

| 操作 | 一句话描述 |
|---|---|
| 📋 查询公司列表 | 「有哪些公司？」→ Agent 返回所有公司详情 |
| 📂 查看科目表 | 「看下资产类科目」→ 分类展示科目编码和余额 |
| ✏️ 创建凭证 | 「记录一笔办公用品支出 2000 元」→ Agent 自动选科目校验平衡 |
| 📊 利润表分析 | 「看 6 月利润表」→ 本期/累计收入费用净利润 |
| 📈 资产负债表 | 「到 6 月 30 日的负债表」→ 标准格式左右分栏 |
| 📑 总分类账 | 「查银行存款的明细账」→ 每笔流水+期初期末余额 |
| 🔍 异常检测 | 「检查有没有异常凭证」→ 扫不平/大额/重复 |
| 📉 费用趋势 | 「今年各月费用走势」→ 逐月柱状图对比 |
| 🔒 期间结账 | 「结算 2026 年 6 月」→ 锁定期间，自动损益结转 |

### 快速上手

```bash
# 在 Hermes Agent 中加载技能
skill_view("finbooks-agent")

# 查询科目表
python3 finbooks_tools.py accounts "示例科技有限公司"

# 创建凭证（1002 银行存款 → 5001 主营业务收入）
python3 finbooks_tools.py create "示例科技有限公司" "2026-06-04" "销售收入" "1002:100000:0,5001:0:100000"

# 查看利润表
python3 finbooks_tools.py income "示例科技有限公司" 2026 6

# 一键分析
python3 finbooks_tools.py analyze "示例科技有限公司"
```

> Agent 写入数据后，App 中按 **`Cmd + Shift + R`** 一键刷新。

---

## 🚀 快速开始

### 下载运行

从 [Releases 页面](https://github.com/iMENGiCHAO/FinBooks/releases) 下载最新 `FinBooks.app`：

```
📦 FinBooks.app（Universal Binary，约 4MB）
   ├── Intel Mac（x86_64）→ 直接运行
   └── Apple Silicon（arm64）→ 直接运行
```

### 自行编译

```bash
git clone https://github.com/iMENGiCHAO/FinBooks.git
cd FinBooks
bash build.sh
open archive/FinBooks.app
```

### 首次使用

1. 启动应用 → 点击「新增公司」
2. 输入公司名称（如「北京某某科技有限公司」）
3. 系统自动创建标准科目表
4. 开始录入凭证

---

## 📖 功能详解

### 公司管理
- 创建、切换、删除公司
- 每家公司独立账簿数据
- 公司名称可修改

### 科目表
| 类别 | 编码范围 | 包含科目 |
|---|---|---|
| 资产类 | 1001~1901 | 库存现金、银行存款、应收账款、存货、固定资产、累计折旧等 |
| 负债类 | 2001~2901 | 短期借款、应付账款、应付职工薪酬、应交税费、长期借款等 |
| 权益类 | 4001~4901 | 实收资本、本年利润、利润分配 |
| 收入类 | 5001~5901 | 主营业务收入、其他业务收入、投资收益等 |
| 费用类 | 6001~6901 | 主营业务成本、管理费用、销售费用、财务费用、所得税费用等 |

### 凭证管理
- **新增凭证** — 自动编号 `记-2026-NNNN`，删除不补号
- **编辑凭证** — 未过账凭证可修改，已过账锁定
- **过账/反过账** — 过账时校验借贷平衡
- **删除凭证** — 已过账和已结账期间禁止删除

### 快捷键
| 快捷键 | 功能 |
|---|---|
| `Cmd + Shift + R` | 从磁盘刷新数据（AI Agent 写入后使用） |
| `Cmd + Enter` | 保存当前凭证 |
| `Cmd + .` | 取消编辑 |

---

## 🏗️ 技术架构

```
FinBooks
│
├─ SwiftUI 视图层
│  ├─ 首页总览（Dashboard）
│  ├─ 凭证录入 / 凭证列表
│  ├─ 科目表管理
│  ├─ 资产负债表 / 利润表
│  ├─ 总分类账
│  ├─ 期末结账
│  └─ 公司管理
│
├─ AccountingEngine（业务逻辑）
│  ├─ 余额计算
│  ├─ 期末结转
│  ├─ 凭证编号（单调递增）
│  ├─ 报表生成
│  ├─ 借贷平衡校验
│  └─ 科目表管理
│
├─ DataStore（数据层）
│  ├─ Company / Account / JournalEntry
│  ├─ PeriodClose / AuditLog
│  ├─ JSON 文件存储（atomic write）
│  └─ 自动备份（保留 30 天）
│
└─ finbooks-agent（AI Agent 集成）
   ├─ finbooks_tools.py
   └─ SKILL.md（2500+ 行自然语言操作规范）
```

### 技术栈
| 层次 | 技术 |
|---|---|
| UI 框架 | SwiftUI 3+ |
| 系统框架 | AppKit（PDF 导出） |
| 持久化 | JSON 文件存储（atomic write 防数据损坏） |
| 语言 | Swift 5.10+ |
| 最低部署 | macOS 14.0 |
| 架构 | Universal Binary（Intel + Apple Silicon） |
| AI 集成 | Hermes / Claude Code / Codex 等任意 AI Agent |

### 架构亮点
- **分层设计** — 视图 → 业务逻辑 → 数据，职责清晰
- **响应式数据流** — `@Published` + `@ObservableObject` 驱动 UI
- **离线优先** — 零网络依赖，数据完全本地
- **Agent 友好** — JSON 结构开放，AI 可直接读写

---

## 🔐 数据安全

- ✅ **完全离线** — 无需网络，数据不离开你的电脑
- ✅ **本地存储** — `~/Library/Application Support/com.finbooks.app/`
- ✅ **原子写入** — JSON 保存使用系统 atomic write，防止文件损坏
- ✅ **自动备份** — 每次保存生成带时间戳的备份（保留 30 天）
- ✅ **零数据采集** — 不含任何分析 SDK、遥测、统计组件
- ✅ **开源审计** — 全部源码开放，任何人都可以审查

---

## 🗺️ 路线图

### v1.x — 功能完善（当前 v1.2.1）
- [x] 凭证编号单调递增（删除不补号，审计合规）
- [x] 利润表动态取科目（不硬编码 code）
- [x] Dashboard 本月净利润按期间过滤
- [x] 过账锁定（已过账禁止修改/删除）
- [x] 期末结账双重检查防重复
- [x] 审计日志系统（AuditLog 模型 + JSON 持久化）
- [x] 科目实时反查（resolvedAccountCode/Name）
- [x] PDF 坐标系修复（Flipped 方向正确）
- [ ] Excel/CSV 凭证批量导入导出
- [ ] 现金流量表
- [ ] 账簿打印（总账、明细账、日记账）
- [ ] 多币种支持
- [ ] AI Agent 自然语言凭证生成

### v2.x — 企业级特性
- [ ] 用户权限管理（会计/出纳/审核角色分离）
- [ ] 操作审计日志界面
- [ ] 电子发票识别与自动生成凭证
- [ ] iCloud 多设备同步

### v3.x — 智能财务
- [ ] AI 辅助记账（自然语言→凭证）
- [ ] 智能财务分析报告
- [ ] 税务申报数据导出

---

## 🤝 贡献指南

欢迎各种形式的贡献！无论是 Bug 报告、功能建议还是 PR：

1. Fork 本仓库
2. 创建特性分支：`git checkout -b feature/awesome-feature`
3. 提交改动：`git commit -m 'Add awesome feature'`
4. 推送分支：`git push origin feature/awesome-feature`
5. 提交 Pull Request

---

## 📄 许可证

[MIT License](LICENSE)

Copyright © 2026 iMENGiCHAO

---

<p align="center">
  <b>FinBooks</b> — 让中小微企业拥有专业级的财务管理工具
  <br>
  <sub>⭐ 如果这个项目对你有帮助，请给一个 Star</sub>
</p>

<p align="center">
  <a href="https://github.com/iMENGiCHAO/FinBooks/issues">📮 反馈问题</a>
  ·
  <a href="https://github.com/iMENGiCHAO/FinBooks/discussions">💬 讨论交流</a>
  ·
  <a href="https://github.com/iMENGiCHAO/FinBooks/releases">📦 下载最新版</a>
</p>