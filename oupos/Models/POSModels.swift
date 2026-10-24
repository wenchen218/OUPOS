import Foundation

enum MainTab: String, CaseIterable, Identifiable {
    case order = "點餐"
    case inventory = "售完管理"
    case reports = "報表"
    case settings = "設定"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .order: "fork.knife"
        case .inventory: "shippingbox.fill"
        case .reports: "chart.line.uptrend.xyaxis"
        case .settings: "gearshape.fill"
        }
    }
}

struct ProductCategory: Identifiable, Hashable {
    let id: UUID
    let name: String
}
/// These values match the existing local JSON and AI menu import schema.
/// No persistent database migration is necessary.
enum ModifierSelectionType: String, Codable {
    case single    // Exactly one choice within the same topping group
    case multi     // Repeated quantities of the same topping are allowed
    case checkbox  // Several different toppings; each at most once

    var label: String {
        switch self {
        case .single: "單選"
        case .multi: "複選（可加數量）"
        case .checkbox: "勾選（每項一次）"
        }
    }
}
struct ModifierOption: Identifiable, Hashable {
    let id: UUID
    let name: String
    let price: Int
    let selectionType: ModifierSelectionType
}
struct ModifierGroup: Identifiable, Hashable {
    let id: UUID
    let name: String
    let maxSelect: Int
    let options: [ModifierOption]
}

/// The cart's existing [ModifierOption] representation can contain repeated
/// entries for multi-select quantities. This keeps old carts/order data compatible.
enum ModifierSelection {
    enum Action { case select, increment, decrement }
    static let maxPerTopping = 99

    static func count(of option: ModifierOption, in selected: [ModifierOption]) -> Int {
        selected.filter { $0.id == option.id }.count
    }

    static func canIncrement(_ option: ModifierOption, in group: ModifierGroup,
                             selected: [ModifierOption]) -> Bool {
        let current = count(of: option, in: selected)
        guard current < maxPerTopping else { return false }
        let groupIDs = Set(group.options.map(\.id))
        let total = selected.filter { groupIDs.contains($0.id) }.count
        return group.maxSelect == 0 || total < group.maxSelect
    }

    static func apply(_ action: Action, to option: ModifierOption,
                      group: ModifierGroup, selected: [ModifierOption]) -> [ModifierOption] {
        guard group.options.contains(where: { $0.id == option.id }) else { return selected }
        var updated = selected
        let count = count(of: option, in: updated)
        switch option.selectionType {
        case .single:
            guard action == .select else { return updated }
            // Treat single choice as GROUP exclusive, not just option exclusive.
            let groupIDs = Set(group.options.map(\.id))
            updated.removeAll { groupIDs.contains($0.id) }
            if count == 0 { updated.append(option) }
        case .checkbox:
            guard action == .select else { return updated }
            if count > 0 {
                updated.removeAll { $0.id == option.id }
            } else {
                // Defensive support for legacy imports that put modes in one group.
                // New saves reject mixed-mode groups.
                let groupIDs = Set(group.options.filter { $0.selectionType == .single }.map(\.id))
                updated.removeAll { groupIDs.contains($0.id) }
                if canIncrement(option, in: group, selected: updated) { updated.append(option) }
            }
        case .multi:
            if action == .decrement {
                if let index = updated.lastIndex(where: { $0.id == option.id }) {
                    updated.remove(at: index)
                }
            } else {
                let groupIDs = Set(group.options.filter { $0.selectionType == .single }.map(\.id))
                updated.removeAll { groupIDs.contains($0.id) }
                if canIncrement(option, in: group, selected: updated) { updated.append(option) }
            }
        }
        return updated
    }

