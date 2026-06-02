# FinBooks

**中国中小微企业财务管理软件 — macOS 原生 SwiftUI 应用**

## 功能

- **多公司管理** — 多公司数据完全隔离
- **科目表** — 标准中文科目编码（1001~6901），自动建账
- **凭证管理** — 新增/编辑/删除/过账/反过账，借贷平衡强制校验
- **凭证编号** — 自动填补已删除编号空缺，保证连续不跳号
- **期末结账** — 损益结转至本年利润，结账期间 CRUD 全锁定，过账/反过账/新增/修改/删除均禁止
- **报表导出** — 资产负债表、利润表、总分类账，支持 PDF 导出
- **科目删除保护** — 被凭证引用的科目不可删除

## 系统要求

- macOS 14.0+
- Apple Silicon 或 Intel

## 构建

```bash
git clone https://github.com/iMENGiCHAO/FinBooks.git
cd FinBooks
bash build.sh
```

构建产物位于 `archive/FinBooks.app`。

## 技术栈

- Swift 5.9+
- SwiftUI
- AppKit (PDF 导出)
- SQLite (轻量级数据存储)

## 许可证

MIT License

## 版本历史

- **v1.0.0** (2026-06) — 首个稳定版，基础功能完整，满足中小微企业日常记账需求
