import Foundation
import Security
import CommonCrypto
import CryptoKit

/// Only local staff accounts. Never included in the POS JSON backup or sent to a server.
enum StaffRole: String, Codable {
    case administrator
    case employee
    var title: String { self == .administrator ? "管理員" : "員工" }
}

struct StaffProfile: Identifiable, Equatable {
    let id: UUID
    let username: String
    let role: StaffRole
}

fileprivate struct StoredAccount: Codable {
    let id: UUID
    let username: String
    let role: StaffRole
    let salt: Data
    let derivedKey: Data
    var profile: StaffProfile { StaffProfile(id: id, username: username, role: role) }
}

/// Stored inside the account Keychain vault (never in the JSON backup).
/// An existing vault without this optional property decodes normally.
fileprivate struct StoredLoginSession: Codable {
    let accountID: UUID
    let createdAt: Date
    let expiresAt: Date
    let credentialFingerprint: Data
}

struct StaffAccountVault: Codable {
    fileprivate var accounts: [StoredAccount] = []
    fileprivate var loginSession: StoredLoginSession? = nil
    fileprivate var failedAttempts: Int = 0
    fileprivate var blockedUntil: Date? = nil
}

enum AccountError: LocalizedError {
    case invalidUsername, invalidPassword, confirmationMismatch, duplicateUsername
    case setupComplete, setupRequired, invalidCredentials, blocked, notFound
    case lastAdministrator, persistence(OSStatus), corrupted, notAuthorized

    var errorDescription: String? {
        switch self {
        case .invalidUsername: "帳號須為 3～32 個英文字母、數字、底線或連字號"
        case .invalidPassword: "密碼至少 8 個字元，最多 128 個字元"
        case .confirmationMismatch: "兩次輸入的密碼不相同"
        case .duplicateUsername: "這個帳號已經存在"
        case .setupComplete: "管理員已建立，請直接登入"
        case .setupRequired: "請先建立第一位管理員"
        case .invalidCredentials: "帳號或密碼錯誤"
        case .blocked: "登入失敗次數過多，請在 30 秒後再試"
        case .notFound: "找不到員工帳號"
        case .lastAdministrator: "無法刪除最後一位管理員"
        case .persistence(let status): "iPad Keychain 存取失敗（代碼 \(status)），已禁止建立或登入帳號"
        case .corrupted: "本機帳號資料損壞，為保護資料已鎖定登入"
        case .notAuthorized: "需要管理員權限"
        }
    }
}

@MainActor
protocol StaffAccountStorage {
    func load() throws -> StaffAccountVault
    func save(_ vault: StaffAccountVault) throws
}

struct KeychainStaffAccountStorage: StaffAccountStorage {
    nonisolated init() {}
    private let service = "org.oupos.local.staff-credentials.v1"
    private let account = "oupos-staff-v1"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> StaffAccountVault {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return StaffAccountVault() }
        guard status == errSecSuccess else { throw AccountError.persistence(status) }
        guard let data = result as? Data,
              let vault = try? JSONDecoder().decode(StaffAccountVault.self, from: data),
              !vault.accounts.isEmpty,
              vault.accounts.contains(where: { $0.role == .administrator }) else { throw AccountError.corrupted }
        return vault
    }

    func save(_ vault: StaffAccountVault) throws {
        let data = try JSONEncoder().encode(vault)
        var newItem = query
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(newItem as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else { throw AccountError.persistence(updateStatus) }
        } else if status != errSecSuccess { throw AccountError.persistence(status) }
    }
}

/// Synchronous operations are deliberately serialized on the main actor through POSStore.
/// Password hashes: random 16-byte salt + PBKDF2-HMAC-SHA256 (210,000 rounds).
@MainActor
struct LocalAccountService {
    let storage: any StaffAccountStorage
    /// Fixed 24-hour session from the last successful password login.
    static let sessionDuration: TimeInterval = 24 * 60 * 60
    private let clock: () -> Date

    init(storage: any StaffAccountStorage = KeychainStaffAccountStorage(),
         now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.clock = now
    }

    private func fingerprint(for account: StoredAccount) -> Data {
        Data(SHA256.hash(data: account.salt + account.derivedKey))
    }

    private func makeSession(for account: StoredAccount) -> StoredLoginSession {
        let start = clock()
        return StoredLoginSession(accountID: account.id, createdAt: start,
                                  expiresAt: start.addingTimeInterval(Self.sessionDuration),
                                  credentialFingerprint: fingerprint(for: account))
    }

    /// Restores only existing, unchanged credentials; never extends expiration.
    /// A deleted account, password update, elapsed 24 hours or clock rollback
    /// makes the saved login invalid. Keychain read errors fail closed.
    func restoreSession() throws -> StaffProfile? {
        var vault = try storage.load()
        guard let session = vault.loginSession else { return nil }
        let current = clock()
        guard current >= session.createdAt, current < session.expiresAt,
              let account = vault.accounts.first(where: { $0.id == session.accountID }),
              constantTimeEquals(fingerprint(for: account), session.credentialFingerprint) else {
            vault.loginSession = nil
            try storage.save(vault)
            return nil
        }
        return account.profile
    }

    func endSession() throws {
        var vault = try storage.load()
        guard vault.loginSession != nil else { return }
        vault.loginSession = nil
        try storage.save(vault)
    }

