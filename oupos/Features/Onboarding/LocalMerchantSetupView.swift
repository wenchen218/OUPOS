import SwiftUI

/// First launch asks only for a store name, then opens the existing on-device
/// administrator creation screen. No provider login or business type collection.
struct LocalMerchantSetupView: View {
    @EnvironmentObject private var merchant: LocalMerchantStore
    @State private var businessName = ""
    @State private var logoMoved = false
    @State private var formVisible = false

    var body: some View {
        ZStack {
            Color(red: 137 / 255, green: 166 / 255, blue: 194 / 255)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    Text("OUPOS")
                        .font(.system(size: 58, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.top, logoMoved ? 0 : 175)
                        .animation(.spring(response: 0.65, dampingFraction: 0.82), value: logoMoved)

                    if !formVisible {
                        ProgressView("正在載入")
                            .tint(.white)
                            .foregroundStyle(.white)
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            Label("商家基本資料", systemImage: "storefront.fill")
                                .font(.title2.bold())
                            Text("設定商家名稱後，即可建立 POS 管理員帳號。")
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("商家名稱")
                                    .font(.subheadline.weight(.semibold))
                                TextField("請輸入商家名稱", text: $businessName)
                                    .textContentType(.organizationName)
                                    .ouposAuthInput()
                                    .submitLabel(.go)
                                    .onSubmit { submit() }
                            }
                            Button("下一步：建立管理員") { submit() }
                                .buttonStyle(OUPOSAuthPrimaryButtonStyle())
                                .disabled(businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            if let message = merchant.errorMessage {
                                Text(message).foregroundStyle(.red).font(.subheadline)
                            }
                        }
                        .font(.system(size: 16))
                        .padding(28)
                        .frame(maxWidth: 520, alignment: .leading)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .transition(.opacity.combined(with: .offset(y: 14)))
                    }
                }
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            do {
                try await Task.sleep(for: .milliseconds(800))
                withAnimation { logoMoved = true }
                try await Task.sleep(for: .milliseconds(480))
                withAnimation(.easeOut(duration: 0.32)) { formVisible = true }
            } catch { /* View dismissed during transition. */ }
        }
    }

    private func submit() {
        _ = merchant.saveBusinessName(businessName)
    }
}
