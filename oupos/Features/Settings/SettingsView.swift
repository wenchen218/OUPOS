import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case menu = "菜單與配料"
    case tables = "桌號"
    case devices = "出單機"
    case payments = "支付方式"
    case backup = "備份還原"
    case staff = "員工帳號"
    var id: String { rawValue }
}

struct SettingsView: View {
    @State private var selected: SettingsTab = .menu
    @EnvironmentObject private var store: POSStore
    var body: some View {
        if store.isAdministrator {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                ForEach(SettingsTab.allCases) { tab in
                    Button(tab.rawValue) { KeyboardDismissal.dismiss(); selected = tab }
                        .font(.system(size: 16, weight: selected == tab ? .bold : .medium))
                        .foregroundStyle(selected == tab ? POSColor.primaryStrong : POSColor.textPrimary)
                        .buttonStyle(.plain)
                        .padding(.vertical, 18)
                }
                Spacer()
            }.padding(.horizontal, 24).background(POSColor.surface)
            Group {
                switch selected {
                case .menu: CatalogLocalView()
                case .tables: TablesLocalView()
                case .devices: PrinterLocalView()
                case .payments: PaymentsLocalView()
                case .backup: SettingsPage(title: "備份還原") { LocalBackupView() }
                case .staff: StaffAccountsView()
                }
            }
            .id(selected)
        }
        } else {
            EmptyStateView(symbol: "lock.fill", message: "僅限管理員使用")
        }
    }
}

/// Numeric entry starts blank when creating a record. Zero is valid only when typed explicitly.
@MainActor
private func enteredNonNegativeInt(_ text: String, label: String, store: POSStore) -> Int? {
    guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else {
        store.errorMessage = "請輸入有效的\(label)（可填 0）"
        return nil
    }
    return value
}

private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.system(size: 27, weight: .bold))
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.immediately)
        .onDisappear { KeyboardDismissal.dismiss() }
    }
}

struct InventoryLocalView: View {
    @EnvironmentObject private var store: POSStore
    var body: some View {
        SettingsPage(title: "商品供應狀態") {
            ForEach(store.categories) { category in
                VStack(alignment: .leading, spacing: 10) {
                    Text(category.name).font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 12) {
                        ForEach(store.products.filter { $0.categoryID == category.id }) { product in
                            Button { store.toggleSoldOut(product) } label: {
                                HStack {
                                    Text(product.name).lineLimit(2)
                                    Spacer()
                                    Text(product.isSoldOut ? "售完" : "供應中")
                                        .foregroundStyle(product.isSoldOut ? POSColor.danger : POSColor.success)
                                }.padding(14)
                                    .background(POSColor.surfaceSecondary)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                        }
                    }
                }.posCard()
            }
            if store.categories.isEmpty { Text("請先在菜單管理建立分類和商品").foregroundStyle(POSColor.textSecondary) }
        }
    }
}

private enum CatalogSection: String, CaseIterable, Identifiable {
    case categories = "分類"
    case products = "商品"
    case groups = "配料群組"
    case toppings = "配料"
    var id: String { rawValue }
}
private struct CatalogLocalView: View {
    @State private var section: CatalogSection = .categories
    @State private var showingAIImport = false
    var body: some View {
        SettingsPage(title: "菜單管理") {
            HStack {
                Spacer()
                Button { KeyboardDismissal.dismiss(); showingAIImport = true } label: {
                    Label("AI 新增菜單", systemImage: "sparkles")
                }.buttonStyle(OUPOSAuthPrimaryButtonStyle(compact: true))
            }
            Picker("管理項目", selection: $section) {
                ForEach(CatalogSection.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            .onChange(of: section) { _, _ in KeyboardDismissal.dismiss() }
            Group {
                switch section {
                case .categories: LocalCategoriesView()
                case .products: LocalProductsView()
                case .groups: LocalToppingGroupsView()
                case .toppings: LocalToppingsView()
                }
            }
        }
        .sheet(isPresented: $showingAIImport) { AIMenuImportView() }
    }
}

private struct LocalCategoriesView: View {
    @EnvironmentObject private var store: POSStore
    @State private var id: Int?
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("分類名稱", text: $name).ouposAuthInput()
                Button(id == nil ? "新增分類" : "儲存") {
                    store.saveCategory(id: id, name: name)
                    if store.errorMessage == nil { id = nil; name = "" }
                }.buttonStyle(OUPOSAuthPrimaryButtonStyle(compact: true))
                Button("清空") { id = nil; name = "" }.buttonStyle(OUPOSAuthOutlineButtonStyle(compact: true))
            }.posCard()
            ForEach(store.menuCategories) { item in
                HStack {
                    Text(item.name).fontWeight(.semibold)
                    Spacer()
                    Button("編輯") { id = item.id; name = item.name }.buttonStyle(OUPOSAuthOutlineButtonStyle(compact: true))
                    Button("刪除", role: .destructive) { store.deleteCategory(item.id) }.buttonStyle(OUPOSAuthDestructiveButtonStyle())
                }.posCard()
            }
        }
    }
}

