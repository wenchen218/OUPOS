import XCTest
import UIKit
@testable import oupos

@MainActor
final class ouposTests: XCTestCase {
    private final class MemoryAccountStorage: StaffAccountStorage {
        var vault = StaffAccountVault()
        func load() throws -> StaffAccountVault { vault }
        func save(_ value: StaffAccountVault) throws { vault = value }
    }

    @MainActor
    private final class FakeBiometrics: AdministratorBiometricAuthenticating {
        var accepted = false
        var attempts = 0
        func authenticate() async throws {
            attempts += 1
            guard accepted else { throw AdministratorRecoveryError.authenticationFailed }
        }
    }

    private func authorizedStore(database: LocalPOSDatabase) -> POSStore {
        let service = LocalAccountService(storage: MemoryAccountStorage())
        let store = POSStore(database: database, accounts: service)
        store.registerAdministrator(username: "owner", password: "secure-password-123", confirmation: "secure-password-123")
        XCTAssertTrue(store.isAdministrator)
        return store
    }

    private func temporaryDatabase() -> LocalPOSDatabase {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return LocalPOSDatabase(fileURL: directory.appendingPathComponent("pos-data.json"))
    }


    func testReceiptLogoAssetIsIncluded() {
        XCTAssertNotNil(UIImage(named: "ReceiptLogo"),
                        "ReceiptLogo.imageset must be included in the app target")
    }

    func testReceiptRasterOrientationCanBeCorrectedForPrinters() throws {
        let order = POSOrder(id: UUID(), number: "2610249977", createdAt: Date(), table: "內用",
            lines: [OrderLine(id: UUID(), name: "原味蛋餅", quantity: 1, unitPrice: 35,
                              modifiers: ["加蛋 ×2"], note: nil)],
            note: "不要袋子", paymentMethod: "LinePay", status: .completed)

        for width in [384, 576] {
            let plain = ReceiptFormatter.makeReceipt(order: order, width: width,
                businessName: "OUPOS早餐店", correctHorizontalMirror: false)
            let corrected = ReceiptFormatter.makeReceipt(order: order, width: width,
                businessName: "OUPOS早餐店", correctHorizontalMirror: true)
            XCTAssertNotEqual(plain, corrected)
            let normalRows = try receiptBitmapRows(plain)
            let mirroredRows = try receiptBitmapRows(corrected)
            XCTAssertEqual(normalRows.count, mirroredRows.count)
            XCTAssertFalse(normalRows.isEmpty)
            let rowBytes = width / 8
            var hasPrinting = false
            for row in normalRows.indices {
                for byte in 0..<rowBytes {
                    let sample = normalRows[row][rowBytes - byte - 1]
                    let reverseBits = (0..<8).reduce(UInt8(0)) { acc, bit in
                        acc | (((sample >> bit) & 1) << (7 - bit))
                    }
                    XCTAssertEqual(mirroredRows[row][byte], reverseBits)
                    if sample != 0 { hasPrinting = true }
                }
            }
            XCTAssertTrue(hasPrinting)
        }
    }

    private func receiptBitmapRows(_ bytes: Data) throws -> [[UInt8]] {
        let data = [UInt8](bytes)
        XCTAssertEqual(Array(data.prefix(2)), [0x1B, 0x40])
        var offset = 2
        var rows: [[UInt8]] = []
        while offset + 8 <= data.count, Array(data[offset..<(offset + 4)]) == [0x1D, 0x76, 0x30, 0] {
            let rowBytes = Int(data[offset + 4]) | (Int(data[offset + 5]) << 8)
            let blockRows = Int(data[offset + 6]) | (Int(data[offset + 7]) << 8)
            offset += 8
            XCTAssertTrue(rowBytes == 48 || rowBytes == 72)
            XCTAssertLessThanOrEqual(offset + rowBytes * blockRows, data.count)
            guard offset + rowBytes * blockRows <= data.count else { break }
            for _ in 0..<blockRows {
                rows.append(Array(data[offset..<(offset + rowBytes)]))
                offset += rowBytes
            }
        }
        XCTAssertEqual(Array(data[offset...]), [0x0A, 0x0A, 0x1D, 0x56, 0x00])
        return rows
    }

    func testMerchantSetupIsDeviceLocalAndRequiresAName() throws {
        let suite = "oupos-test-merchant-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let merchant = LocalMerchantStore(defaults: defaults)
        XCTAssertNil(merchant.businessName)
        XCTAssertFalse(merchant.saveBusinessName("   "))
        XCTAssertNil(merchant.businessName)
        XCTAssertTrue(merchant.saveBusinessName("  我的商店  "))
        XCTAssertEqual(merchant.businessName, "我的商店")
        XCTAssertEqual(defaults.string(forKey: LocalMerchantStore.businessNameKey), "我的商店")

        let restored = LocalMerchantStore(defaults: defaults)
        XCTAssertEqual(restored.businessName, "我的商店")
    }

