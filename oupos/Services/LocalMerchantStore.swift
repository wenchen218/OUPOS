import Foundation
import Combine

/// Business name is an optional, device-local display preference.
/// It is never transmitted and is not related to a cloud account.
enum LocalMerchantError: LocalizedError {
    case invalidName
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .invalidName: "請輸入 1～100 個字的商家名稱。"
        case .saveFailed: "商家名稱儲存失敗，請重試。"
        }
    }
}

@MainActor
final class LocalMerchantStore: ObservableObject {
    static let businessNameKey = "app.oupos.local.business-name.v1"

    @Published private(set) var businessName: String?
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let existing = defaults.string(forKey: Self.businessNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        businessName = existing?.isEmpty == false ? existing : nil
    }

    @discardableResult
    func saveBusinessName(_ input: String) -> Bool {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(cleaned.count) else {
            errorMessage = LocalMerchantError.invalidName.localizedDescription
            return false
        }
        defaults.set(cleaned, forKey: Self.businessNameKey)
        guard defaults.string(forKey: Self.businessNameKey) == cleaned else {
            errorMessage = LocalMerchantError.saveFailed.localizedDescription
            return false
        }
        errorMessage = nil
        businessName = cleaned
        return true
    }

    func clearError() { errorMessage = nil }
}
