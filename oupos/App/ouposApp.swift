import SwiftUI
import Combine

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
            .ignoresSafeArea(edges: .top)
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { store.handleSceneBackground() }
                if phase == .active { store.validateActiveSession() }
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                store.validateActiveSession()
            }
        }
    }
}
