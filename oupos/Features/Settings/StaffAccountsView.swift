import SwiftUI

/// First launch: a centered OUPOS loading logo moves upward, then the
/// administrator setup or account/password sign-in form fades into view.
private enum LoginIntroPhase: Equatable {
    case loading
    case movingLogo
    case ready
}

struct AccountGateView: View {
    @EnvironmentObject private var store: POSStore
    @State private var username = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var introPhase: LoginIntroPhase = .loading
    @State private var showingAdministratorRecovery = false
    @FocusState private var focusedField: LoginField?

    private enum LoginField: Hashable { case username, password, confirmation }
    private var registering: Bool { store.accountGate.isSetup }
    private var splashColor: Color { Color(red: 137 / 255, green: 166 / 255, blue: 194 / 255) }

    var body: some View {
        GeometryReader { geometry in
            let headerY = max(104, min(132, geometry.size.height * 0.17))
            ZStack {
                splashColor.ignoresSafeArea()

                if introPhase == .loading {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2 + 72)
                        .transition(.opacity)
                        .accessibilityLabel("正在載入")
                }

                if introPhase == .ready {
                    ScrollView {
                        VStack(spacing: 0) {
                            // Keep the form below the brand, including on smaller iPads.
                            Color.clear.frame(height: headerY + 70)
                            loginCard
                                .frame(maxWidth: 480)
                                .padding(.horizontal, 24)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 36)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .transition(.opacity.combined(with: .offset(y: 18)))
                }

                Text("OUPOS")
                    .font(.system(size: 62, weight: .black, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .position(
                        x: geometry.size.width / 2,
                        y: introPhase == .loading ? geometry.size.height / 2 - 22 : headerY
                    )
                    .animation(.spring(response: 0.65, dampingFraction: 0.82), value: introPhase)
                    .accessibilityAddTraits(.isHeader)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showingAdministratorRecovery, onDismiss: {
            store.revokeAdministratorRecovery()
        }) {
            AdministratorRecoveryView()
                .environmentObject(store)
        }
        .task {
            // The logo must stay on screen while loading, not blink into a
            // separate sign-in page. Cancelling this task stops the animation
            // if login is dismissed before the transition completes.
            do {
                try await Task.sleep(for: .milliseconds(850))
                withAnimation(.easeOut(duration: 0.18)) { introPhase = .movingLogo }
                try await Task.sleep(for: .milliseconds(520))
                withAnimation(.easeOut(duration: 0.35)) { introPhase = .ready }
            } catch {
                // View was dismissed; avoid updating state after cancellation.
            }
        }
    }

    private var loginCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: registering ? "person.crop.circle.badge.plus" : "lock.shield")
                    .font(.system(size: 29))
                    .foregroundStyle(POSColor.primaryStrong)
                VStack(alignment: .leading, spacing: 4) {
                    Text(registering ? "建立管理員帳號" : "帳號登入")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(POSColor.textPrimary)
                    Text(registering ? "第一次使用，請先註冊管理員。" : "請輸入帳號與密碼以進入 POS。")
                        .font(.system(size: 14))
                        .foregroundStyle(POSColor.textSecondary)
                }
            }

            if store.accountGate.isUnavailable {
                Text("帳號儲存空間無法讀取，已停止登入以保護原有資料。請勿刪除 App。")
                    .foregroundStyle(POSColor.danger)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text("帳號").font(.subheadline.weight(.semibold))
                    TextField("請輸入帳號", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .ouposAuthInput()
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("密碼").font(.subheadline.weight(.semibold))
                    SecureField("請輸入密碼", text: $password)
                        .textContentType(registering ? .newPassword : .password)
                        .ouposAuthInput()
                        .focused($focusedField, equals: .password)
                        .submitLabel(registering ? .next : .go)
                        .onSubmit {
                            if registering { focusedField = .confirmation }
                            else { submitCredentials() }
                        }
                }
                if registering {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("確認密碼").font(.subheadline.weight(.semibold))
                        SecureField("再次輸入密碼", text: $confirmation)
                            .textContentType(.newPassword)
                            .ouposAuthInput()
                            .focused($focusedField, equals: .confirmation)
                            .submitLabel(.go)
                            .onSubmit { submitCredentials() }
                    }
                    Text("帳號需有 3～32 個英數字、_ 或 -；密碼至少 8 個字元。")
                        .font(.system(size: 12))
                        .foregroundStyle(POSColor.textSecondary)
                }

                Button(action: submitCredentials) {
                    Text(registering ? "建立管理員並進入 POS" : "登入 POS")
                }
                .buttonStyle(OUPOSAuthPrimaryButtonStyle())
                .disabled(username.isEmpty || password.isEmpty || (registering && confirmation.isEmpty))

                // Only available once an administrator has already been created.
                // The account name is deliberately NOT disclosed until Face ID
                // or Touch ID has succeeded in the recovery sheet.
                if store.accountGate.isLogin {
                    Button("忘記管理員密碼？") {
                        showingAdministratorRecovery = true
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(POSColor.primaryStrong)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 20, y: 10)
    }

    private func submitCredentials() {
        focusedField = nil
        if registering {
            store.registerAdministrator(username: username, password: password, confirmation: confirmation)
        } else {
            store.signIn(username: username, password: password)
        }
        password = ""
        confirmation = ""
    }
}

struct StaffAccountsView: View {
    @EnvironmentObject private var store: POSStore
    @State private var username = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var passwordTarget: StaffProfile?
    @State private var updatedPassword = ""
    @State private var updatedConfirmation = ""
    @State private var deletionTarget: StaffProfile?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("員工帳號管理").font(.system(size: 27, weight: .bold))
                Text("只有管理員可以新增、移除員工及重設員工密碼。員工只能建立訂單和變更商品售完狀態。")
                    .foregroundStyle(POSColor.textSecondary)
                VStack(alignment: .leading, spacing: 12) {
                    Text("新增員工").font(.headline)
                    TextField("員工帳號", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .ouposAuthInput()
                    SecureField("登入密碼（至少 8 個字元）", text: $password).ouposAuthInput()
                    SecureField("確認密碼", text: $confirmation).ouposAuthInput()
                    Button("新增員工帳號") {
                        store.createEmployee(username: username, password: password, confirmation: confirmation)
                        if store.errorMessage == nil { username = ""; password = ""; confirmation = "" }
                    }
                    .buttonStyle(OUPOSAuthPrimaryButtonStyle())
                    .disabled(username.isEmpty || password.isEmpty || confirmation.isEmpty)
                }.posCard()
                VStack(alignment: .leading, spacing: 12) {
                    Text("目前帳號").font(.headline)
                    ForEach(store.staffAccounts) { person in
                        HStack(spacing: 10) {
                            Image(systemName: person.role == .administrator ? "person.crop.circle.fill.badge.checkmark" : "person.fill")
                            Text(person.username).fontWeight(.semibold)
                            Text(person.role.title).foregroundStyle(POSColor.textSecondary)
                            Spacer()
                            if person.role == .employee {
                                Button("重設密碼") { passwordTarget = person; updatedPassword = ""; updatedConfirmation = "" }
                                    .buttonStyle(OUPOSAuthOutlineButtonStyle(compact: true))
                                Button("刪除", role: .destructive) { deletionTarget = person }
                                    .buttonStyle(OUPOSAuthDestructiveButtonStyle())
                            }
                        }
                        Divider()
                    }
                }.posCard()
                if let person = passwordTarget {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("重設 \(person.username) 的密碼").font(.headline)
                        SecureField("新密碼", text: $updatedPassword).ouposAuthInput()
                        SecureField("確認新密碼", text: $updatedConfirmation).ouposAuthInput()
                        HStack {
                            Button("儲存新密碼") {
                                store.changeEmployeePassword(id: person.id, password: updatedPassword, confirmation: updatedConfirmation)
                                if store.errorMessage == nil { passwordTarget = nil; updatedPassword = ""; updatedConfirmation = "" }
                            }
                            .buttonStyle(OUPOSAuthPrimaryButtonStyle())
                            .disabled(updatedPassword.isEmpty || updatedConfirmation.isEmpty)
                            Button("取消") { passwordTarget = nil }.buttonStyle(OUPOSAuthOutlineButtonStyle(compact: true))
                        }
                    }.posCard()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("確認刪除員工帳號？", isPresented: Binding(get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } })) {
            Button("刪除", role: .destructive) {
                if let id = deletionTarget?.id { store.deleteEmployee(id: id) }
                deletionTarget = nil
            }
            Button("取消", role: .cancel) { deletionTarget = nil }
        } message: {
            Text("刪除後此帳號將無法再登入。")
        }
    }
}
