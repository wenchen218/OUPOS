import Foundation
import Combine
import LocalAuthentication


/// A password reset is permitted ONLY after the iPad confirms Face ID / Touch ID.
/// Intentionally NEVER use .deviceOwnerAuthentication: that policy permits the
/// device passcode as a fallback, including after repeated biometric failures.
@MainActor
protocol AdministratorBiometricAuthenticating {
    func authenticate() async throws
}

enum AdministratorRecoveryError: LocalizedError {
    case biometricsUnavailable
    case biometricsLocked
    case authenticationFailed
    case cancelled
    case verificationRequired
    case verificationExpired
    case administratorMissing

    var errorDescription: String? {
        switch self {
        case .biometricsUnavailable:
            "這台 iPad 未設定可用的 Face ID／Touch ID，無法重設管理員密碼。請先在 iPad 系統設定中啟用生物辨識。"
        case .biometricsLocked:
            "生物辨識已被系統鎖定，不能改用裝置密碼重設管理員密碼。請先在 iPad 系統層級恢復生物辨識，再重新驗證。"
        case .authenticationFailed:
            "Face ID／Touch ID 驗證未通過，管理員密碼未變更。"
        case .cancelled:
            "已取消生物辨識，管理員密碼未變更。"
        case .verificationRequired:
            "請先通過 Face ID／Touch ID，才能重設管理員密碼。"
        case .verificationExpired:
            "驗證已逾時，請重新使用 Face ID／Touch ID。"
        case .administratorMissing:
            "無法找到本機管理員帳號，已拒絕重設密碼。"
        }
    }
}

@MainActor
struct SystemAdministratorBiometricAuthenticator: AdministratorBiometricAuthenticating {
    func authenticate() async throws {
        let context = LAContext()
        // Hide the system's 'Enter Password' fallback affordance.
        context.localizedFallbackTitle = ""
        context.localizedCancelTitle = "取消"

        // Biometric-only policy. NEVER retry with .deviceOwnerAuthentication.
        let policy: LAPolicy = .deviceOwnerAuthenticationWithBiometrics
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(policy, error: &evaluationError) else {
            throw Self.translate(evaluationError ?? AdministratorRecoveryError.biometricsUnavailable)
        }
        do {
            guard try await context.evaluatePolicy(policy, localizedReason: "驗證管理員身分後，才能重設 OUPOS 管理員密碼") else {
                throw AdministratorRecoveryError.authenticationFailed
            }
        } catch {
            throw Self.translate(error)
        }
    }

    private static func translate(_ error: Error) -> AdministratorRecoveryError {
        if let known = error as? AdministratorRecoveryError { return known }
        let nsError = error as NSError
        guard nsError.domain == LAError.errorDomain,
              let code = LAError.Code(rawValue: nsError.code) else {
            return .authenticationFailed
        }
        switch code {
        case .biometryLockout:
            return .biometricsLocked
        case .biometryNotAvailable, .biometryNotEnrolled:
            return .biometricsUnavailable
        case .userCancel, .systemCancel, .appCancel:
            return .cancelled
        default:
            return .authenticationFailed
        }
    }
}


enum AccountGate {
    case setup
    case login
    case authenticated(StaffProfile)
    case unavailable

    // Compare only the current state. Equatable synthesis is unnecessary for a
    // case that also carries a StaffProfile and can fail on some Xcode toolchains.
    var isSetup: Bool {
        if case .setup = self { return true }
        return false
    }

