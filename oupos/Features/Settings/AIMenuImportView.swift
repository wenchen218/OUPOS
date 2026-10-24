import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// External-AI-assisted import: the app never calls ChatGPT/Claude/Gemini directly.
/// Only a local JSON file or text deliberately provided by the administrator is parsed.
struct AIMenuImportView: View {
    @EnvironmentObject private var store: POSStore
    @Environment(\.dismiss) private var dismiss

    @State private var jsonText = ""
    @State private var importingFile = false
    @State private var preview: AIMenuImportPlan?
    @State private var pendingJSON: Data?
    @State private var confirmation = false
    @State private var localError: String?
    @State private var promptCopied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("AI 新增菜單", systemImage: "sparkles")
                            .font(.system(size: 28, weight: .bold))
                        Text("將菜單交給你慣用的 AI 整理成 JSON，接著匯入 OUPOS。無需額外註冊或串接 AI API。")
                            .font(.callout).foregroundStyle(POSColor.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Label("1. 複製提示詞", systemImage: "doc.on.doc").font(.headline)
                        Text("先複製以下指令，再到 ChatGPT、Claude 或 Gemini 上傳菜單照片、PDF 或文字。")
                            .font(.callout).foregroundStyle(POSColor.textSecondary)
                        Text(AIMenuImporter.prompt)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(POSColor.surfaceSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                        Button {
                            UIPasteboard.general.string = AIMenuImporter.prompt
                            promptCopied = true
                        } label: {
                            Label(promptCopied ? "已複製提示詞" : "複製 AI 提示詞", systemImage: "doc.on.doc")
                        }.buttonStyle(OUPOSAuthPrimaryButtonStyle(compact: true))
                        HStack(spacing: 15) {
                            Link("開啟 ChatGPT", destination: URL(string: "https://chatgpt.com/")!)
                            Link("開啟 Claude", destination: URL(string: "https://claude.ai/")!)
                            Link("開啟 Gemini", destination: URL(string: "https://gemini.google.com/")!)
                        }.font(.callout)
                        Text("提醒：菜單圖片會由你自行上傳至所選 AI 平台，請先移除不想分享的私人資料。")
                            .font(.caption).foregroundStyle(POSColor.textSecondary)
                    }.posCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Label("2. 匯入 AI 產生的 JSON", systemImage: "square.and.arrow.down").font(.headline)
                        Text("請讓 AI 只輸出 JSON。把內容存成 .json 檔案，或直接貼在下方；不支援把 OUPOS 完整備份當成 AI 菜單匯入。")
                            .font(.callout).foregroundStyle(POSColor.textSecondary)
                        Button {
                            KeyboardDismissal.dismiss()
                            clearPreview()
                            importingFile = true
                        } label: {
                            Label("選擇 JSON 檔案", systemImage: "folder")
                        }.buttonStyle(OUPOSAuthOutlineButtonStyle(compact: true))
                        Text("或貼上 JSON 文字").font(.subheadline).fontWeight(.semibold)
                        TextEditor(text: $jsonText)
                            // Focus follows a tap on this editor only; no
                            // FocusState is restored after sheet transitions.
                            .font(.system(size: 13, design: .monospaced))
                            .frame(height: 175)
                            .padding(8)
                            .background(POSColor.surfaceSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                            .onChange(of: jsonText) { _, _ in clearPreview() }
                        Button("檢查貼上的 JSON") {
                            KeyboardDismissal.dismiss()
                            inspect(Data(jsonText.utf8))
                        }.buttonStyle(OUPOSAuthPrimaryButtonStyle(compact: true))
                            .disabled(jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.posCard()

                    if let error = localError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(POSColor.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let preview {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("3. 確認匯入內容", systemImage: "checkmark.circle").font(.headline)
                            Text(preview.summary.description).font(.body)
                            Text("只會新增缺少的資料；同名資料不覆蓋。歷史訂單、出單機設定與員工帳號不受影響。")
                                .font(.callout).foregroundStyle(POSColor.textSecondary)
                            Button("確認新增到菜單") { confirmation = true }
                                .buttonStyle(OUPOSAuthPrimaryButtonStyle(compact: true))
                        }.posCard()
                    }
                }
                .padding(24)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.immediately)
            .onDisappear { KeyboardDismissal.dismiss() }
            .background(POSColor.background)
            .navigationTitle("AI 新增菜單")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { KeyboardDismissal.dismiss(); dismiss() }
                }
            }
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    inspect(data)
                } catch {
                    // A cancelled Files picker is not an import error.
                    let ns = error as NSError
                    if ns.domain != NSCocoaErrorDomain || ns.code != NSUserCancelledError {
                        localError = "讀取檔案失敗：\(error.localizedDescription)"
                    }
                }
            }
            .confirmationDialog("確認新增這些商品與配料？", isPresented: $confirmation) {
                Button("確認匯入") {
                    guard let pendingJSON else { return }
                    let imported = store.importAIMenuData(pendingJSON)
                    if imported {
                        clearPreview()
                        localError = nil
                        dismiss()
                    } else {
                        localError = store.errorMessage ?? "匯入失敗"
                    }
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("匯入不會刪除或覆蓋現有商品，但新增前仍建議先備份菜單。")
            }
        }
    }

    private func clearPreview() {
        preview = nil
        pendingJSON = nil
        confirmation = false
    }

    private func inspect(_ data: Data) {
        clearPreview()
        localError = nil
        if let planned = store.previewAIMenuData(data) {
            preview = planned
            pendingJSON = data
        } else {
            localError = store.errorMessage ?? "檢查 JSON 失敗"
        }
    }
}