    func needsSetup() throws -> Bool { try storage.load().accounts.isEmpty }
    func profiles() throws -> [StaffProfile] { try storage.load().accounts.map(\.profile) }

    func registerFirstAdmin(username: String, password: String) throws -> StaffProfile {
        var vault = try storage.load()
        guard vault.accounts.isEmpty else { throw AccountError.setupComplete }
        let record = try createRecord(username: username, password: password, role: .administrator, existing: vault.accounts)
        vault.accounts.append(record)
        vault.loginSession = makeSession(for: record)
        try storage.save(vault)
        return record.profile
    }

    func signIn(username: String, password: String) throws -> StaffProfile {
        var vault = try storage.load()
        guard !vault.accounts.isEmpty else { throw AccountError.setupRequired }
        if let until = vault.blockedUntil, until > Date() { throw AccountError.blocked }
        let key = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let record = vault.accounts.first { $0.username.lowercased() == key }
        // Compute a hash even when user does not exist to reduce username probing.
        let salt = record?.salt ?? Data(repeating: 0, count: 16)
        let attempted = try derive(password: password, salt: salt)
        if let record, constantTimeEquals(attempted, record.derivedKey) {
            vault.failedAttempts = 0
            vault.blockedUntil = nil
            vault.loginSession = makeSession(for: record)
            try storage.save(vault)
            return record.profile
        }
        vault.failedAttempts += 1
        if vault.failedAttempts >= 5 {
            vault.blockedUntil = Date().addingTimeInterval(30)
            vault.failedAttempts = 0
        }
        try storage.save(vault)
        throw AccountError.invalidCredentials
    }

    /// Only call after the POSStore has obtained a fresh biometric-only grant.
    /// Never exposes (or attempts to recover) the original password.
    func administratorProfile() throws -> StaffProfile {
        let vault = try storage.load()
        guard let admin = vault.accounts.first(where: { $0.role == .administrator }) else {
            throw AdministratorRecoveryError.administratorMissing
        }
        return admin.profile
    }

    func replaceAdministratorPassword(id: UUID, newPassword: String) throws {
        var vault = try storage.load()
        guard let index = vault.accounts.firstIndex(where: { $0.id == id && $0.role == .administrator }) else {
            throw AdministratorRecoveryError.administratorMissing
        }
        let account = vault.accounts[index]
        // Regenerate both salt and derived key; preserve admin ID and username.
        vault.accounts[index] = try createRecord(username: account.username, password: newPassword,
                                                 role: .administrator, existing: [], id: account.id)
        vault.failedAttempts = 0
        vault.blockedUntil = nil
        if vault.loginSession?.accountID == id { vault.loginSession = nil }
        try storage.save(vault)
    }

    func addEmployee(username: String, password: String) throws -> StaffProfile {
        var vault = try storage.load()
        guard vault.accounts.contains(where: { $0.role == .administrator }) else { throw AccountError.setupRequired }
        let record = try createRecord(username: username, password: password, role: .employee, existing: vault.accounts)
        vault.accounts.append(record)
        try storage.save(vault)
        return record.profile
    }

    func resetEmployeePassword(id: UUID, newPassword: String) throws {
        var vault = try storage.load()
        guard let index = vault.accounts.firstIndex(where: { $0.id == id && $0.role == .employee }) else { throw AccountError.notFound }
        let employee = vault.accounts[index]
        vault.accounts[index] = try createRecord(username: employee.username, password: newPassword, role: .employee, existing: [], id: id)
        if vault.loginSession?.accountID == id { vault.loginSession = nil }
        try storage.save(vault)
    }

    func removeEmployee(id: UUID) throws {
        var vault = try storage.load()
        guard vault.accounts.contains(where: { $0.id == id && $0.role == .employee }) else { throw AccountError.notFound }
        vault.accounts.removeAll { $0.id == id }
        if vault.loginSession?.accountID == id { vault.loginSession = nil }
        try storage.save(vault)
    }

    private func createRecord(username: String, password: String, role: StaffRole, existing: [StoredAccount], id: UUID = UUID()) throws -> StoredAccount {
        let cleaned = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard (3...32).contains(cleaned.utf8.count), cleaned.unicodeScalars.allSatisfy({ permitted.contains($0) }) else { throw AccountError.invalidUsername }
        guard (8...128).contains(password.utf8.count) else { throw AccountError.invalidPassword }
        guard !existing.contains(where: { $0.username.caseInsensitiveCompare(cleaned) == .orderedSame }) else { throw AccountError.duplicateUsername }
        var bytes = [UInt8](repeating: 0, count: 16)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw AccountError.corrupted }
        let salt = Data(bytes)
        return StoredAccount(id: id, username: cleaned, role: role, salt: salt, derivedKey: try derive(password: password, salt: salt))
    }

    private func derive(password: String, salt: Data) throws -> Data {
        var result = [UInt8](repeating: 0, count: 32)
        let code = password.withCString { pointer in
            salt.withUnsafeBytes { saltBuffer in
                result.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pointer, password.utf8.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 210_000,
                        output.bindMemory(to: UInt8.self).baseAddress!, output.count)
                }
            }
        }
        guard code == kCCSuccess else { throw AccountError.corrupted }
        return Data(result)
    }

    private func constantTimeEquals(_ first: Data, _ second: Data) -> Bool {
        guard first.count == second.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(first, second) { diff |= a ^ b }
        return diff == 0
    }
}