    func testInitialDataIsLocalAndHasNoServerConfiguration() throws {
        let db = temporaryDatabase()
        let data = try db.load()
        XCTAssertTrue(data.categories.isEmpty)
        XCTAssertTrue(data.orders.isEmpty)
        XCTAssertEqual(data.printer.port, 9100)
        XCTAssertTrue(data.printer.host.isEmpty)
        XCTAssertEqual(data.paymentMethods.map(\.name), ["現金"])
    }

    func testCatalogPersistsAfterRestart() throws {
        let db = temporaryDatabase()
        var state = try db.load()
        try state.saveCategory(id: nil, name: "早餐")
        let category = try XCTUnwrap(state.categories.first)
        try state.saveProduct(id: nil, categoryID: category.id, name: "蛋餅", price: 40, isVisible: true)
        let product = try XCTUnwrap(state.products.first)
        try state.saveToppingGroup(id: nil, name: "加料", maxSelect: 2)
        let group = try XCTUnwrap(state.toppingGroups.first)
        try state.saveTopping(id: nil, groupID: group.id, name: "加起司", price: 10,
                              menuItemIDs: [product.id], selectionType: "multi", isRequired: false, isVisible: true)
        try state.setSoldOut(product.id, true)
        try db.save(state)

        let reloaded = try db.load()
        XCTAssertEqual(reloaded.categories.first?.name, "早餐")
        XCTAssertEqual(reloaded.products.first?.price, 40)
        XCTAssertEqual(reloaded.products.first?.isSoldOut, true)
        XCTAssertEqual(reloaded.toppings.first?.menuItemIDs, [product.id])
        XCTAssertThrowsError(try state.deleteCategory(category.id))
    }

    func testLocalCheckoutKeepsHistoryWhenPrinterIsDisabled() async throws {
        let db = temporaryDatabase()
        var state = try db.load()
        try state.saveCategory(id: nil, name: "飲品")
        let cat = try XCTUnwrap(state.categories.first)
        try state.saveProduct(id: nil, categoryID: cat.id, name: "紅茶", price: 25, isVisible: true)
        try db.save(state)
        let store = authorizedStore(database: db)
        store.addProduct(try XCTUnwrap(store.products.first))
        store.orderTableName = "外帶"
        store.paymentMethod = try XCTUnwrap(store.paymentMethods.first)
        store.cashReceived = 50
        store.shouldPrintCurrentOrder = false
        XCTAssertTrue(store.canSubmitOrder)
        await store.submitOrder()

        let restored = try db.load()
        XCTAssertEqual(restored.orders.count, 1)
        XCTAssertEqual(restored.orders[0].total, 25)
        XCTAssertEqual(restored.orders[0].lines[0].name, "紅茶")
        XCTAssertTrue(store.cart.isEmpty)
        XCTAssertEqual(store.report.revenue, 25)
    }

