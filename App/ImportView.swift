import SwiftUI
import UniformTypeIdentifiers

/// Bulk-import transactions from CSV — paste rows or load a file. Shows a live
/// count of what will import and which lines were skipped, before committing.
struct ImportView: View {
    @Environment(\.dismiss) private var dismiss
    let onImport: ([TransactionDraft]) -> Void

    @State private var text = ""
    @State private var showingFile = false

    private var result: CSVImport.Result { CSVImport.parse(text) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Paste CSV rows or load a file.\nColumns: **date, type, asset, quantity, price, account** · types: buy · sell · receive · deposit")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                editor

                HStack(spacing: 10) {
                    Button { showingFile = true } label: { Label("Load file…", systemImage: "doc") }
                    Button { text = CSVImport.sample } label: { Label("Sample", systemImage: "doc.text") }
                    if !text.isEmpty {
                        Button(role: .destructive) { text = "" } label: { Label("Clear", systemImage: "xmark") }
                    }
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if !text.isEmpty { summary }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Import CSV")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(result.drafts.isEmpty ? "Import" : "Import \(result.drafts.count)") {
                        onImport(result.drafts)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(result.drafts.isEmpty)
                }
            }
            .fileImporter(isPresented: $showingFile,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { res in
                guard case .success(let url) = res else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let s = try? String(contentsOf: url, encoding: .utf8) { text = s }
            }
        }
        .frame(minWidth: 480, minHeight: 560)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 200)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
            if text.isEmpty {
                Text("date,type,asset,quantity,price,account\n2024-01-15,buy,BTC,0.25,42000,Coinbase")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Label("\(result.drafts.count) ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if !result.errors.isEmpty {
                    Label("\(result.errors.count) skipped", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.subheadline.weight(.medium))

            if !result.errors.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(result.errors, id: \.self) { e in
                            Text(e).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
        }
    }
}