private struct LocalProductsView: View {
    @EnvironmentObject private var store: POSStore
    @State private var id: Int?
    @State private var name = ""
    @State private var price = ""
    @State private var categoryID = 0
    @State private var visible = true
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 12) {
                HStack {
                    TextField("商品名稱", text: $name).ouposAuthInput()
                    TextField("價格", text: $price).keyboardType(.numberPad).ouposAuthInput().frame(width: 120)
                    Picker("分類", selection: $categoryID) {
                        Text("請選擇").tag(0)
                        ForEach(store.menuCategories) { Text($0.name).tag($0.id) }
                    }.frame(width: 220)
                }
                HStack {
                    Toggle("在 POS 上顯示", isOn: $visible).frame(width: 180)
                    Spacer()
                    Button("清空") { reset() }.buttonStyle(OUPOSAuthOutlineButtonStyle(compact: true))
                    Button(id == nil ? "新增商品" : "儲存商品") {
                        guard let enteredPrice = enteredNonNegativeInt(price, label: "商品價格", store: store) else { return }
                        store.saveProduct(id: id, categoryID: categoryID, name: name, price: enteredPrice, isVisible: visible)
                        if store.errorMessage == nil { reset() }
                    }.buttonStyle(OUPOSAuthPrimaryButtonStyle(compact: true))
                }
            }.posCard()
            ForEach(store.menuCategories) { category in
                VStack(alignment: .leading, spacing: 10) {
                    Text(category.name).font(.headline)
                    ForEach(store.menuProducts.filter { $0.categoryID == category.id }) { product in
                        HStack {
                            Text(product.name).fontWeight(.medium)
                            Spacer()
                            Text("$\(product.price)")
                            if !product.isVisible { Text("隱藏").foregroundStyle(POSColor.textSecondary) }
                            Button("編輯") {
                                id = product.id; name = product.name; price = String(product.price)
                                categoryID = product.categoryID; visible = product.isVisible
                            }.buttonStyle(OUPOSAuthOutlineButtonStyle(compact: true))
                            Button("刪除", role: .destructive) { store.deleteProduct(product.id) }.buttonStyle(OUPOSAuthDestructiveButtonStyle())
                        }
                        Divider()
                    }
                }.posCard()
            }
        }
        .onAppear { if categoryID == 0 { categoryID = store.menuCategories.first?.id ?? 0 } }
    }
    private func reset() {
        id = nil; name = ""; price = ""; visible = true; categoryID = store.menuCategories.first?.id ?? 0
    }
}

private struct LocalToppingGroupsView: View {
    @EnvironmentObject private var store: POSStore
    @State private var id: Int?
    @State private var name = ""
    @State private var maxSelect = ""
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("配料群組名稱", text: $name).ouposAuthInput()
                TextField("最多選幾份／項（0 不限）", text: $maxSelect).keyboardType(.numberPad).ouposAuthInput().frame(width: 200)
                Button(id == nil ? "新增" : "儲存") {
                    guard let count = enteredNonNegativeInt(maxSelect, label: "可選項數", store: store) else { return }
                    store.saveToppingGroup(id: id, name: name, maxSelect: count)
                    if store.errorMessage == nil { id = nil; name = ""; maxSelect = "" }
                }.buttonStyle(OUPOSAuthPrimaryButtonStyle(compact: true))
            }.posCard()
            ForEach(store.toppingGroups) { group in
                HStack {
                    Text(group.name)
                    Spacer()
                    Text(group.maxSelect == 0 ? "不限份／項" : "最多 \(group.maxSelect) 份／項")
                    Button("編輯") { id = group.id; name = group.name; maxSelect = String(group.maxSelect) }.buttonStyle(OUPOSAuthOutlineButtonStyle(compact: true))
                    Button("刪除", role: .destructive) { store.deleteToppingGroup(group.id) }.buttonStyle(OUPOSAuthDestructiveButtonStyle())
                }.posCard()
            }
        }
    }
}

private struct LocalToppingsView: View {
    @EnvironmentObject private var store: POSStore
    @State private var id: Int?
    @State private var name = ""
    @State private var price = ""
    @State private var groupID = 0
    @State private var selectionType = "multi"
    @State private var required = false
    @State private var visible = true
    @State private var productIDs: Set<Int> = []
    @State private var selectedProductCategoryID = 0

