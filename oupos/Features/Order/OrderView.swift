import SwiftUI

struct OrderView: View {
    @EnvironmentObject private var store: POSStore
    @State private var quantityTarget: CartItem?
    @State private var quantityDraft = ""
    @State private var quantityShouldReplace = true
    @State private var showClearConfirmation = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                CategorySidebar()
                    .frame(width: max(108, geometry.size.width * 0.13))

                VStack(spacing: 0) {
                    ProductGrid()
                        .frame(maxHeight: .infinity)
                    if store.selectedCartItem != nil {
                        ModifierPanel()
                            .frame(height: min(280, geometry.size.height * 0.42))
                    }
                }
                .frame(width: geometry.size.width * 0.56)

                CartPanel(
                    quantityTarget: $quantityTarget,
                    quantityDraft: $quantityDraft,
                    quantityShouldReplace: $quantityShouldReplace,
                    showClearConfirmation: $showClearConfirmation,
                )
                .frame(maxWidth: .infinity)
            }
        }
        .confirmationDialog("確定要清空購物車嗎？", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("清空", role: .destructive) { store.clearCart() }
            Button("取消", role: .cancel) {}
        }
        .overlay {
            if let target = quantityTarget {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
                    .onTapGesture { quantityTarget = nil }
                NumberKeypad(
                    title: "商品數量",
                    displayedValue: quantityDraft.isEmpty ? "0" : quantityDraft,
                    onDigit: {
                        quantityDraft = quantityShouldReplace ? String($0) : appended(quantityDraft, digit: $0, maximumDigits: 2)
                        quantityShouldReplace = false
                    },
                    onDecrement: {
                        quantityDraft = String(max(1, (Int(quantityDraft) ?? target.quantity) - 1))
                        quantityShouldReplace = true
                    },
                    onIncrement: {
                        quantityDraft = String(min(99, (Int(quantityDraft) ?? target.quantity) + 1))
                        quantityShouldReplace = true
                    },
                    onCancel: { quantityTarget = nil },
                    onConfirm: {
                        store.setQuantity(Int(quantityDraft) ?? 0, for: target.id)
                        quantityTarget = nil
                    }
                )
            }
        }
    }

    private func appended(_ value: String, digit: Int, maximumDigits: Int) -> String {
        let base = value == "0" ? "" : value
        return String((base + String(digit)).prefix(maximumDigits))
    }
}

