import SwiftUI
import UniformTypeIdentifiers

/// Files-compatible snapshot for transferring data between installations without any server.
struct LocalBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct LocalBackupView: View {
    @EnvironmentObject private var store: POSStore
    @State private var document: LocalBackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var confirmingRestore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本機資料備份與還原").font(.system(size: 21, weight: .bold))
            Text("備份包含菜單、商品、配料、桌號、支付方式、歷史訂單及印表機設定。可將備份檔保存或移轉裝置，刪除 App 前請先備份。")
                .font(.callout).foregroundStyle(POSColor.textSecondary)
            HStack(spacing: 15) {
                Button {
                    if let data = store.exportBackupData() {
                        document = LocalBackupDocument(data: data)
                        exporting = true
                    }
                } label: { Label("匯出 JSON 備份", systemImage: "square.and.arrow.up") }
                    .buttonStyle(OUPOSAuthPrimaryButtonStyle(compact: true))
                Button(role: .destructive) { confirmingRestore = true } label: {
                    Label("從 JSON 還原（覆蓋本機資料）", systemImage: "square.and.arrow.down")
                }.buttonStyle(OUPOSAuthOutlineButtonStyle(compact: true))
            }
        }
        .posCard()
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "oupos-backup") { result in
            if case .failure(let error) = result { store.errorMessage = "匯出失敗：\(error.localizedDescription)" }
        }
        .confirmationDialog("還原將覆蓋所有現有本機資料，確定已另行備份？", isPresented: $confirmingRestore) {
            Button("選擇備份檔並覆蓋", role: .destructive) { importing = true }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                store.importBackupData(try Data(contentsOf: url))
            } catch { store.errorMessage = "還原失敗：\(error.localizedDescription)" }
        }
    }
}
