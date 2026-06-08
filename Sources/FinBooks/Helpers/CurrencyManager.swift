import SwiftUI

// MARK: - 多币种支持

/// 币种汇率记录
struct CurrencyRate: Codable, Identifiable {
    let id: UUID
    var fromCurrency: String
    var toCurrency: String
    var rate: Decimal
    var date: Date
    var source: String  // "manual", "auto"
}

/// 币种管理
@MainActor
final class CurrencyManager: ObservableObject {
    static let shared = CurrencyManager()
    
    @Published var rates: [CurrencyRate] = []
    
    /// 支持的币种列表
    let supportedCurrencies = [
        ("CNY", "人民币"),
        ("USD", "美元"),
        ("EUR", "欧元"),
        ("GBP", "英镑"),
        ("JPY", "日元"),
        ("HKD", "港元"),
        ("SGD", "新加坡元"),
        ("KRW", "韩元"),
    ]
    
    private init() {
        // 加载默认汇率（从 UserDefaults）
        if let data = UserDefaults.standard.data(forKey: "currency_rates"),
           let saved = try? JSONDecoder().decode([CurrencyRate].self, from: data) {
            rates = saved
        }
        
        // 如果没有数据，设置默认汇率
        if rates.isEmpty {
            setDefaultRates()
        }
    }
    
    private func setDefaultRates() {
        let defaults: [(String, String, Decimal)] = [
            ("USD", "CNY", 7.24),
            ("EUR", "CNY", 7.87),
            ("GBP", "CNY", 9.15),
            ("JPY", "CNY", 0.048),
            ("HKD", "CNY", 0.93),
            ("SGD", "CNY", 5.36),
            ("KRW", "CNY", 0.0054),
        ]
        rates = defaults.map { CurrencyRate(id: UUID(), fromCurrency: $0.0, toCurrency: $0.1, rate: $0.2, date: Date(), source: "manual") }
        saveRates()
    }
    
    /// 获取从某币种到人民币的汇率
    func rateToCNY(from currency: String) -> Decimal {
        if currency == "CNY" { return 1 }
        return rates.first(where: { $0.fromCurrency == currency && $0.toCurrency == "CNY" })?.rate ?? 1
    }
    
    /// 转换金额为人民币
    func convertToCNY(amount: Decimal, from currency: String) -> Decimal {
        amount * rateToCNY(from: currency)
    }
    
    /// 更新汇率
    func updateRate(from: String, to: String, rate: Decimal) {
        if let idx = rates.firstIndex(where: { $0.fromCurrency == from && $0.toCurrency == to }) {
            var r = rates[idx]
            r.rate = rate
            r.date = Date()
            r.source = "manual"
            rates[idx] = r
        } else {
            rates.append(CurrencyRate(id: UUID(), fromCurrency: from, toCurrency: to, rate: rate, date: Date(), source: "manual"))
        }
        saveRates()
    }
    
    private func saveRates() {
        if let data = try? JSONEncoder().encode(rates) {
            UserDefaults.standard.set(data, forKey: "currency_rates")
        }
    }
    
    var currencyNames: [(code: String, name: String)] {
        supportedCurrencies.map { ($0.0, $0.1) }
    }
}

// MARK: - 币种选择器

struct CurrencyPicker: View {
    @Binding var selection: String
    let label: String
    
    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(CurrencyManager.shared.currencyNames, id: \.code) { item in
                Text("\(item.code) \(item.name)").tag(item.code)
            }
        }
    }
}

// MARK: - 汇率管理视图

struct CurrencyRateView: View {
    @StateObject private var manager = CurrencyManager.shared
    @State private var editingRate: String = ""
    @State private var editingIndex: Int?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("汇率管理").font(.headline)
            
            List {
                ForEach(Array(manager.rates.enumerated()), id: \.offset) { idx, rate in
                    HStack {
                        Text("\(rate.fromCurrency) → \(rate.toCurrency)")
                            .font(.subheadline)
                            .frame(width: 100, alignment: .leading)
                        if editingIndex == idx {
                            TextField("汇率", text: $editingRate)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .onSubmit {
                                    if let val = Decimal(string: editingRate) {
                                        manager.updateRate(from: rate.fromCurrency, to: rate.toCurrency, rate: val)
                                    }
                                    editingIndex = nil
                                }
                        } else {
                            Text(String(describing: rate.rate))
                                .font(.subheadline.monospacedDigit())
                                .frame(width: 80, alignment: .trailing)
                        }
                        Spacer()
                        Text(rate.source == "auto" ? "自动" : "手动")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        
                        Button("编辑") {
                            editingIndex = idx
                            editingRate = String(describing: rate.rate)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .listStyle(.plain)
            .frame(height: 200)
        }
        .padding()
    }
}