    /// Aggregate identical modifiers in first-selected order, for cart, checkout and receipt.
    static func descriptions(_ selected: [ModifierOption], includePrices: Bool = false) -> [String] {
        var ordered: [ModifierOption] = []
        var quantities: [UUID: Int] = [:]
        for option in selected {
            if quantities[option.id] == nil { ordered.append(option) }
            quantities[option.id, default: 0] += 1
        }
        return ordered.map { option in
            let qty = quantities[option.id] ?? 1
            let countLabel = qty > 1 ? " ×\(qty)" : ""
            let totalPrice = option.price * qty
            let priceLabel = includePrices && totalPrice > 0 ? " +\(totalPrice)" : ""
            return option.name + countLabel + priceLabel
        }
    }
}
struct Product: Identifiable, Hashable {
    let id: UUID
    let categoryID: UUID
    let name: String
    let price: Int
    let isSoldOut: Bool
    let isEnabled: Bool
    let modifierGroups: [ModifierGroup]
}
struct CartItem: Identifiable, Equatable {
    let id: UUID
    let product: Product
    var quantity: Int
    var selectedModifiers: [ModifierOption]
    var note: String
    var unitPrice: Int { product.price + selectedModifiers.reduce(0) { $0 + $1.price } }
    var subtotal: Int { unitPrice * quantity }
    var modifierDescriptions: [String] { ModifierSelection.descriptions(selectedModifiers) }
    var receiptModifiers: [String] { ModifierSelection.descriptions(selectedModifiers, includePrices: true) }
}
struct PaymentMethod: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    var isCash: Bool { name == "現金" || name.lowercased() == "cash" }
    var symbol: String { isCash ? "banknote.fill" : "creditcard.fill" }
}
struct ShopTable: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
}
struct PrinterTarget: Codable, Equatable {
    var host: String
    var port: UInt16
    var width: Int
    static let fallback = PrinterTarget(host: "", port: 9100, width: 576)
}
struct MenuCategoryRecord: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
}
struct MenuProductRecord: Identifiable, Hashable, Codable {
    let id: Int
    let categoryID: Int
    let name: String
    let price: Int
    let isVisible: Bool
    var isSoldOut: Bool
}
struct ToppingGroupRecord: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let maxSelect: Int
}
struct ToppingRecord: Identifiable, Hashable, Codable {
    let id: Int
    let groupID: Int
    let name: String
    let price: Int
    let menuItemIDs: [Int]
    let selectionType: String
    let isRequired: Bool
    let isVisible: Bool
}

/// Bulk-select a category without changing selections from other categories.
enum CategoryProductSelection {
    static func update(_ selected: Set<Int>, categoryID: Int,
                       products: [MenuProductRecord], selectAll: Bool) -> Set<Int> {
        let ids = Set(products.filter { $0.categoryID == categoryID }.map(\.id))
        return selectAll ? selected.union(ids) : selected.subtracting(ids)
    }
}

enum OrderStatus: String, Codable {
    case completed = "已完成"
    case cancelled = "已取消"
}
struct OrderLine: Identifiable, Hashable, Codable {
    let id: UUID
    let name: String
    var productID: UUID? = nil
    let quantity: Int
    let unitPrice: Int
    let modifiers: [String]
    let note: String?
    var subtotal: Int { quantity * unitPrice }
}
/// Human-readable receipt number: local Gregorian date (YYMMDD) + four random digits.
/// Random choices are made only from suffixes not already used on this iPad
/// for the date. Cancelled orders are included, so their numbers are never reused.
enum OrderNumberGenerator {
    enum Error: LocalizedError {
        case dailyNumbersExhausted

        var errorDescription: String? {
            switch self {
            case .dailyNumbersExhausted:
                "今天的四位數訂單編號已全部使用，無法建立新訂單。"
            }
        }
    }

    static func generate(at date: Date,
                         existingNumbers: Set<String>,
                         timeZone: TimeZone = .current,
                         randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }) throws -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let prefix = String(format: "%02d%02d%02d", (parts.year ?? 0) % 100,
                            parts.month ?? 0, parts.day ?? 0)

        // Only ten-character numbers sharing today's date prefix occupy a slot.
        // Historical numbers from older app versions remain untouched.
        let usedSuffixes = Set(existingNumbers.compactMap { number -> Int? in
            guard number.count == 10, number.hasPrefix(prefix) else { return nil }
            return Int(number.suffix(4))
        })
        let available = (0..<10_000).filter { !usedSuffixes.contains($0) }
        guard !available.isEmpty else { throw Error.dailyNumbersExhausted }

        let suffix = available[randomIndex(available.count)]
        return prefix + String(format: "%04d", suffix)
    }
}

struct POSOrder: Identifiable, Hashable, Codable {
    let id: UUID
    let number: String
    let createdAt: Date
    let table: String
    let lines: [OrderLine]
    let note: String
    let paymentMethod: String
    var status: OrderStatus
    var total: Int { lines.reduce(0) { $0 + $1.subtotal } }
    var totalQuantity: Int { lines.reduce(0) { $0 + $1.quantity } }
}
struct ReportSummary {
    let revenue: Int
    let orderCount: Int
    let payments: [PaymentSlice]
    let orders: [POSOrder]
    static let empty = ReportSummary(revenue: 0, orderCount: 0, payments: [], orders: [])
}
struct ProductSalesRow: Identifiable, Hashable {
    let id: String
    let name: String
    let quantity: Int
    let orderCount: Int
    let grossSales: Int
}
struct ProductSalesSummary: Equatable {
    let productCount: Int
    let totalQuantity: Int
    let totalOrders: Int
    let grossSales: Int
    let products: [ProductSalesRow]
    static let empty = ProductSalesSummary(productCount: 0, totalQuantity: 0, totalOrders: 0, grossSales: 0, products: [])
}
struct PaymentSlice: Identifiable {
    let id = UUID()
    let label: String
    let amount: Int
    let colorIndex: Int
}
