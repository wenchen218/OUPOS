import SwiftUI

struct CheckoutView: View {
    @EnvironmentObject private var store: POSStore
    @State private var cashDraft = ""
    @State private var cashShouldReplace = true
    @State private var showCashKeypad = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Button {
                            store.isCheckoutPresented = false
                        } label: {
                            Label("返回點餐", systemImage: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(POSColor.primaryStrong)
                        Spacer()
                        Text("結帳")
                            .font(.system(size: 28, weight: .bold))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("支付方式")
                            .font(.system(size: 22, weight: .bold))

                        HStack(spacing: 14) {
                            ForEach(store.paymentMethods) { method in
                                PaymentMethodCard(method: method, selected: store.paymentMethod == method) {
                                    store.paymentMethod = method
                                    if method.isCash {
                                        cashDraft = store.cashReceived.map(String.init) ?? String(store.cartTotal)
                                        cashShouldReplace = true
                                        showCashKeypad = true
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                            Text("桌號／取餐位置")
                                .font(.system(size: 22, weight: .bold))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(store.tables) { table in tableButton(table.name) }
                                }
                            }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("訂單備註")
                            .font(.system(size: 22, weight: .bold))
                        TextEditor(text: $store.orderNote)
                            .font(.system(size: 16))
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .background(POSColor.surface)
                            .overlay { RoundedRectangle(cornerRadius: 8).stroke(POSColor.border) }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .frame(maxHeight: .infinity)
                    }
                }
                .padding(20)
                .frame(width: geometry.size.width * 0.69)

                CheckoutCartSummary()
                    .frame(maxWidth: .infinity)
            }
        }
        .overlay {
            if showCashKeypad {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
                    .onTapGesture { showCashKeypad = false }
                NumberKeypad(
                    title: "實收金額",
                    displayedValue: "$\(cashDraft.isEmpty ? "0" : cashDraft)",
                    onDigit: { digit in
                        let base = cashShouldReplace || cashDraft == "0" ? "" : cashDraft
                        cashDraft = String((base + String(digit)).prefix(6))
                        cashShouldReplace = false
                    },
                    onCancel: { showCashKeypad = false },
                    onConfirm: {
                        store.cashReceived = cashDraft.isEmpty ? store.cartTotal : (Int(cashDraft) ?? store.cartTotal)
                        showCashKeypad = false
                    }
                )
            }
        }
    }

    private func tableButton(_ name: String) -> some View {
        Button(name) { store.orderTableName = name }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(POSColor.textPrimary)
            .padding(.horizontal, 18)
            .frame(minHeight: 48)
            .background(store.orderTableName == name ? POSColor.categorySelected : POSColor.surface)
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(store.orderTableName == name ? POSColor.primaryStrong : POSColor.border) }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .buttonStyle(.plain)
    }
}

private struct PaymentMethodCard: View {
    let method: PaymentMethod
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                paymentIcon
                    .frame(width: 44, height: 34)
                Text(method.name)
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(selected ? POSColor.primaryStrong : POSColor.textPrimary)
            .frame(maxWidth: 160, minHeight: 100)
            .background(selected ? POSColor.primary.opacity(0.15) : POSColor.surface)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? POSColor.primaryStrong : POSColor.border, lineWidth: selected ? 2.5 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("支付方式：\(method.name)\(selected ? "，已選取" : "")")
    }

    private var paymentIcon: some View {
        Image(systemName: method.symbol).font(.system(size: 28, weight: .semibold))
    }

}

private struct CheckoutCartSummary: View {
    @EnvironmentObject private var store: POSStore

    var body: some View {
        VStack(spacing: 0) {
            Text("購物車摘要")
                .font(.system(size: 23, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            Divider()

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.cart) { item in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.product.name)
                                    .font(.system(size: 15, weight: .semibold))
                                if !item.selectedModifiers.isEmpty {
                                    Text(item.modifierDescriptions.joined(separator: "、"))
                                        .font(.system(size: 12))
                                        .foregroundStyle(POSColor.textSecondary)
                                }
                            }
                            Spacer()
                            Text("×\(item.quantity)")
                                .font(.system(size: 14).monospacedDigit())
                            Text("$\(item.subtotal)")
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                                .frame(width: 58, alignment: .trailing)
                        }
                        .padding(11)
                        .background(POSColor.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(12)
            }

            Divider()
            VStack(spacing: 10) {
                amountRow("總計", store.cartTotal, weight: .bold)
                if store.paymentMethod?.isCash == true, let cash = store.cashReceived {
                    amountRow("實收", cash, weight: .medium)
                    if cash >= store.cartTotal {
                        amountRow("找零", cash - store.cartTotal, color: POSColor.success, size: 22, weight: .bold)
                    } else {
                        amountRow("尚差", store.cartTotal - cash, color: POSColor.danger, size: 22, weight: .bold)
                    }
                }

                if store.paymentMethod == nil {
                    Text("請先選擇支付方式")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(POSColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if store.hasUnavailableCartItems {
                    Label("已售完／停售：\(store.unavailableCartProductNames.joined(separator: "、"))。請先移除商品才能下單。", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(POSColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if store.hasMissingRequiredModifiers {
                    Text("請先選擇必選配料")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(POSColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if store.orderTableName.isEmpty {
                    Text("請選擇桌號")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(POSColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Toggle(isOn: $store.shouldPrintCurrentOrder) {
                    Label(store.shouldPrintCurrentOrder ? "出單：開啟" : "出單：關閉", systemImage: store.shouldPrintCurrentOrder ? "printer.fill" : "printer.slash.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                .toggleStyle(.switch)
                .tint(POSColor.success)
                .padding(.vertical, 4)

                Button {
                    Task { await store.submitOrder() }
                } label: {
                    HStack {
                        Text("下單")
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(FilledActionButtonStyle(color: POSColor.primaryStrong, height: 64))
                .disabled(!store.canSubmitOrder)
                .opacity(store.canSubmitOrder ? 1 : 0.45)
            }
            .padding(16)
        }
        .background(POSColor.surface)
        .overlay(alignment: .leading) { Rectangle().fill(POSColor.border).frame(width: 1) }
    }

    private func amountRow(_ label: String, _ amount: Int, color: Color = POSColor.textPrimary, size: CGFloat = 18, weight: Font.Weight) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("$\(amount)")
                .monospacedDigit()
        }
        .font(.system(size: size, weight: weight))
        .foregroundStyle(color)
    }
}