    private var categoryProducts: [MenuProductRecord] {
        store.menuProducts.filter { $0.categoryID == selectedProductCategoryID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("配料名稱", text: $name).ouposAuthInput()
                    TextField("加價", text: $price).keyboardType(.numberPad).ouposAuthInput().frame(width: 110)
                    Picker("群組", selection: $groupID) {
                        Text("請選擇").tag(0)
                        ForEach(store.toppingGroups) { Text($0.name).tag($0.id) }
                    }.frame(width: 190)
                }
                HStack {
                    Picker("選擇方式", selection: $selectionType) {
                        Text("複選").tag("multi")
                        Text("單選").tag("single")
                        Text("勾選").tag("checkbox")
                    }.pickerStyle(.segmented).frame(width: 300)
                    Toggle("必選", isOn: $required).frame(width: 95)
                    Toggle("在 POS 顯示", isOn: $visible).frame(width: 170)
                    Spacer()
                    Button("清空") { reset() }.buttonStyle(OUPOSAuthOutlineButtonStyle(compact: true))
                    Button(id == nil ? "新增" : "儲存") {
                        guard let enteredPrice = enteredNonNegativeInt(price, label: "配料加價", store: store) else { return }
                        store.saveTopping(id: id, groupID: groupID, name: name, price: enteredPrice,
                                          menuItemIDs: Array(productIDs).sorted(), selectionType: selectionType,
                                          isRequired: required, isVisible: visible)
                        if store.errorMessage == nil { reset() }
                    }.buttonStyle(OUPOSAuthPrimaryButtonStyle(compact: true))
                }
                Text("複選：同一配料可重複加量（加蛋 ×5）；單選：同一群組只能選一項（去冰／微冰／熱）；勾選：可選不同項目，但每項只能一次（果醬）。請將溫度、甜度等獨立設成不同單選群組。")
                    .font(.footnote)
                    .foregroundStyle(POSColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("適用商品（可多選）").font(.headline)
                    Spacer()
                    Text("共選取 \(productIDs.count) 項")
                        .font(.callout).foregroundStyle(POSColor.textSecondary)
                }
                HStack(spacing: 12) {
                    Picker("商品分類", selection: $selectedProductCategoryID) {
                        Text("請選擇分類").tag(0)
                        ForEach(store.menuCategories) { category in
                            Text(category.name).tag(category.id)
                        }
                    }.frame(width: 250)
                    Button("全選此分類") {
                        productIDs = CategoryProductSelection.update(
                            productIDs, categoryID: selectedProductCategoryID,
                            products: store.menuProducts, selectAll: true
                        )
                    }.buttonStyle(OUPOSAuthPrimaryButtonStyle(compact: true)).disabled(categoryProducts.isEmpty)
                    Button("取消此分類的選取") {
                        productIDs = CategoryProductSelection.update(
                            productIDs, categoryID: selectedProductCategoryID,
                            products: store.menuProducts, selectAll: false
                        )
                    }.buttonStyle(OUPOSAuthOutlineButtonStyle(compact: true))
                        .disabled(!categoryProducts.contains(where: { productIDs.contains($0.id) }))
                }
                if categoryProducts.isEmpty {
                    Text(store.menuCategories.isEmpty ? "請先建立商品分類" : "此分類目前沒有商品")
                        .font(.callout).foregroundStyle(POSColor.textSecondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 165))], spacing: 8) {
                        ForEach(categoryProducts) { product in
                            Button {
                                if productIDs.contains(product.id) { productIDs.remove(product.id) }
                                else { productIDs.insert(product.id) }
                            } label: {
                                Label(product.name, systemImage: productIDs.contains(product.id) ? "checkmark.square.fill" : "square")
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(OUPOSAuthOutlineButtonStyle(compact: true))
                        }
                    }
                }
            }.posCard()
            ForEach(store.toppingGroups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.name).font(.headline)
                    ForEach(store.toppings.filter { $0.groupID == group.id }) { topping in
                        HStack {
                            Text(topping.name)
                            Spacer()
                            Text("+$\(topping.price)")
                            Text(ModifierSelectionType(rawValue: topping.selectionType)?.label ?? "勾選")
                                .foregroundStyle(POSColor.textSecondary)
                            Text("適用 \(topping.menuItemIDs.count) 項").foregroundStyle(POSColor.textSecondary)
                            Button("編輯") {
                                id = topping.id; name = topping.name; price = String(topping.price); groupID = topping.groupID
                                selectionType = topping.selectionType; required = topping.isRequired; visible = topping.isVisible
                                productIDs = Set(topping.menuItemIDs)
                                selectedProductCategoryID = store.menuProducts.first(where: { productIDs.contains($0.id) })?.categoryID
                                    ?? store.menuCategories.first?.id ?? 0
                            }.buttonStyle(OUPOSAuthOutlineButtonStyle(compact: true))
                            Button("刪除", role: .destructive) { store.deleteTopping(topping.id) }.buttonStyle(OUPOSAuthDestructiveButtonStyle())
                        }
                        Divider()
                    }
                }.posCard()
            }
        }
        .onAppear {
            if groupID == 0 { groupID = store.toppingGroups.first?.id ?? 0 }
            if selectedProductCategoryID == 0 { selectedProductCategoryID = store.menuCategories.first?.id ?? 0 }
        }
        .onChange(of: groupID) { _, newGroupID in
            // When adding to a group, default to its existing selection behavior.
            if id == nil, let existing = store.toppings.first(where: { $0.groupID == newGroupID }) {
                selectionType = existing.selectionType
            }
        }
    }
    private func reset() {
        id = nil; name = ""; price = ""; groupID = store.toppingGroups.first?.id ?? 0
        selectionType = "multi"; required = false; visible = true; productIDs = []
    }
}

