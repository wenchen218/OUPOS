import Foundation

// This is an interchange format for menus produced by a human or an external AI.
// It is NOT the full POS backup format and never contains orders or accounts.
struct AIMenuPayload: Decodable {
    let schemaVersion: Int
    let categories: [String]
    let products: [AIProduct]
    let toppingGroups: [AIToppingGroup]
    let toppings: [AITopping]

    struct AIProduct: Decodable {
        let category: String
        let name: String
        let price: Int
    }
    struct AIToppingGroup: Decodable {
        let name: String
        let maxSelect: Int
    }
    struct ProductReference: Decodable {
        let category: String
        let name: String
    }
    struct AITopping: Decodable {
        let group: String
        let name: String
        let price: Int
        let selectionType: String
        let isRequired: Bool
        let appliesToCategories: [String]
        let appliesToProducts: [ProductReference]
    }
}

struct AIMenuImportSummary {
    var newCategories = 0
    var newProducts = 0
    var newGroups = 0
    var newToppings = 0
    var skippedExisting = 0

    var addedTotal: Int { newCategories + newProducts + newGroups + newToppings }
    var description: String {
        "分類 \(newCategories)、商品 \(newProducts)、配料群組 \(newGroups)、配料 \(newToppings)；已存在而略過 \(skippedExisting)"
    }
}

struct AIMenuImportPlan {
    let candidate: LocalPOSData
    let summary: AIMenuImportSummary
}

enum AIMenuImportError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let text): return text }
    }
}

