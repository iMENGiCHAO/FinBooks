# FinBooks AI Agent 智能对接层 — 设计文档

## 概述

FinBooks 是 macOS SwiftUI 财务软件，数据以 JSON 文件存储在 `~/Library/Application Support/com.finbooks.app/`。本设计增加一个 **AI Agent 智能对接层**，让 Hermes Agent / OpenClaw 等 AI 智能体可以直接读写 FinBooks 的数据文件，完成财务操作——智能体作为数据入口，App 作为可视化界面，两者共享同一份 JSON 数据，无需额外桥接服务。

## 核心思路

```
User ──┬── FinBooks App (macOS GUI)
       │     ↑ 读写 JSON 文件
       │
       └── AI Agent (Hermes/OpenClaw)
             ↑ 读写 JSON 文件（相同路径）
             → 读取/解析/校验/写入
             → 提供自然语言交互
```

**Key Insight:** FinBooks 的 DataStore.saveAll() 直接写 JSON，Agent 也直接读写同一份 JSON。App 重启或 refresh 时自动加载 Agent 写入的数据。二者天然兼容，不需要 API 层。

## Agent 能力矩阵

AI Agent 通过 finbooks-agent skill 获得以下能力：

### 1. 查询能力（只读）
- 列出公司
- 查看科目表（按公司/分类）
- 查看凭证清单（按期间/按公司）
- 查看结账状态
- 查看余额、期间发生额

### 2. 写入能力（需确认）
- 创建凭证（严格借贷平衡校验、结账校验）
- 修改/删除凭证（结账校验）
- 新增科目（建议 code 规范）
- 结账/反结账

### 3. 分析能力
- 利润表分析
- 资产负债表分析
- 科目余额趋势
- 异常检测（大额异常、重复凭证、不平凭证等）
- 自然语言查询转财务数据

### 4. 导入能力
- CSV/Excel 银行流水导入
- 凭证图片 OCR（可选）
- 智能提取→清洗→生成凭证草稿

## 数据模型对等

AI Agent 操作的 JSON 结构与 FinBooks DataStore 完全一致：

```
~/Library/Application Support/com.finbooks.app/
├── companies.json    → [Company]    公司列表
├── accounts.json     → [Account]    会计科目
├── entries.json      → [JournalEntry] 凭证
└── periodCloses.json → [PeriodClose] 结账记录
```

JSON 格式对应 Swift 的 Codable 输出，Agent 读写时保留所有字段。

## 财务规则引擎（Agent 端）

Agent 需内嵌以下规则校验：

| 规则 | 校验逻辑 | 违反处理 |
|------|---------|---------|
| 借贷平衡 | 每条凭证 `sum(debit) == sum(credit)` | 拒绝创建，提示差额 |
| 结账锁定 | 检查 periodCloses.json，已结账期间禁止 CRUD | 拒绝操作，提示已结账 |
| 科目存在性 | lines 中的 accountCode 必须在 accounts.json 存在 | 拒绝或建议新建科目 |
| 凭证编号 | 复用已删除的空缺编号，连续不跳号 | 自动计算 |
| 操作前备份 | 修改前复制原文件为 `.bak.时间戳` | 自动执行 |

## 安全与数据完整性

1. **自动备份**：每次写入前，将受影响的 JSON 文件备份为 `filename.json.bak.20260604T120000`
2. **操作确认**：写入操作前向用户展示即将变更的内容，请求确认
3. **乐观并发**：Agent 修改前重新读取文件，避免覆写 App 已保存的更新
4. **JSON 校验**：写入后立即回读解析验证，确保 JSON 合法

## 交互流程

```
用户: "给示例科技做一张凭证，借银行存款10万，贷主营业务收入10万"

Agent:
  ┌─ 1. 读取 companies.json → 找到"示例科技有限公司"
  ├─ 2. 读取 accounts.json → 验证科目"1002 银行存款"存在
  ├─ 3. 读取 accounts.json → 验证科目"5001 主营业务收入"存在
  ├─ 4. 读取 periodCloses.json → 检查当期未结账
  ├─ 5. 读取 entries.json → 计算下一个凭证号
  ├─ 6. 展示将要写入的内容 + 请求确认
  └─ 7. 确认后 → 备份 entries.json → 写入新凭证 → 回读验证 → 汇报结果
```

## 与 App 的关系

- App 是 **GUI 展示层**，提供可视化操作（表格、表单、报表、PDF 导出）
- Agent 是 **智能交互层**，提供自然语言操作、智能分析、批量导入、异常检测
- 数据层**完全共享**同一份 JSON 文件
- App 可通过 `DataStore.refreshFromDisk()` 或 `loadAll()` 立即看到 Agent 的修改
- Agent 写入前重读文件，避免并发覆盖

## 迭代路线

### Phase 1 — Agent Skill 基础版
- finbooks-agent SKILL.md 包含完整数据模型、所有 CRUD 操作指引、财务规则
- Agent 通过工具函数直接读写 JSON
- 支持：查公司、查科目、创建凭证、查结账状态

### Phase 2 — 智能分析
- 利润分析、资产负债表生成、科目趋势
- 自然语言查询（"这个月利润怎么样？"、"哪些费用超了？"）
- 异常检测（大额异常、重复凭证）

### Phase 3 — 导入能力
- CSV 银行流水导入→自动匹配科目→生成凭证草稿
- 凭证图片 OCR→提取信息→清洗→生成凭证

### Phase 4 — App 侧增强
- App 增加 "从 Agent 导入" 按钮
- Agent 写入后可通过某种信号提醒 App 刷新
- 可选：App 内嵌 Agent 查询面板