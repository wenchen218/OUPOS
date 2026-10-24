import SwiftUI
import Combine
import UIKit

@main
@MainActor
struct ouposApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: POSStore
    @StateObject private var merchant: LocalMerchantStore

    init() {
        _store = StateObject(wrappedValue: POSStore())
        _merchant = StateObject(wrappedValue: LocalMerchantStore())
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                POSColor.topBar.ignoresSafeArea()
                RootView()
                    .environmentObject(store)
                    .environmentObject(merchant)
            }
            .preferredColorScheme(.light)
            .onAppear {
                store.retryAccountAccess()
                if scenePhase == .active { LocalNetworkPermissionPrimer.shared.requestAtLaunch() }
            }
            // The Keychain accessibility class is WhenUnlockedThisDeviceOnly.
            // Retry after iPad finishes unlocking, not while data is protected.
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                store.retryAccountAccess()
            }
            .ignoresSafeArea(edges: .top)
            .onChange(of: scenePhase) { _, phase in
                if phase == .inactive || phase == .background {
                    // iPad lock, app switch or multitasking must not preserve a
                    // hidden first responder that reopens the keyboard later.
                    KeyboardDismissal.dismiss()
                }
                if phase == .background { store.handleSceneBackground() }
                if phase == .active {
                    KeyboardDismissal.dismiss()
                    store.validateActiveSession()
                    LocalNetworkPermissionPrimer.shared.requestAtLaunch()
                }
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                store.validateActiveSession()
            }
        }
    }
}
