import Foundation

/// All persistent state lives inside the iPad app sandbox. No network, login or server dependencies.
struct LocalPOSData: Codable {
    var schemaVersion = 1
    var categories: [MenuCategoryRecord] = []
    var products: [MenuProductRecord] = []
    var toppingGroups: [ToppingGroupRecord] = []
    var toppings: [ToppingRecord] = []
    var tables: [ShopTable] = [ShopTable(id: 1, name: "外帶"), ShopTable(id: 2, name: "內用")]
    var paymentMethods: [PaymentMethod] = [PaymentMethod(id: 1, name: "現金")]
    var printer: PrinterTarget = .fallback
    var orders: [POSOrder] = []
    var nextOrderSequence: Int = 1
}

enum LocalDatabaseError: LocalizedError {
    case invalidSchema, invalidInput(String), missingRecord, linkedRecords(String)
    var errorDescription: String? {
        switch self {
        case .invalidSchema: "本機資料版本不相容；資料並未被覆蓋。"
        case .invalidInput(let reason): reason
        case .missingRecord: "找不到指定資料"
        case .linkedRecords(let reason): reason
        }
    }
}

struct LocalPOSDatabase {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL { self.fileURL = fileURL; return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = base.appendingPathComponent("Oupos", isDirectory: true).appendingPathComponent("pos-data.json")
    }

    func load() throws -> LocalPOSData {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return LocalPOSData() }
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(LocalPOSData.self, from: data)
        guard decoded.schemaVersion == 1 else { throw LocalDatabaseError.invalidSchema }
        return decoded
    }

    func save(_ state: LocalPOSData) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        // Atomic replacement keeps an interrupted write from truncating the previous orders.
        try data.write(to: fileURL, options: .atomic)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL.path)
        #endif
    }
}

