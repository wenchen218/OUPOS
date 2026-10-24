import SwiftUI

struct ToastData: Equatable { let message: String }

struct RootView: View {
    @EnvironmentObject private var store: POSStore
    @EnvironmentObject private var merchant: LocalMerchantStore

    var body: some View {
        ZStack {
            if merchant.businessName == nil {
                LocalMerchantSetupView()
            } else if store.isSignedIn {
                VStack(spacing: 0) {
                    TopNavigationBar().frame(height: 62)
                    Group {
                        switch store.currentTab {
                        case .order:
                            if store.isCheckoutPresented { CheckoutView() } else { OrderView() }
                        case .inventory: InventoryLocalView()
                        case .reports: if store.isAdministrator { ReportsView() } else { OrderView() }
                        case .settings: if store.isAdministrator { SettingsView() } else { OrderView() }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(POSColor.background)
                }
                .ignoresSafeArea()
                .overlay(alignment: .top) {
                    if let toast = store.toast { ToastView(message: toast.message).padding(.top, 72) }
                }
            } else {
                // Login owns the splash animation so the OUPOS logo can move
                // smoothly into the authentication screen instead of fading out.
                AccountGateView()
            }
        }
        .overlay {
            if store.isLoading && store.isSignedIn { LoadingOverlay() }
        }
        .alert("操作失敗", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "本機操作失敗") }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}

struct TopNavigationBar: View {
    @EnvironmentObject private var store: POSStore
    @EnvironmentObject private var merchant: LocalMerchantStore
    @State private var now = Date()
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("OUPOS").font(.system(size: 22, weight: .black)).foregroundStyle(.white)
                Text(merchant.businessName ?? "POS")
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(width: 165, alignment: .leading)
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                ForEach(store.availableTabs) { tab in
                    Button {
                        store.isCheckoutPresented = false
                        store.currentTab = tab
                        if tab == .reports { store.refreshReport() }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: tab.symbol).font(.system(size: 19, weight: .semibold))
                            Text(tab.rawValue).font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .frame(width: 85, height: 50)
                        .background(store.currentTab == tab && !store.isCheckoutPresented ? POSColor.selectedOrange : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: POSRadius.small))
                    }.buttonStyle(.plain)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(store.signedInUser?.username ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                    .font(.system(size: 12, weight: .medium))
                Text(now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                    .font(.system(size: 20, weight: .bold).monospacedDigit())
            }
            .foregroundStyle(.white)
            .frame(width: 115, alignment: .trailing)
            Button("登出") { store.signOut() }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .buttonStyle(.bordered)
                .tint(.white)
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        }
        .padding(.horizontal, 16)
        .background(POSColor.topBar)
    }
}

struct ToastView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background(POSColor.topBar.opacity(0.94))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.12), radius: 12, y: 3)
    }
}

struct LoadingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            ProgressView()
                .controlSize(.large)
                .padding(24)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: POSRadius.large))
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 38))
                .foregroundStyle(POSColor.textSecondary.opacity(0.65))
            Text(message)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(POSColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NumberKeypad: View {
    let title: String
    let displayedValue: String
    let onDigit: (Int) -> Void
    var onDecrement: (() -> Void)? = nil
    var onIncrement: (() -> Void)? = nil
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private let keys = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(POSColor.textSecondary)
            if let onDecrement, let onIncrement {
                HStack(spacing: 12) {
                    keypadButton("minus", color: POSColor.surface, foreground: POSColor.textPrimary, isSymbol: true, action: onDecrement)
                        .frame(width: 54)
                    Text(displayedValue)
                        .font(.system(size: 30, weight: .bold).monospacedDigit())
                        .frame(maxWidth: .infinity)
                    keypadButton("plus", color: POSColor.surface, foreground: POSColor.textPrimary, isSymbol: true, action: onIncrement)
                        .frame(width: 54)
                }
            } else {
                Text(displayedValue)
                    .font(.system(size: 30, weight: .bold).monospacedDigit())
                    .frame(maxWidth: .infinity)
            }

            ForEach(keys, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { digit in
                        keypadButton("\(digit)", color: .white, foreground: POSColor.textPrimary) { onDigit(digit) }
                    }
                }
            }

            HStack(spacing: 8) {
                keypadButton("xmark", color: POSColor.danger, foreground: .white, isSymbol: true, action: onCancel)
                keypadButton("0", color: .white, foreground: POSColor.textPrimary) { onDigit(0) }
                keypadButton("checkmark", color: POSColor.success, foreground: .white, isSymbol: true, action: onConfirm)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(14)
        .frame(width: 252)
        .background(Color(hex: 0xF4F4F4))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 3)
    }

    private func keypadButton(_ value: String, color: Color, foreground: Color, isSymbol: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isSymbol { Image(systemName: value) } else { Text(value) }
            }
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