enum AIMenuImporter {
    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_TW"))
    }

    private static func requireName(_ value: String, label: String) throws -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 100 else {
            throw AIMenuImportError.invalid("\(label)不能空白，且不可超過 100 個字")
        }
        return cleaned
    }

    /// Fix Markdown-escaped array brackets (\\[ / \\]) OUTSIDE JSON quoted strings.
    /// Also supports pasting a fenced ```json block. Does not alter valid JSON.
    static func cleanCopiedJSON(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8) else { return data }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let lineEnd = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: lineEnd)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if text.hasSuffix("```") { text = String(text.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let characters = Array(text)
        var output = ""
        output.reserveCapacity(characters.count)
        var withinString = false
        var escaped = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if withinString {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { withinString = false }
            } else if character == "\"" {
                withinString = true
                output.append(character)
            } else if character == "\\", index + 1 < characters.count,
                      characters[index + 1] == "[" || characters[index + 1] == "]" {
                index += 1
                output.append(characters[index])
            } else {
                output.append(character)
            }
            index += 1
        }
        return Data(output.utf8)
    }

    static func prepare(_ data: Data, current: LocalPOSData) throws -> AIMenuImportPlan {
        guard data.count <= 2_000_000 else { throw AIMenuImportError.invalid("JSON 檔案不可超過 2 MB") }
        let payload: AIMenuPayload
        do { payload = try JSONDecoder().decode(AIMenuPayload.self, from: cleanCopiedJSON(data)) }
        catch { throw AIMenuImportError.invalid("JSON 格式不符：請確認價格、選擇上限為整數，並包含所有指定欄位。\n\(error.localizedDescription)") }
        guard payload.schemaVersion == 1 else { throw AIMenuImportError.invalid("不支援的菜單 JSON 版本（須為 1）") }
        guard payload.categories.count <= 100, payload.products.count <= 3000,
              payload.toppingGroups.count <= 100, payload.toppings.count <= 6000 else {
            throw AIMenuImportError.invalid("單次匯入資料量過大，請分批匯入")
        }
        guard !(payload.categories.isEmpty && payload.products.isEmpty && payload.toppingGroups.isEmpty && payload.toppings.isEmpty) else {
            throw AIMenuImportError.invalid("JSON 沒有任何菜單資料")
        }
        var state = current
        var summary = AIMenuImportSummary()

        for raw in payload.categories {
            let name = try requireName(raw, label: "分類名稱")
            if state.categories.contains(where: { normalize($0.name) == normalize(name) }) {
                summary.skippedExisting += 1
            } else {
                try state.saveCategory(id: nil, name: name)
                summary.newCategories += 1
            }
        }

        for input in payload.products {
            let name = try requireName(input.name, label: "商品名稱")
            let cat = try requireName(input.category, label: "商品分類")
            guard let category = state.categories.first(where: { normalize($0.name) == normalize(cat) }) else {
                throw AIMenuImportError.invalid("商品「\(name)」所屬分類「\(cat)」不存在，請先放入 categories")
            }
            guard input.price >= 0 else { throw AIMenuImportError.invalid("商品「\(name)」價格不能為負數") }
            if state.products.contains(where: { $0.categoryID == category.id && normalize($0.name) == normalize(name) }) {
                summary.skippedExisting += 1
            } else {
                try state.saveProduct(id: nil, categoryID: category.id, name: name, price: input.price, isVisible: true)
                summary.newProducts += 1
            }
        }

        for input in payload.toppingGroups {
            let name = try requireName(input.name, label: "配料群組名稱")
            guard input.maxSelect >= 0 else { throw AIMenuImportError.invalid("配料群組「\(name)」的 maxSelect 不能小於 0") }
            if state.toppingGroups.contains(where: { normalize($0.name) == normalize(name) }) {
                summary.skippedExisting += 1
            } else {
                try state.saveToppingGroup(id: nil, name: name, maxSelect: input.maxSelect)
                summary.newGroups += 1
            }
        }

        for input in payload.toppings {
            let name = try requireName(input.name, label: "配料名稱")
            let groupName = try requireName(input.group, label: "配料群組")
            guard let group = state.toppingGroups.first(where: { normalize($0.name) == normalize(groupName) }) else {
                throw AIMenuImportError.invalid("配料「\(name)」所屬群組「\(groupName)」不存在，請先放入 toppingGroups")
            }
            guard input.price >= 0 else { throw AIMenuImportError.invalid("配料「\(name)」價格不能為負數") }
            guard ["single", "multi", "checkbox"].contains(input.selectionType) else {
                throw AIMenuImportError.invalid("配料「\(name)」的 selectionType 只能是 single、multi、checkbox")
            }
            var appliesTo: Set<Int> = []
            for rawCategory in input.appliesToCategories {
                let categoryName = try requireName(rawCategory, label: "配料適用分類")
                guard let category = state.categories.first(where: { normalize($0.name) == normalize(categoryName) }) else {
                    throw AIMenuImportError.invalid("配料「\(name)」的適用分類「\(categoryName)」不存在")
                }
                appliesTo.formUnion(state.products.filter { $0.categoryID == category.id }.map(\.id))
            }
            for productRef in input.appliesToProducts {
                let categoryName = try requireName(productRef.category, label: "適用商品分類")
                let productName = try requireName(productRef.name, label: "適用商品名稱")
                guard let category = state.categories.first(where: { normalize($0.name) == normalize(categoryName) }),
                      let product = state.products.first(where: { $0.categoryID == category.id && normalize($0.name) == normalize(productName) }) else {
                    throw AIMenuImportError.invalid("配料「\(name)」找不到適用商品「\(categoryName) / \(productName)」")
                }
                appliesTo.insert(product.id)
            }
            if state.toppings.contains(where: { $0.groupID == group.id && normalize($0.name) == normalize(name) }) {
                // Never replace an existing topping or its applied products without explicit editing.
                summary.skippedExisting += 1
            } else {
                try state.saveTopping(id: nil, groupID: group.id, name: name, price: input.price,
                                      menuItemIDs: Array(appliesTo).sorted(), selectionType: input.selectionType,
                                      isRequired: input.isRequired, isVisible: true)
                summary.newToppings += 1
            }
        }
        guard summary.addedTotal > 0 else { throw AIMenuImportError.invalid("所有項目都已存在，沒有需要新增的菜單資料") }
        return AIMenuImportPlan(candidate: state, summary: summary)
    }

    static let prompt = """
    我會上傳餐廳的菜單照片、PDF 或文字。請逐項讀取菜單，轉換成 OUPOS 可匯入的 JSON。只輸出一個有效 JSON 物件，不要 Markdown 程式碼框、前言、註解、貨幣符號或解釋。

    請完全遵守此結構（可依實際菜單新增多筆資料）：
    {
      "schemaVersion": 1,
      "categories": ["飲品"],
      "products": [
        {"category": "飲品", "name": "紅茶", "price": 30}
      ],
      "toppingGroups": [
        {"name": "加料", "maxSelect": 0}
      ],
      "toppings": [
        {
          "group": "加料", "name": "珍珠", "price": 10,
          "selectionType": "multi", "isRequired": false,
          "appliesToCategories": ["飲品"],
          "appliesToProducts": []
        }
      ]
    }

    規則：
    1. categories 為分類名稱陣列；products.category 必須與其中一個分類名稱完全相同。
    2. 商品及配料價格使用整數，不要加「元」或「$」，例如 30；零元明確寫 0。切勿自行猜測價格。若任何價格在原始菜單無法辨認，先向我提問確認，再產生 JSON。
    3. 沒有配料時，toppingGroups 和 toppings 都輸出 []。不要虛構配料或商品。
    4. toppingGroups 為配料群組。maxSelect 為最多選幾項，0 代表不限；沒有註明選取限制就填 0。
    5. toppings.group 必須對應 toppingGroups.name。selectionType 只能用 single（單選）、multi（複選）、checkbox（勾選）。isRequired 只有菜單寫明必選才設 true，否則 false。
    6. appliesToCategories 是該配料適用的完整商品分類，會自動套用到該分類全部商品；appliesToProducts 只用於指定個別商品，每筆必須包含 category 與 name。兩者可以並用；若原始菜單無法判定適用範圍，兩者都填 []，讓店家稍後手動編輯，絕不可任意套用全部商品。
    7. 各分類、商品及群組名稱需一致，避免錯字；不要放入 ID、會員、訂單、商家資訊或任何非上述欄位。
    8. 不要把這段範例「飲品、紅茶、珍珠」當成實際菜單，應完全根據我上傳的內容產生資料。
    """
}