private struct CategorySidebar: View {
    @EnvironmentObject private var store: POSStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(store.categories) { category in
                    Button {
                        store.selectedCategoryID = category.id
                    } label: {
                        Text(category.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(POSColor.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(store.selectedCategoryID == category.id ? POSColor.categorySelected : POSColor.categoryNormal)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .background(POSColor.surface)
        .overlay(alignment: .trailing) { Rectangle().fill(POSColor.border).frame(width: 1) }
    }
}

private struct ProductGrid: View {
    @EnvironmentObject private var store: POSStore

    var body: some View {
        GeometryReader { geometry in
            let columns = geometry.size.width < 570 ? 3 : 4
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                    ForEach(store.filteredProducts) { product in
                        ProductCard(product: product) { store.addProduct(product) }
                    }
                }
                .padding(16)
            }
        }
    }
}

private struct ProductCard: View {
    let product: Product
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(product.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(POSColor.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if product.isSoldOut {
                        Text("售完")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(POSColor.danger)
                            .clipShape(Capsule())
                    }
                }
                Spacer(minLength: 0)
                Text("$\(product.price)")
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(POSColor.textSecondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
            .background(POSColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(product.isSoldOut ? 0.72 : 1)
        }
        .buttonStyle(.plain)
        .disabled(product.isSoldOut)
        .accessibilityLabel("\(product.name)，\(product.price) 元\(product.isSoldOut ? "，已售完，無法購買" : "")")
    }
}

private struct ModifierPanel: View {
    @EnvironmentObject private var store: POSStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            if let item = store.selectedCartItem, !item.product.modifierGroups.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(item.product.modifierGroups) { group in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(spacing: 8) {
                                    Text(group.name).font(.system(size: 16, weight: .bold))
                                    if let mode = group.options.first?.selectionType {
                                        Text(mode == .single ? "擇一" : (mode == .multi ? "可重複加量" : "每項限選一次"))
                                            .font(.system(size: 12))
                                            .foregroundStyle(POSColor.textSecondary)
                                    }
                                    if group.maxSelect > 0 {
                                        Text("最多 \(group.maxSelect) 份／項")
                                            .font(.system(size: 12))
                                            .foregroundStyle(POSColor.textSecondary)
                                    }
                                }
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(group.options) { option in
                                            optionControl(option, in: group, item: item)
                                        }
                                    }
                                    // Leave room for the top-left decrement badge on multi toppings.
                                    .padding(.horizontal, 13)
                                    .padding(.top, 13)
                                    .padding(.bottom, 4)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                EmptyStateView(symbol: "slider.horizontal.3", message: store.selectedCartItem == nil ? "選擇商品後可調整配料" : "此商品沒有配料")
            }
        }
        .background(POSColor.surface)
    }

    /// One large tappable card per topping, as in the original ordering UI.
    /// Multi: tap the card to add one serving, top-left minus to remove one.
    /// Single / checkbox: tap to choose or unchoose; no decrement button.
    private func optionControl(_ option: ModifierOption, in group: ModifierGroup, item: CartItem) -> some View {
        let count = ModifierSelection.count(of: option, in: item.selectedModifiers)
        let chosen = count > 0
        let canAdd = ModifierSelection.canIncrement(option, in: group, selected: item.selectedModifiers)
        return Button {
            switch option.selectionType {
            case .multi: store.increaseModifier(option)
            case .single, .checkbox: store.toggleModifier(option)
            }
        } label: {
            VStack(spacing: 3) {
                Text(option.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if option.price > 0 {
                    Text("+\(option.price)")
                        .font(.system(size: 12))
                }
            }
            .foregroundStyle(POSColor.textPrimary)
            .frame(width: 92, height: 56)
            .background(modifierBackground(for: option.selectionType, chosen: chosen))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(chosen ? modifierBorder(for: option.selectionType) : .clear, lineWidth: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(option.selectionType == .multi && !canAdd)
        .opacity(option.selectionType == .multi && !canAdd ? 0.72 : 1)
        .accessibilityLabel("\(option.name)，\(option.selectionType.label)")
        .accessibilityValue(option.selectionType == .multi ? "\(count) 份" : (chosen ? "已選取" : "未選取"))
        .accessibilityHint(option.selectionType == .multi ? "點一下增加一份；已選取時可用左上角減號減少一份" : "點一下切換選取狀態")
        .overlay(alignment: .topTrailing) {
            if option.selectionType == .multi && chosen {
                Text("×\(count)")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 22)
                    .background(POSColor.primaryStrong)
                    .clipShape(Capsule())
                    .offset(x: 7, y: -10)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            if option.selectionType == .multi && chosen {
                Button {
                    store.decreaseModifier(option)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(POSColor.danger)
                        .clipShape(Circle())
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: -12, y: -12)
                .accessibilityLabel("減少一份\(option.name)，目前\(count)份")
            }
        }
    }

    private func modifierBackground(for type: ModifierSelectionType, chosen: Bool) -> Color {
        switch type {
        case .multi: chosen ? POSColor.modifierSelected : POSColor.modifierNormal
        case .single: chosen ? POSColor.modifierSingleSelected : POSColor.modifierSingleNormal
        case .checkbox: chosen ? POSColor.modifierCheckboxSelected : POSColor.modifierCheckboxNormal
        }
    }

    private func modifierBorder(for type: ModifierSelectionType) -> Color {
        switch type {
        case .multi: POSColor.success
        case .single: POSColor.modifierSingleBorder
        case .checkbox: POSColor.modifierCheckboxBorder
        }
    }

}

private struct CartPanel: View {
    @EnvironmentObject private var store: POSStore
    @Binding var quantityTarget: CartItem?
    @Binding var quantityDraft: String
    @Binding var quantityShouldReplace: Bool
    @Binding var showClearConfirmation: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("購物車")
                    .font(.system(size: 25, weight: .bold))
                Text("\(store.cartCount) 項")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(POSColor.textSecondary)
                Spacer()
                Button("清空", role: .destructive) { showClearConfirmation = true }
                    .font(.system(size: 15, weight: .semibold))
                    .disabled(store.cart.isEmpty)
            }
            .padding(16)

            Divider()

            if store.cart.isEmpty {
                EmptyStateView(symbol: "cart", message: "購物車目前沒有商品")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.cart) { item in
                            CartItemView(item: item) {
                                store.removeItem(item.id)
                            } select: {
                                store.selectedCartItemID = item.id
                            } quantity: {
                                quantityDraft = String(item.quantity)
                                quantityShouldReplace = true
                                quantityTarget = item
                            }
                        }
                    }
                    .padding(12)
                }
            }

            Divider()

            VStack(spacing: 12) {
                HStack {
                    Text("總計")
                        .font(.system(size: 18, weight: .bold))
                    Spacer()
                    Text("$\(store.cartTotal)")
                        .font(.system(size: 26, weight: .bold).monospacedDigit())
                }

                Button {
                    store.resetCheckout()
                    store.isCheckoutPresented = true
                } label: {
                    Label("結帳", systemImage: "cart.fill")
                }
                .buttonStyle(FilledActionButtonStyle(color: POSColor.primaryStrong, height: 60))
                .disabled(store.cart.isEmpty)
                .opacity(store.cart.isEmpty ? 0.45 : 1)
            }
            .padding(16)
        }
        .background(POSColor.surface)
        .overlay(alignment: .leading) { Rectangle().fill(POSColor.border).frame(width: 1) }
    }
}

private struct CartItemView: View {
    let item: CartItem
    let remove: () -> Void
    let select: () -> Void
    let quantity: () -> Void
    @EnvironmentObject private var store: POSStore

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 9) {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(POSColor.danger)
                        .frame(width: 34, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("刪除 \(item.product.name)")

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.product.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(POSColor.textPrimary)
                    if !item.selectedModifiers.isEmpty {
                        Text(item.modifierDescriptions.joined(separator: "  "))
                            .font(.system(size: 12))
                            .foregroundStyle(POSColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: quantity) {
                    Text("\(item.quantity)")
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .foregroundStyle(POSColor.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("修改 \(item.product.name) 數量，目前 \(item.quantity)")

                Text("$\(item.subtotal)")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(POSColor.textPrimary)
                    .frame(minWidth: 48, minHeight: 44, alignment: .trailing)
            }
            .padding(8)
            .background(store.selectedCartItemID == item.id ? Color(hex: 0xFFF0F0) : POSColor.surfaceSecondary)
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(store.selectedCartItemID == item.id ? POSColor.danger : .clear, lineWidth: 1.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