extension LocalPOSData {
    mutating func saveCategory(id: Int?, name: String) throws {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw LocalDatabaseError.invalidInput("請填寫分類名稱") }
        if let id {
            guard let i = categories.firstIndex(where: { $0.id == id }) else { throw LocalDatabaseError.missingRecord }
            categories[i] = MenuCategoryRecord(id: id, name: value)
        } else { categories.append(MenuCategoryRecord(id: nextID(categories.map(\.id)), name: value)) }
    }

    mutating func deleteCategory(_ id: Int) throws {
        guard !products.contains(where: { $0.categoryID == id }) else { throw LocalDatabaseError.linkedRecords("請先刪除或搬移分類內商品") }
        guard categories.contains(where: { $0.id == id }) else { throw LocalDatabaseError.missingRecord }
        categories.removeAll { $0.id == id }
    }

    mutating func saveProduct(id: Int?, categoryID: Int, name: String, price: Int, isVisible: Bool) throws {
        guard categories.contains(where: { $0.id == categoryID }), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, price >= 0 else {
            throw LocalDatabaseError.invalidInput("商品名稱、分類或價格無效")
        }
        if let id {
            guard let index = products.firstIndex(where: { $0.id == id }) else { throw LocalDatabaseError.missingRecord }
            let soldOut = products[index].isSoldOut
            products[index] = MenuProductRecord(id: id, categoryID: categoryID, name: name, price: price, isVisible: isVisible, isSoldOut: soldOut)
        } else {
            products.append(MenuProductRecord(id: nextID(products.map(\.id)), categoryID: categoryID, name: name, price: price, isVisible: isVisible, isSoldOut: false))
        }
    }

    mutating func deleteProduct(_ id: Int) throws {
        guard products.contains(where: { $0.id == id }) else { throw LocalDatabaseError.missingRecord }
        products.removeAll { $0.id == id }
        for index in toppings.indices { toppings[index] = ToppingRecord(id: toppings[index].id, groupID: toppings[index].groupID, name: toppings[index].name, price: toppings[index].price, menuItemIDs: toppings[index].menuItemIDs.filter { $0 != id }, selectionType: toppings[index].selectionType, isRequired: toppings[index].isRequired, isVisible: toppings[index].isVisible) }
    }

    mutating func saveToppingGroup(id: Int?, name: String, maxSelect: Int) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, maxSelect >= 0 else { throw LocalDatabaseError.invalidInput("請填寫正確的配料群組") }
        if let id {
            guard let index = toppingGroups.firstIndex(where: { $0.id == id }) else { throw LocalDatabaseError.missingRecord }
            toppingGroups[index] = ToppingGroupRecord(id: id, name: name, maxSelect: maxSelect)
        } else { toppingGroups.append(ToppingGroupRecord(id: nextID(toppingGroups.map(\.id)), name: name, maxSelect: maxSelect)) }
    }

    mutating func deleteToppingGroup(_ id: Int) throws {
        guard !toppings.contains(where: { $0.groupID == id }) else { throw LocalDatabaseError.linkedRecords("請先刪除或搬移群組內的配料") }
        guard toppingGroups.contains(where: { $0.id == id }) else { throw LocalDatabaseError.missingRecord }
        toppingGroups.removeAll { $0.id == id }
    }

    mutating func saveTopping(id: Int?, groupID: Int, name: String, price: Int, menuItemIDs: [Int], selectionType: String, isRequired: Bool, isVisible: Bool) throws {
        guard toppingGroups.contains(where: { $0.id == groupID }), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, price >= 0,
              ["single", "multi", "checkbox"].contains(selectionType),
              menuItemIDs.allSatisfy({ item in products.contains(where: { $0.id == item }) }) else {
            throw LocalDatabaseError.invalidInput("配料內容或適用商品無效")
        }
        // All options in a group must share one behavior. A temperature radio
        // group cannot silently be mixed with repeatable add-ons or checkboxes.
        guard !toppings.contains(where: {
            $0.groupID == groupID && $0.id != id && $0.selectionType != selectionType
        }) else {
            throw LocalDatabaseError.invalidInput("同一配料群組須使用同一選擇方式，請將單選／複選／勾選分開建立群組")
        }
        let actualID: Int
        if let id {
            guard toppings.contains(where: { $0.id == id }) else { throw LocalDatabaseError.missingRecord }
            actualID = id
            toppings.removeAll { $0.id == id }
        } else { actualID = nextID(toppings.map(\.id)) }
        toppings.append(ToppingRecord(id: actualID, groupID: groupID, name: name, price: price, menuItemIDs: Array(Set(menuItemIDs)).sorted(), selectionType: selectionType, isRequired: isRequired, isVisible: isVisible))
        toppings.sort { $0.id < $1.id }
    }

    mutating func deleteTopping(_ id: Int) throws {
        guard toppings.contains(where: { $0.id == id }) else { throw LocalDatabaseError.missingRecord }
        toppings.removeAll { $0.id == id }
    }

    mutating func setSoldOut(_ id: Int, _ value: Bool) throws {
        guard let index = products.firstIndex(where: { $0.id == id }) else { throw LocalDatabaseError.missingRecord }
        products[index].isSoldOut = value
    }

    mutating func addTable(_ name: String) throws {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw LocalDatabaseError.invalidInput("請填寫桌號") }
        tables.append(ShopTable(id: nextID(tables.map(\.id)), name: cleaned))
    }
    mutating func deleteTable(_ id: Int) { tables.removeAll { $0.id == id } }
    mutating func addPaymentMethod(_ name: String) throws {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw LocalDatabaseError.invalidInput("請填寫支付方式") }
        paymentMethods.append(PaymentMethod(id: nextID(paymentMethods.map(\.id)), name: cleaned))
    }
    mutating func deletePaymentMethod(_ id: Int) throws {
        guard paymentMethods.count > 1 else { throw LocalDatabaseError.invalidInput("至少保留一種支付方式") }
        paymentMethods.removeAll { $0.id == id }
    }

    private func nextID(_ ids: [Int]) -> Int { (ids.max() ?? 0) + 1 }
}
