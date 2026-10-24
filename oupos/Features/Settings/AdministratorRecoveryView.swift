import SwiftUI

/// Administrator-only *password reset*. We never display or decrypt old hashes.
/// The administrator username stays hidden until Face ID / Touch ID succeeds.
struct AdministratorRecoveryView: View {
    @EnvironmentObject private var store: POSStore
    @Environment(\.dismiss) private var dismiss
    @State private var newPassword = ""
    @State private var confirmation = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "faceid")
                        .font(.system(size: 44))
                        .foregroundStyle(POSColor.primaryStrong)
                        .frame(maxWidth: .infinity)

                    Text("重設管理員密碼")
                        .font(.system(size: 25, weight: .bold))
                        .frame(maxWidth: .infinity)

                    Text("必須先通過 iPad 的 Face ID 或 Touch ID，才可以查看管理員帳號並設定新密碼。此流程不接受裝置解鎖密碼作為替代。")
                        .foregroundStyle(POSColor.textSecondary)
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)

                    if let username = store.administratorRecoveryPhase.completedUsername {
                        successContent(username: username)
                    } else if let username = store.administratorRecoveryPhase.verifiedUsername {
                        verifiedContent(username: username)
                    } else {
                        verificationContent
                    }

                    if let error = store.administratorRecoveryError {
                        Text(error)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(POSColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(28)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(POSColor.background)
            .navigationTitle("管理員密碼救援")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("關閉") {
                        store.revokeAdministratorRecovery()
                        newPassword = ""
                        confirmation = ""
                        dismiss()
                    }
                }
            }
        }
    }

    private var verificationContent: some View {
        VStack(spacing: 14) {
            if store.administratorRecoveryPhase.isAuthenticating {
                ProgressView("等待生物辨識…")
                    .frame(maxWidth: .infinity)
            }
            Button {
                Task { await store.authenticateForAdministratorRecovery() }
            } label: {
                Label("使用 Face ID／Touch ID 驗證", systemImage: "lock.shield")
            }
            .buttonStyle(OUPOSAuthPrimaryButtonStyle())
            .disabled(store.administratorRecoveryPhase.isAuthenticating)

            Text("未設定生物辨識、驗證失敗或系統鎖定時，將無法進行密碼重設。")
                .font(.footnote)
                .foregroundStyle(POSColor.textSecondary)
        }
    }

    private func verifiedContent(username: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("生物辨識已通過", systemImage: "checkmark.shield.fill")
                .foregroundStyle(POSColor.primaryStrong)
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("管理員帳號")
                    .font(.subheadline)
                    .foregroundStyle(POSColor.textSecondary)
                Text(username)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .textSelection(.enabled)
            }

            Text("請輸入新密碼（至少 8 個字元）。原本的密碼不會顯示。驗證有效期限為 2 分鐘，只能重設一次。")
                .font(.footnote)
                .foregroundStyle(POSColor.textSecondary)

            SecureField("新管理員密碼", text: $newPassword)
                .textContentType(.newPassword)
                .ouposAuthInput()
            SecureField("再次輸入新密碼", text: $confirmation)
                .textContentType(.newPassword)
                .ouposAuthInput()

            Button("確認重設管理員密碼") {
                if store.resetAdministratorPassword(newPassword: newPassword,
                                                    confirmation: confirmation) {
                    newPassword = ""
                    confirmation = ""
                }
            }
            .buttonStyle(OUPOSAuthPrimaryButtonStyle())
            .frame(maxWidth: .infinity)
            .disabled(newPassword.isEmpty || confirmation.isEmpty)
        }
    }

    private func successContent(username: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("密碼已重設完成", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(POSColor.primaryStrong)
            Text("管理員帳號：\(username)")
                .font(.system(size: 18, weight: .semibold))
            Text("請使用新密碼回到登入畫面登入。員工帳號與營業資料不受影響。")
                .foregroundStyle(POSColor.textSecondary)
            Button("返回登入") {
                store.revokeAdministratorRecovery()
                dismiss()
            }
            .buttonStyle(OUPOSAuthPrimaryButtonStyle())
        }
    }
}
