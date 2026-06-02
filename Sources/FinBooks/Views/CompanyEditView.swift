import SwiftUI

struct CompanyEditView: View {
    @EnvironmentObject var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss

    let existingCompany: Company?
    var onSave: ((Company) -> Void)?

    @State private var name: String = ""
    @State private var legalName: String = ""
    @State private var taxId: String = ""
    @State private var address: String = ""
    @State private var phone: String = ""
    @State private var fiscalYearStart: String = "01-01"
    @State private var currency: String = "CNY"
    @State private var createDefaultAccounts = true
    @State private var showError = false
    @State private var errorMessage = ""

    init(company: Company?, onSave: ((Company) -> Void)? = nil) {
        self.existingCompany = company
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("公司名称", text: $name)
                    TextField("法定全称", text: $legalName)
                    TextField("税号", text: $taxId)
                }
                Section("联系方式") {
                    TextField("地址", text: $address)
                    TextField("电话", text: $phone)
                }
                Section("会计设置") {
                    TextField("会计年度起始 (MM-DD)", text: $fiscalYearStart)
                    Picker("本位币", selection: $currency) {
                        Text("CNY - 人民币").tag("CNY")
                        Text("USD - 美元").tag("USD")
                        Text("EUR - 欧元").tag("EUR")
                    }
                    if existingCompany == nil {
                        Toggle("创建默认科目表", isOn: $createDefaultAccounts)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existingCompany != nil ? "编辑公司" : "新建公司")
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
                if let company = existingCompany {
                    name = company.name
                    legalName = company.legalName
                    taxId = company.taxId
                    address = company.address
                    phone = company.phone
                    fiscalYearStart = company.fiscalYearStart
                    currency = company.currency
                }
            }
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "公司名称不能为空"
            showError = true
            return
        }

        let company: Company
        if let existing = existingCompany {
            company = existing
            company.name = name
            company.legalName = legalName
            company.taxId = taxId
            company.address = address
            company.phone = phone
            company.fiscalYearStart = fiscalYearStart
            company.currency = currency
            dataStore.updateCompany(company)
        } else {
            company = Company(name: name, legalName: legalName, taxId: taxId,
                             address: address, phone: phone,
                             fiscalYearStart: fiscalYearStart, currency: currency)
            dataStore.addCompany(company)
            if createDefaultAccounts {
                AccountingEngine.createDefaultAccounts(for: company.id)
            }
        }

        onSave?(company)
        dismiss()
    }
}