private struct TablesLocalView: View {
    @EnvironmentObject private var store: POSStore
    @State private var name = ""
    var body: some View {
        SettingsPage(title: "桌號與取餐位置") {
            HStack {
                TextField("新增桌號或取餐位置", text: $name).ouposAuthInput()
                Button("新增") { store.addTable(name); if store.errorMessage == nil { name = "" } }.buttonStyle(OUPOSAuthPrimaryButtonStyle(compact: true))
            }.posCard()
            ForEach(store.tables) { item in
                HStack {
                    Text(item.name)
                    Spacer()
                    Button("刪除", role: .destructive) { store.deleteTable(item.id) }.buttonStyle(OUPOSAuthDestructiveButtonStyle())
                }.posCard()
            }
        }
    }
}

private struct PaymentsLocalView: View {
    @EnvironmentObject private var store: POSStore
    @State private var name = ""
    var body: some View {
        SettingsPage(title: "本機支付方式") {
            Text("此處僅記錄訂單的支付方式，不連接任何金流。")
                .font(.callout).foregroundStyle(POSColor.textSecondary)
            HStack {
                TextField("新增支付方式", text: $name).ouposAuthInput()
                Button("新增") { store.addPaymentMethod(name); if store.errorMessage == nil { name = "" } }.buttonStyle(OUPOSAuthPrimaryButtonStyle(compact: true))
            }.posCard()
            ForEach(store.paymentMethods) { method in
                HStack {
                    Label(method.name, systemImage: method.symbol)
                    Spacer()
                    Button("刪除", role: .destructive) { store.deletePaymentMethod(method.id) }.buttonStyle(OUPOSAuthDestructiveButtonStyle())
                }.posCard()
            }
        }
    }
}

private struct PrinterLocalView: View {
    @EnvironmentObject private var store: POSStore
    @AppStorage(ReceiptFormatter.mirrorSettingKey) private var correctHorizontalMirror = true
    @AppStorage(ReceiptFormatter.reverseRowSettingKey) private var correctVerticalOrder = true
    @State private var host = ""
    @State private var port = ""
    @State private var width = 576
    var body: some View {
        SettingsPage(title: "區域網路出單機設定") {
            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("印表機 IP 位址") {
                    TextField("例如：192.168.1.100", text: $host).ouposAuthInput().frame(width: 270)
                }
                LabeledContent("TCP 連接埠") {
                    TextField("請輸入連接埠", text: $port).keyboardType(.numberPad).ouposAuthInput().frame(width: 160)
                }
                Picker("列印紙張寬度", selection: $width) {
                    Text("58mm（384 點）").tag(384)
                    Text("80mm（576 點）").tag(576)
                }.pickerStyle(.segmented).frame(maxWidth: 430)
                Toggle("修正收據上下列印順序（店名先、Logo 後）", isOn: $correctVerticalOrder)
                Text("預設開啟。若印表機先印 OUPOS Logo，請保持開啟；若店名與 Logo 顛倒則關閉。")
                    .font(.footnote).foregroundStyle(POSColor.textSecondary)
                Toggle("修正收據左右鏡像", isOn: $correctHorizontalMirror)
                Text("已預設開啟。若實際印出來文字方向正常，請關閉；如果整張收據左右顛倒，請開啟。")
                    .font(.footnote).foregroundStyle(POSColor.textSecondary)
                Button("儲存出單機設定") {
                    guard let value = UInt16(port), value > 0 else { store.errorMessage = "請輸入有效 TCP 連接埠"; return }
                    store.savePrinter(host: host, port: value, width: width)
                }.buttonStyle(OUPOSAuthPrimaryButtonStyle(compact: true))
            }.posCard()
        }
        .onAppear {
            host = store.printerTarget.host
            port = store.printerTarget.host.isEmpty ? "" : String(store.printerTarget.port)
            width = store.printerTarget.width
        }
    }
}