    func testOrderNumberUsesLocalYYMMDDAndFourDigits() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-22T16:30:00Z"))
        let taipei = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))
        // Local date is October 23, even though the UTC date is October 22.
        XCTAssertEqual(try OrderNumberGenerator.generate(at: date, existingNumbers: [],
            timeZone: taipei, randomIndex: { _ in 7 }), "2610230007")
    }

    func testOrderNumberDoesNotRepeatExistingOrCancelledNumbers() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z"))
        let taipei = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))
        let first = try OrderNumberGenerator.generate(at: date, existingNumbers: [],
            timeZone: taipei, randomIndex: { _ in 0 })
        let next = try OrderNumberGenerator.generate(at: date,
            existingNumbers: [first, "test-legacy"], timeZone: taipei,
            randomIndex: { _ in 0 })
        XCTAssertEqual(first, "2610220000")
        XCTAssertEqual(next, "2610220001")
        XCTAssertNotEqual(first, next)
        // A full day's allotment cannot silently duplicate a previously issued number.
        let all = Set((0..<10_000).map { "261022" + String(format: "%04d", $0) })
        XCTAssertThrowsError(try OrderNumberGenerator.generate(at: date,
            existingNumbers: all, timeZone: taipei))
    }

    func testSubmittedOrdersUseNewNumberAndKeepOldHistory() async throws {
        let db = temporaryDatabase()
        var state = try db.load()
        state.orders = [POSOrder(id: UUID(), number: "old-123",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), table: "外帶",
            lines: [], note: "", paymentMethod: "現金", status: .cancelled)]
        try db.save(state)
        let store = authorizedStore(database: db)
        store.saveCategory(id: nil, name: "飲料")
        let category = try XCTUnwrap(store.menuCategories.first)
        store.saveProduct(id: nil, categoryID: category.id, name: "紅茶", price: 25, isVisible: true)
        store.addProduct(try XCTUnwrap(store.products.first))
        store.orderTableName = "外帶"
        store.paymentMethod = try XCTUnwrap(store.paymentMethods.first)
        store.cashReceived = 50
        store.shouldPrintCurrentOrder = false
        await store.submitOrder()
        let orders = try db.load().orders
        XCTAssertEqual(orders.count, 2)
        XCTAssertEqual(orders[0].number, "old-123")
        XCTAssertEqual(orders[1].number.count, 10)
        XCTAssertEqual(orders[1].number, orders[1].number.filter(\.isNumber))
        XCTAssertEqual(orders[1].number.prefix(6), Self.localYYMMDD(at: orders[1].createdAt))
    }

    private static func localYYMMDD(at date: Date) -> Substring {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return Substring(String(format: "%02d%02d%02d", (parts.year ?? 0) % 100,
                                parts.month ?? 0, parts.day ?? 0))
    }

    func testSoldOutProductCannotBeAddedAndReturningToStockAllowsPurchase() async throws {
        let db = temporaryDatabase()
        let store = authorizedStore(database: db)
        store.saveCategory(id: nil, name: "飲料")
        let category = try XCTUnwrap(store.menuCategories.first)
        store.saveProduct(id: nil, categoryID: category.id, name: "綠茶", price: 35, isVisible: true)
        let oldProduct = try XCTUnwrap(store.products.first)
        store.toggleSoldOut(oldProduct)
        XCTAssertTrue(try XCTUnwrap(db.load().products.first).isSoldOut)

        store.addProduct(oldProduct) // old snapshot must NOT bypass inventory guard
        XCTAssertTrue(store.cart.isEmpty)
        store.orderTableName = "外帶"
        store.paymentMethod = try XCTUnwrap(store.paymentMethods.first)
        store.cashReceived = 40
        XCTAssertFalse(store.canSubmitOrder)
        await store.submitOrder()
        XCTAssertTrue(try db.load().orders.isEmpty)

        store.toggleSoldOut(try XCTUnwrap(store.products.first))
        store.addProduct(oldProduct) // still safe to use stale snapshot when item is in stock
        XCTAssertEqual(store.cart.count, 1)
        XCTAssertTrue(store.canSubmitOrder)
    }

    func testItemAlreadyInCartBlocksCheckoutAfterBecomingSoldOut() async throws {
        let db = temporaryDatabase()
        let store = authorizedStore(database: db)
        store.saveCategory(id: nil, name: "飲料")
        let category = try XCTUnwrap(store.menuCategories.first)
        store.saveProduct(id: nil, categoryID: category.id, name: "奶茶", price: 60, isVisible: true)
        let product = try XCTUnwrap(store.products.first)
        store.addProduct(product)
        store.orderTableName = "外帶"
        store.paymentMethod = try XCTUnwrap(store.paymentMethods.first)
        store.cashReceived = 100
        store.shouldPrintCurrentOrder = false
        XCTAssertTrue(store.canSubmitOrder)

        store.toggleSoldOut(product)
        XCTAssertEqual(store.unavailableCartProductNames, ["奶茶"])
        XCTAssertFalse(store.canSubmitOrder)
        await store.submitOrder() // must revalidate here, not only disable the UI button
        XCTAssertTrue(try db.load().orders.isEmpty)
        XCTAssertEqual(store.cart.count, 1)

        store.toggleSoldOut(try XCTUnwrap(store.products.first))
        XCTAssertTrue(store.unavailableCartProductNames.isEmpty)
        XCTAssertTrue(store.canSubmitOrder)
        await store.submitOrder()
        XCTAssertEqual(try db.load().orders.count, 1)
    }

    func testCancelOnlyChangesLocalRevenueNotHistory() async throws {
        let db = temporaryDatabase()
        var state = try db.load()
        let order = POSOrder(id: UUID(), number: "test-1", createdAt: Date(), table: "外帶",
                             lines: [OrderLine(id: UUID(), name: "咖啡", quantity: 2, unitPrice: 40, modifiers: [], note: nil)],
                             note: "", paymentMethod: "現金", status: .completed)
        state.orders = [order]
        try db.save(state)
        let store = authorizedStore(database: db)
        XCTAssertEqual(store.report.revenue, 80)
        store.cancelOrder(order.id)
        XCTAssertEqual(store.report.revenue, 0)
        let after = try db.load()
        XCTAssertEqual(after.orders.count, 1)
        XCTAssertEqual(after.orders[0].status, .cancelled)
    }

    func testToppingApplicableProductsSelectByCategoryWithoutLosingOtherCategories() throws {
        var state = LocalPOSData()
        try state.saveCategory(id: nil, name: "飲料")
        try state.saveCategory(id: nil, name: "餐點")
        let drinkCategory = try XCTUnwrap(state.categories.first)
        let mealCategory = try XCTUnwrap(state.categories.last)
        try state.saveProduct(id: nil, categoryID: drinkCategory.id, name: "紅茶", price: 25, isVisible: true)
        try state.saveProduct(id: nil, categoryID: drinkCategory.id, name: "綠茶", price: 25, isVisible: true)
        try state.saveProduct(id: nil, categoryID: mealCategory.id, name: "漢堡", price: 60, isVisible: true)
        let drinks = Set(state.products.filter { $0.categoryID == drinkCategory.id }.map(\.id))
        let meal = try XCTUnwrap(state.products.first(where: { $0.categoryID == mealCategory.id }))

        var selected: Set<Int> = [meal.id]
        selected = CategoryProductSelection.update(selected, categoryID: drinkCategory.id,
                                                    products: state.products, selectAll: true)
        XCTAssertEqual(selected, drinks.union([meal.id]))

        selected = CategoryProductSelection.update(selected, categoryID: drinkCategory.id,
                                                    products: state.products, selectAll: false)
        XCTAssertEqual(selected, [meal.id])

        // A category with no products must not affect existing selections.
        selected = CategoryProductSelection.update(selected, categoryID: 999,
                                                    products: state.products, selectAll: true)
        XCTAssertEqual(selected, [meal.id])
    }

    func testFirstLaunchRestores24HourSessionAndExpiresAfterOneDay() throws {
        let storage = MemoryAccountStorage()
        final class MockClock { var date = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = MockClock()
        let service = LocalAccountService(storage: storage, now: { clock.date })
        XCTAssertTrue(try service.needsSetup())
        let first = try service.registerFirstAdmin(username: "Owner", password: "secure-password-123")
        XCTAssertEqual(first.role, .administrator)
        XCTAssertThrowsError(try service.registerFirstAdmin(username: "other", password: "another-password"))
        XCTAssertFalse(try service.needsSetup())
        XCTAssertEqual(try service.signIn(username: "owner", password: "secure-password-123").id, first.id)
        clock.date.addTimeInterval(23 * 60 * 60)
        let restarted = POSStore(database: temporaryDatabase(), accounts: service)
        XCTAssertTrue(restarted.isAdministrator)
        restarted.handleSceneBackground()
        restarted.validateActiveSession()
        XCTAssertTrue(restarted.isSignedIn)
        clock.date.addTimeInterval(60 * 60 + 1)
        restarted.validateActiveSession()
        XCTAssertFalse(restarted.isSignedIn)
        XCTAssertTrue(restarted.accountGate.isLogin)
        XCTAssertNil(try service.restoreSession())
    }

    func testManualLogoutAndPasswordChangeInvalidateSavedSession() throws {
        let storage = MemoryAccountStorage()
        let service = LocalAccountService(storage: storage)
        let owner = try service.registerFirstAdmin(username: "owner", password: "owner-password-123")
        let firstStore = POSStore(database: temporaryDatabase(), accounts: service)
        XCTAssertTrue(firstStore.isAdministrator)
        firstStore.signOut()
        XCTAssertNil(try service.restoreSession())
        firstStore.signIn(username: "owner", password: "owner-password-123")
        XCTAssertEqual(try service.restoreSession()?.id, owner.id)
        let employee = try service.addEmployee(username: "cashier", password: "cashier-password-123")
        _ = try service.signIn(username: "cashier", password: "cashier-password-123")
        XCTAssertEqual(try service.restoreSession()?.id, employee.id)
        try service.resetEmployeePassword(id: employee.id, newPassword: "new-cashier-password-123")
        XCTAssertNil(try service.restoreSession())
        _ = try service.signIn(username: "cashier", password: "new-cashier-password-123")
        try service.removeEmployee(id: employee.id)
        XCTAssertNil(try service.restoreSession())
    }

    func testEmployeeCannotEditCatalogOrdersReportsOrBackupButMaySellAndToggleStock() async throws {
        let database = temporaryDatabase()
        let storage = MemoryAccountStorage()
        let service = LocalAccountService(storage: storage)
        let store = POSStore(database: database, accounts: service)
        store.registerAdministrator(username: "owner", password: "secure-password-123", confirmation: "secure-password-123")
        store.saveCategory(id: nil, name: "飲料")
        let category = try XCTUnwrap(store.menuCategories.first)
        store.saveProduct(id: nil, categoryID: category.id, name: "紅茶", price: 30, isVisible: true)
        let product = try XCTUnwrap(store.products.first)
        store.createEmployee(username: "helper", password: "helper-password-123", confirmation: "helper-password-123")
        store.signOut()
        XCTAssertFalse(store.isAdministrator)
        store.signIn(username: "helper", password: "helper-password-123")
        XCTAssertEqual(store.signedInUser?.role, .employee)
        XCTAssertEqual(store.availableTabs, [.order, .inventory])
        store.saveCategory(id: nil, name: "非法新增")
        store.saveProduct(id: nil, categoryID: category.id, name: "非法變價", price: 0, isVisible: true)
        XCTAssertEqual(store.menuCategories.count, 1)
        XCTAssertEqual(store.menuProducts.count, 1)
        XCTAssertNil(store.exportBackupData())
        store.cancelOrder(UUID())
        store.toggleSoldOut(product)
        XCTAssertTrue(try XCTUnwrap(database.load().products.first).isSoldOut)
        // Sold-out products cannot be added, even when staff invokes the store directly.
        store.addProduct(product)
        XCTAssertTrue(store.cart.isEmpty)
        XCTAssertFalse(store.canSubmitOrder)
        store.toggleSoldOut(try XCTUnwrap(store.products.first))
        XCTAssertFalse(try XCTUnwrap(database.load().products.first).isSoldOut)
        store.addProduct(try XCTUnwrap(store.products.first))
        store.orderTableName = "外帶"
        store.paymentMethod = try XCTUnwrap(store.paymentMethods.first)
        store.cashReceived = 100
        store.shouldPrintCurrentOrder = false
        XCTAssertTrue(store.canSubmitOrder)
        await store.submitOrder()
        XCTAssertEqual(try database.load().orders.count, 1)
        XCTAssertEqual(store.report.orderCount, 0) // Staff may not read revenue.
        store.signOut()
        XCTAssertFalse(store.canSubmitOrder)
        XCTAssertTrue(store.cart.isEmpty)
    }

    func testAdministratorCanManageEmployeesAndEmployeesCannotChangeAccounts() throws {
        let service = LocalAccountService(storage: MemoryAccountStorage())
        let store = POSStore(database: temporaryDatabase(), accounts: service)
        store.registerAdministrator(username: "owner", password: "secure-password-123", confirmation: "secure-password-123")
        store.createEmployee(username: "staff", password: "first-password", confirmation: "first-password")
        XCTAssertEqual(store.staffAccounts.count, 2)
        let staffID = try XCTUnwrap(store.staffAccounts.first(where: { $0.role == .employee })).id
        store.signOut()
        store.signIn(username: "staff", password: "first-password")
        store.createEmployee(username: "intruder", password: "some-password", confirmation: "some-password")
        XCTAssertEqual(try service.profiles().count, 2)
        store.signOut()
        store.signIn(username: "owner", password: "secure-password-123")
        store.changeEmployeePassword(id: staffID, password: "new-password", confirmation: "new-password")
        XCTAssertThrowsError(try service.signIn(username: "staff", password: "first-password"))
        XCTAssertEqual(try service.signIn(username: "staff", password: "new-password").id, staffID)
        store.deleteEmployee(id: staffID)
        XCTAssertEqual(try service.profiles().count, 1)
    }

    func testAdministratorResetRequiresBiometricAndNeverExposesOldPassword() async throws {
        let service = LocalAccountService(storage: MemoryAccountStorage())
        let fakeBiometrics = FakeBiometrics()
        let store = POSStore(database: temporaryDatabase(), accounts: service, biometrics: fakeBiometrics)
        store.registerAdministrator(username: "shop-owner", password: "original-password-123", confirmation: "original-password-123")
        store.createEmployee(username: "cashier", password: "employee-password-123", confirmation: "employee-password-123")
        store.signOut()

        // Even with knowledge of an administrator username, reset is blocked
        // until the OS biometrics-only API returns success.
        XCTAssertNil(store.administratorRecoveryPhase.verifiedUsername)
        XCTAssertFalse(store.resetAdministratorPassword(newPassword: "new-secret-123", confirmation: "new-secret-123"))
        for _ in 0..<2 { await store.authenticateForAdministratorRecovery() }
        XCTAssertEqual(fakeBiometrics.attempts, 2)
        XCTAssertNil(store.administratorRecoveryPhase.verifiedUsername)
        XCTAssertFalse(store.resetAdministratorPassword(newPassword: "new-secret-123", confirmation: "new-secret-123"))
        XCTAssertEqual(try service.signIn(username: "shop-owner", password: "original-password-123").role, .administrator)

        fakeBiometrics.accepted = true
        await store.authenticateForAdministratorRecovery()
        XCTAssertEqual(store.administratorRecoveryPhase.verifiedUsername, "shop-owner")
        XCTAssertFalse(store.resetAdministratorPassword(newPassword: "new-secret-123", confirmation: "wrong-confirmation"))
        XCTAssertTrue(store.resetAdministratorPassword(newPassword: "new-secret-123", confirmation: "new-secret-123"))
        XCTAssertEqual(store.administratorRecoveryPhase.completedUsername, "shop-owner")
        XCTAssertFalse(store.isSignedIn) // Reset must not bypass the login screen.
        XCTAssertFalse(store.resetAdministratorPassword(newPassword: "second-secret-123", confirmation: "second-secret-123"))
        XCTAssertThrowsError(try service.signIn(username: "shop-owner", password: "original-password-123"))
        XCTAssertEqual(try service.signIn(username: "shop-owner", password: "new-secret-123").role, .administrator)
        XCTAssertEqual(try service.signIn(username: "cashier", password: "employee-password-123").role, .employee)
    }

    func testAdministratorBiometricGrantRevokedOnDismissAndBackground() async throws {
        let service = LocalAccountService(storage: MemoryAccountStorage())
        let fakeBiometrics = FakeBiometrics()
        fakeBiometrics.accepted = true
        let store = POSStore(database: temporaryDatabase(), accounts: service, biometrics: fakeBiometrics)
        store.registerAdministrator(username: "owner", password: "initial-password-123", confirmation: "initial-password-123")
        store.signOut()
        await store.authenticateForAdministratorRecovery()
        XCTAssertNotNil(store.administratorRecoveryPhase.verifiedUsername)
        store.revokeAdministratorRecovery()
        XCTAssertFalse(store.resetAdministratorPassword(newPassword: "new-secret-123", confirmation: "new-secret-123"))

        await store.authenticateForAdministratorRecovery()
        store.handleSceneBackground()
        XCTAssertFalse(store.resetAdministratorPassword(newPassword: "new-secret-123", confirmation: "new-secret-123"))
        XCTAssertEqual(try service.signIn(username: "owner", password: "initial-password-123").role, .administrator)
    }

    private var sampleAIJSON: Data {
        Data("""
        {
          "schemaVersion": 1,
          "categories": ["飲品", "點心"],
          "products": [
            {"category":"飲品", "name":"紅茶", "price":30},
            {"category":"飲品", "name":"綠茶", "price":35},
            {"category":"點心", "name":"雞塊", "price":45}
          ],
          "toppingGroups": [{"name":"甜度", "maxSelect":1}],
          "toppings": [
            {"group":"甜度", "name":"無糖", "price":0, "selectionType":"single", "isRequired":false,
             "appliesToCategories":["飲品"], "appliesToProducts":[]},
            {"group":"甜度", "name":"另加甜", "price":5, "selectionType":"single", "isRequired":false,
             "appliesToCategories":[], "appliesToProducts":[{"category":"飲品", "name":"紅茶"}]}
          ]
        }
        """.utf8)
    }

    func testAIMenuPreviewAndImportMatchesApplicableCategoriesAndProducts() throws {
        let db = temporaryDatabase()
        let store = authorizedStore(database: db)
        let summary = try XCTUnwrap(store.previewAIMenuData(sampleAIJSON)).summary
        XCTAssertEqual(summary.newCategories, 2)
        XCTAssertEqual(summary.newProducts, 3)
        XCTAssertEqual(summary.newGroups, 1)
        XCTAssertEqual(summary.newToppings, 2)
        XCTAssertTrue(store.menuProducts.isEmpty) // Preview does not save.
        XCTAssertTrue(store.importAIMenuData(sampleAIJSON))
        let saved = try db.load()
        let teaIDs = Set(saved.products.filter { $0.categoryID == saved.categories.first(where: { $0.name == "飲品" })?.id }.map(\.id))
        let noSugar = try XCTUnwrap(saved.toppings.first(where: { $0.name == "無糖" }))
        XCTAssertEqual(Set(noSugar.menuItemIDs), teaIDs)
        let sweet = try XCTUnwrap(saved.toppings.first(where: { $0.name == "另加甜" }))
        XCTAssertEqual(sweet.menuItemIDs.count, 1)
        XCTAssertEqual(saved.products.first(where: { $0.id == sweet.menuItemIDs[0] })?.name, "紅茶")
        // Additive import refuses to overwrite existing prices and sold-out state.
        let tea = try XCTUnwrap(saved.products.first(where: { $0.name == "紅茶" }))
        store.toggleSoldOut(try XCTUnwrap(store.products.first(where: { $0.name == "紅茶" })))
        XCTAssertNil(store.previewAIMenuData(sampleAIJSON))
        XCTAssertEqual(try db.load().products.first(where: { $0.id == tea.id })?.isSoldOut, true)
    }

    func testAIMenuHandlesEscapedBracketsAndCodeFences() throws {
        let original = String(decoding: sampleAIJSON, as: UTF8.self)
        let escaped = original
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let pasted = "```json\n" + escaped + "\n```"
        let planned = try AIMenuImporter.prepare(Data(pasted.utf8), current: LocalPOSData())
        XCTAssertEqual(planned.summary.newCategories, 2)
        XCTAssertEqual(planned.summary.newProducts, 3)
        XCTAssertEqual(planned.summary.newToppings, 2)
    }

    func testAIMenuInvalidReferenceNeverChangesExistingState() throws {
        let db = temporaryDatabase()
        let store = authorizedStore(database: db)
        let invalid = Data("""
        {"schemaVersion":1,"categories":["飲品"],"products":[],"toppingGroups":[{"name":"加料","maxSelect":0}],
         "toppings":[{"group":"加料","name":"珍珠","price":10,"selectionType":"multi","isRequired":false,
         "appliesToCategories":[],"appliesToProducts":[{"category":"飲品","name":"不存在"}]}]}
        """.utf8)
        XCTAssertNil(store.previewAIMenuData(invalid))
        XCTAssertFalse(store.importAIMenuData(invalid))
        XCTAssertTrue(try db.load().categories.isEmpty)
    }

    func testAIMenuImportAdministratorOnly() throws {
        let db = temporaryDatabase()
        let store = authorizedStore(database: db)
        store.createEmployee(username: "cashier", password: "cashier-password-123", confirmation: "cashier-password-123")
        store.signOut()
        store.signIn(username: "cashier", password: "cashier-password-123")
        XCTAssertNil(store.previewAIMenuData(sampleAIJSON))
        XCTAssertFalse(store.importAIMenuData(sampleAIJSON))
        XCTAssertTrue(try db.load().products.isEmpty)
    }

    func testMultiToppingQuantityAndPrintedReceiptPrice() async throws {
        let db = temporaryDatabase()
        let store = authorizedStore(database: db)
        store.saveCategory(id: nil, name: "吐司")
        let category = try XCTUnwrap(store.menuCategories.first)
        store.saveProduct(id: nil, categoryID: category.id, name: "蛋吐司", price: 40, isVisible: true)
        let product = try XCTUnwrap(store.menuProducts.first)
        store.saveToppingGroup(id: nil, name: "加蛋", maxSelect: 0)
        let group = try XCTUnwrap(store.toppingGroups.first)
        store.saveTopping(id: nil, groupID: group.id, name: "加蛋", price: 15,
                          menuItemIDs: [product.id], selectionType: "multi", isRequired: false, isVisible: true)
        store.addProduct(try XCTUnwrap(store.products.first))
        let option = try XCTUnwrap(store.selectedCartItem?.product.modifierGroups.first?.options.first)
        // In v5.5 the full topping card invokes increaseModifier (once per tap).
        for _ in 0..<5 { store.increaseModifier(option) }
        XCTAssertEqual(ModifierSelection.count(of: option, in: try XCTUnwrap(store.selectedCartItem).selectedModifiers), 5)
        XCTAssertEqual(store.cartTotal, 115)
        XCTAssertEqual(store.selectedCartItem?.modifierDescriptions, ["加蛋 ×5"])
        XCTAssertEqual(store.selectedCartItem?.receiptModifiers, ["加蛋 ×5 +75"])
        store.decreaseModifier(option)
        XCTAssertEqual(store.cartTotal, 100)
        store.increaseModifier(option)
        store.orderTableName = "外帶"
        store.paymentMethod = try XCTUnwrap(store.paymentMethods.first)
        store.cashReceived = 200
        store.shouldPrintCurrentOrder = false
        await store.submitOrder()
        let order = try XCTUnwrap(try db.load().orders.last)
        XCTAssertEqual(order.total, 115)
        XCTAssertEqual(order.lines.first?.modifiers, ["加蛋 ×5 +75"])
    }

    func testSingleToppingIsExclusiveWithinGroupEvenWhenUnlimited() throws {
        let a = ModifierOption(id: UUID(), name: "去冰", price: 0, selectionType: .single)
        let b = ModifierOption(id: UUID(), name: "微冰", price: 0, selectionType: .single)
        let c = ModifierOption(id: UUID(), name: "熱", price: 0, selectionType: .single)
        let group = ModifierGroup(id: UUID(), name: "溫度", maxSelect: 0, options: [a, b, c])
        var chosen: [ModifierOption] = []
        chosen = ModifierSelection.apply(.select, to: a, group: group, selected: chosen)
        chosen = ModifierSelection.apply(.select, to: b, group: group, selected: chosen)
        XCTAssertEqual(chosen.map(\.name), ["微冰"])
        chosen = ModifierSelection.apply(.select, to: c, group: group, selected: chosen)
        XCTAssertEqual(chosen.map(\.name), ["熱"])
        chosen = ModifierSelection.apply(.select, to: c, group: group, selected: chosen)
        XCTAssertTrue(chosen.isEmpty)
    }

    func testCheckboxAllowsDifferentToppingsButNotRepeatedSameOne() throws {
        let options = ["草莓", "花生", "巧克力", "藍莓"].map {
            ModifierOption(id: UUID(), name: $0, price: 10, selectionType: .checkbox)
        }
        let group = ModifierGroup(id: UUID(), name: "果醬", maxSelect: 3, options: options)
        var chosen: [ModifierOption] = []
        for option in options.prefix(3) {
            chosen = ModifierSelection.apply(.select, to: option, group: group, selected: chosen)
        }
        XCTAssertEqual(chosen.count, 3)
        chosen = ModifierSelection.apply(.select, to: options[3], group: group, selected: chosen)
        XCTAssertEqual(chosen.count, 3)  // Group cap
        chosen = ModifierSelection.apply(.select, to: options[0], group: group, selected: chosen)
        XCTAssertEqual(chosen.count, 2)  // Tapping chosen checkbox removes it
        chosen = ModifierSelection.apply(.select, to: options[0], group: group, selected: chosen)
        XCTAssertEqual(chosen.count, 3)  // Re-select only once
        XCTAssertEqual(ModifierSelection.count(of: options[0], in: chosen), 1)
        XCTAssertEqual(ModifierSelection.descriptions(chosen).count, 3)
    }

    func testMultiGroupCapCountsTotalServingsAndPreventsMixedModes() throws {
        let egg = ModifierOption(id: UUID(), name: "加蛋", price: 15, selectionType: .multi)
        let cheese = ModifierOption(id: UUID(), name: "起司", price: 10, selectionType: .multi)
        let group = ModifierGroup(id: UUID(), name: "加料", maxSelect: 3, options: [egg, cheese])
        var chosen: [ModifierOption] = []
        for _ in 0..<5 { chosen = ModifierSelection.apply(.increment, to: egg, group: group, selected: chosen) }
        XCTAssertEqual(ModifierSelection.count(of: egg, in: chosen), 3)
        chosen = ModifierSelection.apply(.increment, to: cheese, group: group, selected: chosen)
        XCTAssertEqual(ModifierSelection.count(of: cheese, in: chosen), 0)
        chosen = ModifierSelection.apply(.decrement, to: egg, group: group, selected: chosen)
        chosen = ModifierSelection.apply(.increment, to: cheese, group: group, selected: chosen)
        XCTAssertEqual(ModifierSelection.count(of: egg, in: chosen), 2)
        XCTAssertEqual(ModifierSelection.count(of: cheese, in: chosen), 1)

        var data = LocalPOSData()
        try data.saveCategory(id: nil, name: "早餐")
        let categoryID = try XCTUnwrap(data.categories.first?.id)
        try data.saveProduct(id: nil, categoryID: categoryID, name: "吐司", price: 40, isVisible: true)
        let productID = try XCTUnwrap(data.products.first?.id)
        try data.saveToppingGroup(id: nil, name: "溫度", maxSelect: 0)
        let groupID = try XCTUnwrap(data.toppingGroups.first?.id)
        try data.saveTopping(id: nil, groupID: groupID, name: "去冰", price: 0,
                             menuItemIDs: [productID], selectionType: "single", isRequired: false, isVisible: true)
        XCTAssertThrowsError(try data.saveTopping(id: nil, groupID: groupID, name: "加珍珠", price: 10,
                             menuItemIDs: [productID], selectionType: "multi", isRequired: false, isVisible: true))
    }

    func testReceiptUsesRequestedVisualSectionsAndActualOrderTotals() throws {
        let placedAt = Date(timeIntervalSince1970: 1_792_833_180)
        let order = POSOrder(
            id: UUID(), number: "2610249977", createdAt: placedAt, table: "內用",
            lines: [
                OrderLine(id: UUID(), name: "原味蛋餅", quantity: 1, unitPrice: 35,
                          modifiers: [], note: nil),
                OrderLine(id: UUID(), name: "草莓吐司", quantity: 1, unitPrice: 45,
                          modifiers: ["加蛋 ×1 +15"], note: "不要切")
            ],
            note: "不要袋子", paymentMethod: "LinePay", status: .completed
        )
        let layout = ReceiptFormatter.content(order: order, businessName: " OUPOS早餐店 ")
        XCTAssertEqual(layout.businessName, "OUPOS早餐店")
        XCTAssertEqual(layout.orderType, "內用")
        XCTAssertEqual(layout.number, "#2610249977")
        XCTAssertEqual(layout.paymentMethod, "LinePay")
        XCTAssertEqual(layout.note, "不要袋子")
        XCTAssertEqual(layout.quantity, 2)
        XCTAssertEqual(layout.total, 80)
        XCTAssertEqual(layout.items[0].name, "原味蛋餅")
        XCTAssertEqual(layout.items[0].subtotal, 35)
        XCTAssertEqual(layout.items[1].subtotal, 45)
        XCTAssertEqual(layout.items[1].modifiers, ["加蛋 ×1 +15"])
        XCTAssertEqual(layout.items[1].note, "不要切")
        XCTAssertEqual(layout.placedAt.count, 16) // yyyy/MM/dd HH:mm

        // Both common ESC/POS dot widths must produce valid raster commands and a cut.
        for width in [384, 576] {
            let bytes = ReceiptFormatter.makeReceipt(order: order, width: width,
                                                     businessName: layout.businessName)
            XCTAssertTrue(bytes.starts(with: [0x1B, 0x40, 0x1D, 0x76, 0x30, 0x00]))
            XCTAssertTrue(bytes.suffix(3).elementsEqual([0x1D, 0x56, 0x00]))
            XCTAssertGreaterThan(bytes.count, 1000)
            let rowBytes = Int(bytes[6]) + Int(bytes[7]) * 256
            XCTAssertEqual(rowBytes * 8, width)
        }
    }

    func testReceiptFallsBackToOUPOSWhenStoreNameMissing() {
        let order = POSOrder(id: UUID(), number: "2610240001", createdAt: Date(),
                             table: "外帶", lines: [], note: "", paymentMethod: "現金",
                             status: .completed)
        XCTAssertEqual(ReceiptFormatter.content(order: order, businessName: nil).businessName, "OUPOS")
        XCTAssertEqual(ReceiptFormatter.content(order: order, businessName: "  ").businessName, "OUPOS")
        XCTAssertTrue(ReceiptFormatter.content(order: order, businessName: " ").note.isEmpty)
    }

    func testBackupRoundTrip() throws {
        let db = temporaryDatabase()
        let store = authorizedStore(database: db)
        store.saveCategory(id: nil, name: "午餐")
        let data = try XCTUnwrap(store.exportBackupData())
        let fresh = authorizedStore(database: temporaryDatabase())
        fresh.importBackupData(data)
        XCTAssertEqual(fresh.menuCategories.first?.name, "午餐")
    }
}
