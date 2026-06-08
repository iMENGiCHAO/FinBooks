import SwiftUI

struct ChartOfAccountsView: View {
    let company: Company
    @EnvironmentObject var dataStore: DataStore
    @State private var showAddAccount = false
    @State private var showEditAccount = false
    @State private var selectedAccountForEdit: Account?
    @State private var searchText = ""
    @State private var selectedCategory: AccountCategory?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("类别", selection: $selectedCategory) {
                    Text("全部").tag(nil as AccountCategory?)
                    ForEach(AccountCategory.allCases) { cat in
                        Text(cat.rawValue).tag(cat as AccountCategory?)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 400)

                Spacer()

                TextField("搜索科目", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)

                Button {
                    selectedAccountForEdit = nil
                    showAddAccount = true
                } label: {
                    Label("新增", systemImage: "plus")
                }
            }
            .padding()

            Divider()

            AccountList(
                company: company,
                searchText: searchText,
                category: selectedCategory,
                onEdit: { account in
                    selectedAccountForEdit = account
                    showEditAccount = true
                }
            )
        }
        .sheet(isPresented: $showAddAccount) {
            AccountEditView(company: company, account: nil)
        }
        .sheet(isPresented: $showEditAccount) {
            if let account = selectedAccountForEdit {
                AccountEditView(company: company, account: account)
            }
        }
    }
}

struct AccountList: View {
    let company: Company
    let searchText: String
    let category: AccountCategory?
    let onEdit: (Account) -> Void
    @EnvironmentObject var dataStore: DataStore

    var filteredAccounts: [Account] {
        let accounts = dataStore.accounts(for: company.id).sorted { $0.code < $1.code }
        var result = accounts
        if let cat = category {
            result = result.filter { $0.category == cat }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.code.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    var body: some View {
        if filteredAccounts.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "无科目数据" : "未找到匹配科目",
                systemImage: "list.bullet.rectangle",
                description: Text(searchText.isEmpty ? "点击「新增」创建第一个科目" : "换个关键词试试")
            )
        } else {
            Table(filteredAccounts) {
            TableColumn("科目编码", value: \.code).width(100)
            TableColumn("科目名称", value: \.name).width(160)
            TableColumn("类别") { account in
                Text(account.category.rawValue)
                    .foregroundStyle(.secondary)
            }.width(100)
            TableColumn("状态") { account in
                Text(account.isActive ? "启用" : "停用")
                    .foregroundStyle(account.isActive ? .green : .red)
            }.width(60)
            TableColumn("余额") { account in
                let bal = AccountingEngine.balance(for: account)
                Text("¥\(FMT.amount(bal))")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(120)
            .alignment(.trailing)
        }
        .tableStyle(.bordered)
        .contextMenu(forSelectionType: Account.self) { items in
            if let account = items.first {
                Button("编辑", action: { onEdit(account) })
                Button(account.isActive ? "停用" : "启用") {
                    account.isActive.toggle()
                    dataStore.updateAccount(account)
                }
                Button("删除", role: .destructive) {
                    dataStore.deleteAccount(account)
                }
            }
        }
    }
    }
}

struct AccountEditView: View {
    @EnvironmentObject var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss

    let company: Company
    let account: Account?

    @State private var code: String = ""
    @State private var name: String = ""
    @State private var category: AccountCategory = .asset
    @State private var isActive: Bool = true
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("科目编码", text: $code)
                TextField("科目名称", text: $name)
                Picker("类别", selection: $category) {
                    ForEach(AccountCategory.allCases) { cat in
                        Text(cat.rawValue).tag(cat)
                    }
                }
                Toggle("启用", isOn: $isActive)
            }
            .formStyle(.grouped)
            .navigationTitle(account != nil ? "编辑科目" : "新增科目")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .alert("错误", isPresented: $showError) {
                Button("确定") {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                if let acc = account {
                    code = acc.code
                    name = acc.name
                    category = acc.category
                    isActive = acc.isActive
                }
            }
            .frame(minWidth: 380, minHeight: 280)
        }
    }

    private func save() {
        guard !code.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "科目编码不能为空"
            showError = true
            return
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "科目名称不能为空"
            showError = true
            return
        }

        if let acc = account {
            acc.code = code
            acc.name = name
            acc.category = category
            acc.isActive = isActive
            dataStore.updateAccount(acc)
        } else {
            let acc = Account(code: code, name: name, category: category, isActive: isActive)
            acc.companyID = company.id
            dataStore.addAccount(acc)
        }
        dismiss()
    }
}