    var isLogin: Bool {
        if case .login = self { return true }
        return false
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

enum AdministratorRecoveryPhase {
    case idle
    case authenticating
    case verified(username: String)
    case completed(username: String)

    var isAuthenticating: Bool {
        if case .authenticating = self { return true }
        return false
    }
    var verifiedUsername: String? {
        if case let .verified(username) = self { return username }
        return nil
    }
    var completedUsername: String? {
        if case let .completed(username) = self { return username }
        return nil
    }
}

@MainActor
final class POSStore: ObservableObject {
    @Published var currentTab: MainTab = .order
    @Published private(set) var accountGate: AccountGate = .unavailable
    @Published private(set) var staffAccounts: [StaffProfile] = []
    @Published private(set) var administratorRecoveryPhase: AdministratorRecoveryPhase = .idle
    @Published private(set) var administratorRecoveryError: String?
    var signedInUser: StaffProfile? {
        if case let .authenticated(profile) = accountGate { return profile }
        return nil
    }
    var isSignedIn: Bool { signedInUser != nil }
    var isAdministrator: Bool { signedInUser?.role == .administrator }
    var availableTabs: [MainTab] { isAdministrator ? MainTab.allCases : [.order, .inventory] }
    @Published private(set) var categories: [ProductCategory] = []
    @Published private(set) var products: [Product] = []
    @Published private(set) var menuCategories: [MenuCategoryRecord] = []
    @Published private(set) var menuProducts: [MenuProductRecord] = []
    @Published private(set) var toppingGroups: [ToppingGroupRecord] = []
    @Published private(set) var toppings: [ToppingRecord] = []
    @Published private(set) var paymentMethods: [PaymentMethod] = []
    @Published private(set) var tables: [ShopTable] = []
    @Published private(set) var printerTarget = PrinterTarget.fallback
    @Published var selectedCategoryID: UUID?
    @Published var selectedCartItemID: UUID?
    @Published var cart: [CartItem] = []
    @Published var isCheckoutPresented = false
    @Published var paymentMethod: PaymentMethod?
    @Published var cashReceived: Int?
    @Published var shouldPrintCurrentOrder = true
    @Published var orderNote = ""
    @Published var orderTableName = ""
    @Published private(set) var report = ReportSummary.empty
    @Published private(set) var productSales = ProductSalesSummary.empty
    @Published var isLoading = false
    @Published var toast: ToastData?
    @Published var errorMessage: String?

    private let database: LocalPOSDatabase
    private let accounts: LocalAccountService
    private let biometrics: any AdministratorBiometricAuthenticating
    // Never publish the grant. A fresh, biometric-only success grants ONE reset
    // for at most two minutes, and closing the sheet or backgrounding revokes it.
    private var recoveryAttemptID: UUID?
    private var recoveryAdminID: UUID?
    private var recoveryGrantedAtUptime: TimeInterval?
    private let recoveryGrantLifetime: TimeInterval = 120
    private let printer: ReceiptPrinting
    private var local: LocalPOSData
    private var storageAvailable = true

    init(database: LocalPOSDatabase = LocalPOSDatabase(), printer: ReceiptPrinting = NetworkReceiptPrinter(),
         accounts: LocalAccountService? = nil,
         biometrics: (any AdministratorBiometricAuthenticating)? = nil) {
        self.database = database
        self.printer = printer
        // Actor-isolated dependencies must be created INSIDE the main-actor initializer.
        self.accounts = accounts ?? LocalAccountService()
        self.biometrics = biometrics ?? SystemAdministratorBiometricAuthenticator()
        do {
            if try self.accounts.needsSetup() {
                accountGate = .setup
            } else if let profile = try self.accounts.restoreSession() {
                accountGate = .authenticated(profile)
                if profile.role == .administrator { staffAccounts = try self.accounts.profiles() }
            } else {
                accountGate = .login
            }
        } catch {
            accountGate = .unavailable
            errorMessage = error.localizedDescription
        }
        do { local = try database.load() }
        catch {
            local = LocalPOSData()
            storageAvailable = false
            errorMessage = "無法讀取本機 POS 資料：\(error.localizedDescription)。請先備份，不要重新安裝 App。"
        }
        reloadCatalog()
        if isAdministrator && storageAvailable { refreshReportSync() }
    }

    var filteredProducts: [Product] {
        guard let selectedCategoryID else { return products }
        return products.filter { $0.categoryID == selectedCategoryID }
    }
    var selectedCartItem: CartItem? { cart.first { $0.id == selectedCartItemID } }
    var cartTotal: Int { cart.reduce(0) { $0 + $1.subtotal } }
    var cartCount: Int { cart.reduce(0) { $0 + $1.quantity } }

    /// Check the current persisted catalog, not the product snapshot inside the cart.
    /// A product may become sold out after it was added to an order.
    var unavailableCartProductNames: [String] {
        var names: [String] = []
        for item in cart {
            guard let record = local.products.first(where: { uuid($0.id, prefix: 4) == item.product.id }),
                  record.isVisible, !record.isSoldOut else {
                if !names.contains(item.product.name) { names.append(item.product.name) }
                continue
            }
        }
        return names
    }

    var hasUnavailableCartItems: Bool { !unavailableCartProductNames.isEmpty }

    var canSubmitOrder: Bool {
        guard isSignedIn, !cart.isEmpty, paymentMethod != nil, !isLoading,
              !orderTableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard paymentMethod?.isCash != true || (cashReceived ?? -1) >= cartTotal else { return false }
        return !hasMissingRequiredModifiers && !hasUnavailableCartItems
    }

    var hasMissingRequiredModifiers: Bool {
        cart.contains { item in
            guard let productRecord = local.products.first(where: { uuid($0.id, prefix: 4) == item.product.id }) else { return false }
            let requiredGroupIDs = Set(local.toppings.filter {
                $0.isVisible && $0.isRequired && $0.menuItemIDs.contains(productRecord.id)
            }.map(\.groupID))
            return requiredGroupIDs.contains(where: { groupID in
                let selectedIDs = Set(item.selectedModifiers.map(\.id))
                return !local.toppings.contains { topping in
                    topping.groupID == groupID && selectedIDs.contains(uuid(topping.id, prefix: 3))
                }
            })
        }
    }

    private func uuid(_ id: Int, prefix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-%04X-%012X", prefix, id))!
    }
    private func reloadCatalog() {
        let previousCategory = categories.first { $0.id == selectedCategoryID }?.name
        menuCategories = local.categories
        menuProducts = local.products
        toppingGroups = local.toppingGroups
        toppings = local.toppings
        tables = local.tables
        paymentMethods = local.paymentMethods
        printerTarget = local.printer
        categories = local.categories.map { ProductCategory(id: uuid($0.id, prefix: 1), name: $0.name) }
        products = local.products.map { item in
            let groups: [ModifierGroup] = local.toppingGroups.compactMap { group in
                let options = local.toppings.filter { $0.groupID == group.id && $0.isVisible && $0.menuItemIDs.contains(item.id) }
                    .map { ModifierOption(id: uuid($0.id, prefix: 3), name: $0.name, price: $0.price,
                                          selectionType: ModifierSelectionType(rawValue: $0.selectionType) ?? .checkbox) }
                guard !options.isEmpty else { return nil }
                return ModifierGroup(id: uuid(group.id, prefix: 2), name: group.name,
                                     maxSelect: group.maxSelect, options: options)
            }
            return Product(id: uuid(item.id, prefix: 4), categoryID: uuid(item.categoryID, prefix: 1), name: item.name,
                           price: item.price, isSoldOut: item.isSoldOut, isEnabled: item.isVisible, modifierGroups: groups)
        }.filter(\.isEnabled)
        selectedCategoryID = categories.first { $0.name == previousCategory }?.id ?? categories.first?.id
        // Refresh product snapshots in cart when catalog changes without discarding quantity or notes.
        cart = cart.compactMap { old in
            guard let updated = products.first(where: { $0.id == old.product.id }) else { return nil }
            let known = Set(updated.modifierGroups.flatMap(\.options))
            return CartItem(id: old.id, product: updated, quantity: old.quantity,
                            selectedModifiers: old.selectedModifiers.filter { known.contains($0) }, note: old.note)
        }
    }

    private func requireAuthorization(adminOnly: Bool = true) -> Bool {
        guard isSignedIn, !adminOnly || isAdministrator else {
            errorMessage = adminOnly ? "此操作僅限管理員" : "請先登入"
            return false
        }
        return true
    }

    /// Start a recovery attempt only from the unauthenticated login state.
    /// The system prompt MUST use .deviceOwnerAuthenticationWithBiometrics.
    func authenticateForAdministratorRecovery() async {
        guard accountGate.isLogin else {
            administratorRecoveryError = AdministratorRecoveryError.verificationRequired.localizedDescription
            return
        }
        revokeAdministratorRecovery()
        let attemptID = UUID()
        recoveryAttemptID = attemptID
        administratorRecoveryPhase = .authenticating
        do {
            try await biometrics.authenticate()
            // Reject late Face ID callbacks if the sheet was closed, a newer
            // attempt started, the app was backgrounded, or login has changed.
            guard recoveryAttemptID == attemptID, accountGate.isLogin else { return }
            let admin = try accounts.administratorProfile()
            recoveryAdminID = admin.id
            // System uptime is monotonic; changing the iPad clock cannot extend the grant.
            recoveryGrantedAtUptime = ProcessInfo.processInfo.systemUptime
            administratorRecoveryPhase = .verified(username: admin.username)
            recoveryAttemptID = nil
        } catch {
            guard recoveryAttemptID == attemptID else { return }
            revokeAdministratorRecovery()
            administratorRecoveryError = error.localizedDescription
        }
    }

    func resetAdministratorPassword(newPassword: String, confirmation: String) -> Bool {
        guard accountGate.isLogin, let adminID = recoveryAdminID,
              let grantedAt = recoveryGrantedAtUptime,
              let verifiedUsername = administratorRecoveryPhase.verifiedUsername else {
            administratorRecoveryError = AdministratorRecoveryError.verificationRequired.localizedDescription
            return false
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - grantedAt
        guard elapsed >= 0, elapsed <= recoveryGrantLifetime else {
            revokeAdministratorRecovery()
            administratorRecoveryError = AdministratorRecoveryError.verificationExpired.localizedDescription
            return false
        }
        guard newPassword == confirmation else {
            administratorRecoveryError = AccountError.confirmationMismatch.localizedDescription
            return false
        }
        do {
            try accounts.replaceAdministratorPassword(id: adminID, newPassword: newPassword)
            // Grant is single-use, even if the screen remains open.
            revokeAdministratorRecovery()
            administratorRecoveryPhase = .completed(username: verifiedUsername)
            return true
        } catch {
            // Keep a valid grant to fix an input error, but do not extend its TTL.
            administratorRecoveryError = error.localizedDescription
            return false
        }
    }

    func revokeAdministratorRecovery() {
        recoveryAttemptID = nil
        recoveryAdminID = nil
        recoveryGrantedAtUptime = nil
        administratorRecoveryPhase = .idle
        administratorRecoveryError = nil
    }

    /// Backgrounding revokes biometric password-reset permission, but DOES NOT
    /// sign out the 24-hour POS staff session.
    func handleSceneBackground() {
        revokeAdministratorRecovery()
    }

    /// Called on foreground and periodically while the app remains open.
    /// Expired, deleted, or password-changed accounts must lose access.
    func validateActiveSession() {
        guard let profile = signedInUser else { return }
        do {
            guard let current = try accounts.restoreSession(), current.id == profile.id else {
                lockAccountUI()
                return
            }
        } catch {
            lockAccountUI()
            accountGate = .unavailable
            errorMessage = "無法驗證登入狀態：\(error.localizedDescription)"
        }
    }

    func registerAdministrator(username: String, password: String, confirmation: String) {
        revokeAdministratorRecovery()
        guard accountGate.isSetup else { errorMessage = AccountError.setupComplete.localizedDescription; return }
        guard password == confirmation else { errorMessage = AccountError.confirmationMismatch.localizedDescription; return }
        do {
            let profile = try accounts.registerFirstAdmin(username: username, password: password)
            accountGate = .authenticated(profile)
            staffAccounts = try accounts.profiles()
            currentTab = .order
            refreshReportSync()
            showToast("管理員帳號已建立")
        } catch { errorMessage = error.localizedDescription }
    }

    func signIn(username: String, password: String) {
        guard accountGate.isLogin else { return }
        do {
            let profile = try accounts.signIn(username: username, password: password)
            revokeAdministratorRecovery()
            accountGate = .authenticated(profile)
            if profile.role == .administrator { staffAccounts = try accounts.profiles() }
            else { staffAccounts = [] }
            currentTab = .order
            if isAdministrator { refreshReportSync() }
            showToast("歡迎，\(profile.username)")
        } catch { errorMessage = error.localizedDescription }
    }

    func signOut() {
        revokeAdministratorRecovery()
        guard isSignedIn else { return }
        do { try accounts.endSession() }
        catch {
            errorMessage = "登出失敗，請重試：\(error.localizedDescription)"
            return // Never claim logout if the Keychain session survived.
        }
        lockAccountUI()
    }

    private func lockAccountUI() {
        revokeAdministratorRecovery()
        clearCart()
        accountGate = .login
        staffAccounts = []
        errorMessage = nil
        toast = nil
        report = .empty
        productSales = .empty
        currentTab = .order
        isCheckoutPresented = false
    }

    func createEmployee(username: String, password: String, confirmation: String) {
        guard requireAuthorization() else { return }
        guard password == confirmation else { errorMessage = AccountError.confirmationMismatch.localizedDescription; return }
        do {
            _ = try accounts.addEmployee(username: username, password: password)
            staffAccounts = try accounts.profiles()
            showToast("員工帳號已建立")
        } catch { errorMessage = error.localizedDescription }
    }

    func changeEmployeePassword(id: UUID, password: String, confirmation: String) {
        guard requireAuthorization() else { return }
        guard password == confirmation else { errorMessage = AccountError.confirmationMismatch.localizedDescription; return }
        do {
            try accounts.resetEmployeePassword(id: id, newPassword: password)
            showToast("員工密碼已更新")
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteEmployee(id: UUID) {
        guard requireAuthorization() else { return }
        do {
            try accounts.removeEmployee(id: id)
            staffAccounts = try accounts.profiles()
            showToast("員工帳號已刪除")
        } catch { errorMessage = error.localizedDescription }
    }

    private func change(_ success: String, adminOnly: Bool = true, _ update: (inout LocalPOSData) throws -> Void) {
        guard requireAuthorization(adminOnly: adminOnly) else { return }
        guard storageAvailable else { errorMessage = "本機資料無法安全載入，已禁止寫入，請先備份。"; return }
        do {
            var candidate = local
            try update(&candidate)
            try database.save(candidate)
            local = candidate
            reloadCatalog()
            showToast(success)
        } catch { errorMessage = "本機儲存失敗：\(error.localizedDescription)" }
    }
    /// Preview is read-only; commit reparses against current data to prevent stale previews.
    func previewAIMenuData(_ data: Data) -> AIMenuImportPlan? {
        guard requireAuthorization() else { return nil }
        guard storageAvailable else { errorMessage = "本機資料無法安全載入，已禁止匯入"; return nil }
        errorMessage = nil
        do { return try AIMenuImporter.prepare(data, current: local) }
        catch { errorMessage = "菜單 JSON 檢查失敗：\(error.localizedDescription)"; return nil }
    }

    @discardableResult
    func importAIMenuData(_ data: Data) -> Bool {
        guard requireAuthorization(), storageAvailable else { return false }
        errorMessage = nil
        do {
            let prepared = try AIMenuImporter.prepare(data, current: local)
            try database.save(prepared.candidate)
            local = prepared.candidate
            reloadCatalog()
            showToast("AI 菜單已新增：\(prepared.summary.description)")
            return true
        } catch {
            errorMessage = "匯入失敗（原本資料保留）：\(error.localizedDescription)"
            return false
        }
    }

    func saveCategory(id: Int?, name: String) { change("分類已儲存") { try $0.saveCategory(id: id, name: name) } }
    func deleteCategory(_ id: Int) { change("分類已刪除") { try $0.deleteCategory(id) } }
    func saveProduct(id: Int?, categoryID: Int, name: String, price: Int, isVisible: Bool) {
        change("商品已儲存") { try $0.saveProduct(id: id, categoryID: categoryID, name: name, price: price, isVisible: isVisible) }
    }
    func deleteProduct(_ id: Int) { change("商品已刪除") { try $0.deleteProduct(id) } }
    func saveToppingGroup(id: Int?, name: String, maxSelect: Int) {
        change("配料群組已儲存") { try $0.saveToppingGroup(id: id, name: name, maxSelect: maxSelect) }
    }
    func deleteToppingGroup(_ id: Int) { change("配料群組已刪除") { try $0.deleteToppingGroup(id) } }
    func saveTopping(id: Int?, groupID: Int, name: String, price: Int, menuItemIDs: [Int], selectionType: String, isRequired: Bool, isVisible: Bool) {
        change("配料已儲存") { try $0.saveTopping(id: id, groupID: groupID, name: name, price: price, menuItemIDs: menuItemIDs, selectionType: selectionType, isRequired: isRequired, isVisible: isVisible) }
    }
    func deleteTopping(_ id: Int) { change("配料已刪除") { try $0.deleteTopping(id) } }
    func toggleSoldOut(_ product: Product) {
        guard let record = local.products.first(where: { uuid($0.id, prefix: 4) == product.id }) else { return }
        change(!record.isSoldOut ? "已標記售完" : "已恢復供應", adminOnly: false) { try $0.setSoldOut(record.id, !record.isSoldOut) }
    }
    func addTable(_ name: String) { change("桌號已新增") { try $0.addTable(name) } }
    func deleteTable(_ id: Int) { change("桌號已刪除") { $0.deleteTable(id) } }
    func addPaymentMethod(_ name: String) { change("支付方式已新增") { try $0.addPaymentMethod(name) } }
    func deletePaymentMethod(_ id: Int) { change("支付方式已刪除") { try $0.deletePaymentMethod(id) } }
    func savePrinter(host: String, port: UInt16, width: Int) {
        guard width == 384 || width == 576, port > 0 else { errorMessage = "出單設定無效"; return }
        change("出單機設定已儲存") { $0.printer = PrinterTarget(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port, width: width) }
    }

    func addProduct(_ product: Product) {
        guard requireAuthorization(adminOnly: false) else { return }
        // The caller can hold a stale Product even after inventory was updated.
        guard let current = products.first(where: { $0.id == product.id }),
              !current.isSoldOut, current.isEnabled,
              let record = local.products.first(where: { uuid($0.id, prefix: 4) == current.id }),
              !record.isSoldOut, record.isVisible else {
            errorMessage = "此商品已售完或停售，無法加入購物車"
            return
        }
        let item = CartItem(id: UUID(), product: current, quantity: 1, selectedModifiers: [], note: "")
        cart.append(item)
        selectedCartItemID = item.id
    }
    /// Single = one option per group; checkbox = each option once;
    /// multi = add one more serving of the same option.
    func toggleModifier(_ option: ModifierOption) {
        changeModifier(option, action: .select)
    }
    func increaseModifier(_ option: ModifierOption) {
        changeModifier(option, action: .increment)
    }
    func decreaseModifier(_ option: ModifierOption) {
        changeModifier(option, action: .decrement)
    }
    private func changeModifier(_ option: ModifierOption, action: ModifierSelection.Action) {
        guard isSignedIn else { return }
        guard let selectedCartItemID,
              let index = cart.firstIndex(where: { $0.id == selectedCartItemID }) else { return }
        let item = cart[index]
        guard let group = item.product.modifierGroups.first(where: { group in
            group.options.contains(where: { $0.id == option.id })
        }), let currentOption = group.options.first(where: { $0.id == option.id }) else { return }
        cart[index].selectedModifiers = ModifierSelection.apply(action, to: currentOption,
                                          group: group, selected: item.selectedModifiers)
    }
    func setQuantity(_ quantity: Int, for itemID: UUID) {
        guard isSignedIn else { return }
        guard let index = cart.firstIndex(where: { $0.id == itemID }) else { return }
        if quantity <= 0 { removeItem(itemID) } else { cart[index].quantity = min(99, quantity) }
    }
    func removeItem(_ id: UUID) {
        cart.removeAll { $0.id == id }
        if selectedCartItemID == id { selectedCartItemID = cart.last?.id }
    }
    func clearCart() { cart.removeAll(); selectedCartItemID = nil; resetCheckout() }
    func resetCheckout() { paymentMethod = nil; cashReceived = nil; orderNote = ""; orderTableName = ""; shouldPrintCurrentOrder = true }

    func submitOrder() async {
        guard requireAuthorization(adminOnly: false) else { return }
        guard storageAvailable else { errorMessage = "資料讀取失敗，已禁止儲存。"; return }
        guard !hasUnavailableCartItems else {
            errorMessage = "購物車包含已售完或停售商品（\(unavailableCartProductNames.joined(separator: "、"))），請先移除後再下單。"
            return
        }
        guard canSubmitOrder, let paymentMethod else { return }
        let lines = cart.map { item in
            OrderLine(id: UUID(), name: item.product.name, productID: item.product.id, quantity: item.quantity, unitPrice: item.unitPrice,
                      modifiers: item.receiptModifiers, note: item.note.isEmpty ? nil : item.note)
        }
        let now = Date()
        let orderNumber: String
        do {
            orderNumber = try OrderNumberGenerator.generate(at: now,
                existingNumbers: Set(local.orders.map(\.number)))
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let order = POSOrder(id: UUID(), number: orderNumber,
                             createdAt: now, table: orderTableName, lines: lines, note: orderNote,
                             paymentMethod: paymentMethod.name, status: .completed)
        var candidate = local
        candidate.orders.append(order)
        candidate.nextOrderSequence += 1
        do {
            try database.save(candidate) // Persist FIRST, even if printer is offline.
        } catch {
            errorMessage = "訂單尚未儲存，請勿清空購物車：\(error.localizedDescription)"
            return
        }
        local = candidate
        let shouldPrint = shouldPrintCurrentOrder
        clearCart()
        isCheckoutPresented = false
        refreshReportSync()
        showToast("訂單已儲存在 iPad")
        if shouldPrint { await printReceipt(order, showSuccess: false) }
    }
    func reprint(_ order: POSOrder, showSuccess: Bool = true) async {
        guard requireAuthorization() else { return }
        await printReceipt(order, showSuccess: showSuccess)
    }
    private func printReceipt(_ order: POSOrder, showSuccess: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let businessName = UserDefaults.standard.string(forKey: LocalMerchantStore.businessNameKey)
            let mirror = UserDefaults.standard.object(forKey: ReceiptFormatter.mirrorSettingKey) as? Bool ?? true
            let receipt = ReceiptFormatter.makeReceipt(order: order, width: printerTarget.width,
                                                       businessName: businessName,
                                                       correctHorizontalMirror: mirror)
            try await printer.print(data: receipt, to: printerTarget)
            if showSuccess { showToast("已傳送至出單機") }
        } catch {
            errorMessage = "訂單保留在 iPad，但出單失敗：\(error.localizedDescription)。可在報表重新出單。"
        }
    }
    func cancelOrder(_ id: UUID) {
        change("已取消本機訂單") { data in
            guard let index = data.orders.firstIndex(where: { $0.id == id }) else { throw LocalDatabaseError.missingRecord }
            data.orders[index].status = .cancelled
        }
        refreshReportSync()
    }
    func loadOrderDetails(_ order: POSOrder) -> POSOrder? {
        guard isAdministrator else { return nil }
        return local.orders.first(where: { $0.id == order.id })
    }

    func refreshReport(startAt: Date? = nil, endAt: Date? = nil) {
        guard requireAuthorization() else { return }
        refreshReportSync(startAt: startAt, endAt: endAt)
    }
    static func defaultReportRange(now: Date = Date()) -> (start: Date, end: Date) {
        let start = Calendar.current.startOfDay(for: now)
        return (start, Calendar.current.date(byAdding: .day, value: 1, to: start) ?? now)
    }
    private func refreshReportSync(startAt: Date? = nil, endAt: Date? = nil) {
        guard isAdministrator else { report = .empty; productSales = .empty; return }
        let today = Self.defaultReportRange()
        let start = startAt ?? today.start
        let end = endAt ?? today.end
        let orders = local.orders.filter { $0.createdAt >= start && $0.createdAt < end }.sorted { $0.createdAt > $1.createdAt }
        let paid = orders.filter { $0.status != .cancelled }
        let byPayment = Dictionary(grouping: paid, by: \.paymentMethod)
        report = ReportSummary(revenue: paid.reduce(0) { $0 + $1.total }, orderCount: paid.count,
                               payments: byPayment.keys.sorted().enumerated().map { index, key in
                                   PaymentSlice(label: key, amount: (byPayment[key] ?? []).reduce(0) { $0 + $1.total }, colorIndex: index)
                               }, orders: orders)
        var stats: [String: (name: String, quantity: Int, gross: Int, orders: Set<UUID>)] = [:]
        for order in paid {
            for line in order.lines {
                let key = line.productID?.uuidString ?? line.name
                var item = stats[key] ?? (line.name, 0, 0, [])
                item.quantity += line.quantity
                item.gross += line.subtotal
                item.orders.insert(order.id)
                stats[key] = item
            }
        }
        let rows = stats.map { key, val in ProductSalesRow(id: key, name: val.name, quantity: val.quantity, orderCount: val.orders.count, grossSales: val.gross) }.sorted { $0.quantity > $1.quantity }
        productSales = ProductSalesSummary(productCount: rows.count, totalQuantity: rows.reduce(0) { $0 + $1.quantity },
                                           totalOrders: paid.count, grossSales: rows.reduce(0) { $0 + $1.grossSales }, products: rows)
    }
    func exportBackupData() -> Data? {
        guard requireAuthorization() else { return nil }
        do { return try JSONEncoder().encode(local) }
        catch { errorMessage = "無法產生備份：\(error.localizedDescription)"; return nil }
    }
    func importBackupData(_ data: Data) {
        guard requireAuthorization() else { return }
        do {
            let backup = try JSONDecoder().decode(LocalPOSData.self, from: data)
            guard backup.schemaVersion == 1, backup.nextOrderSequence > 0,
                  backup.products.allSatisfy({ product in backup.categories.contains { $0.id == product.categoryID } }),
                  backup.toppings.allSatisfy({ top in
                      backup.toppingGroups.contains { $0.id == top.groupID } &&
                      top.menuItemIDs.allSatisfy { id in backup.products.contains { $0.id == id } }
                  }) else { throw LocalDatabaseError.invalidSchema }
            try database.save(backup)
            local = backup
            storageAvailable = true
            clearCart()
            reloadCatalog()
            refreshReportSync()
            showToast("本機資料已還原")
        } catch { errorMessage = "還原失敗（原本資料保留）：\(error.localizedDescription)" }
    }

    func showToast(_ message: String) {
        toast = ToastData(message: message)
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if toast?.message == message { toast = nil }
        }
    }
}
