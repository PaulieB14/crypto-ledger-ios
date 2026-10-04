import SwiftUI
import LedgerCore
#if os(iOS)
import UniformTypeIdentifiers
#endif

/// Settings.
///
/// Appearance first shipped as a Picker in the toolbar's secondaryAction,
/// which on iPhone collapses into the "•••" overflow beside "How it works" —
/// a submenu, two taps deep, next to a help entry. The person who asked for
/// dark mode could not find it, which is all the evidence that placement
/// needed.
///
/// Deliberately small. Cost basis stays in the Realized gains card, beside the
/// numbers it changes — a preference belongs next to its effect when it has an
/// obvious home, and only comes here when it has none. Appearance has none.
///
/// The links are duplicated from HelpView rather than moved: guideline
/// 5.1.1(i) wants the privacy policy reachable from inside the app, and
/// "inside a long explainer, below the fold" is a weak reading of reachable.
struct SettingsView: View {
    @AppStorage("appearance") private var appearance: Appearance = .system
    @Environment(\.dismiss) private var dismiss

    /// Wipes every holding and transaction. Lives here rather than in the "+"
    /// menu, where a destructive action sat under the heading "Add what you
    /// own".
    var onClearAll: (() -> Void)?
    var hasData: Bool = false
    /// The on-device entry file. Not the CSV trade importer.
    var ledgerEntries: () -> [LedgerEntry] = { [] }
    var onRestoreLedger: ([LedgerEntry]) -> Void = { _ in }

    @State private var confirmingClear = false
    #if os(iOS)
    @State private var showingExporter = false
    @State private var exportDocument: LedgerJSONDocument?
    @State private var showingImporter = false
    @State private var pendingRestore: [LedgerEntry]?
    @State private var transferError: String?
    #endif

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Theme", selection: $appearance) {
                        ForEach(Appearance.allCases) { a in
                            Label(a.label, systemImage: a.icon).tag(a)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("System follows your device setting.")
                }

                Section {
                    Link(destination: URL(string: "https://paulieb14.github.io/crypto-ledger-ios/privacy.html")!) {
                        Label("Privacy policy", systemImage: "hand.raised")
                    }
                    Link(destination: URL(string: "https://paulieb14.github.io/crypto-ledger-ios/")!) {
                        Label("Support", systemImage: "lifepreserver")
                    }
                    Link(destination: URL(string: "mailto:barba334@gmail.com")!) {
                        Label("Contact the developer", systemImage: "envelope")
                    }
                    LabeledContent("Version", value: version)
                } header: {
                    Text("About")
                } footer: {
                    Text("Your holdings stay on your device. No account, no sign-in.")
                }

                #if os(iOS)
                Section {
                    Button {
                        exportLedger()
                    } label: {
                        Label("Export ledger", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!hasData)
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import ledger", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("Your data")
                } footer: {
                    Text("A copy of every transaction stored on this device. Import replaces what is here. It is not a CSV of trades.")
                }
                #endif

                if hasData, onClearAll != nil {
                    Section {
                        Button(role: .destructive) { confirmingClear = true } label: {
                            Label("Clear all data", systemImage: "trash")
                        }
                    } footer: {
                        Text("Removes every holding and transaction from this device. Export a copy first if you might want it back.")
                    }
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // A confirmation step the "+" menu never had: Clear all was one tap
            // from a menu people open to add things.
            .confirmationDialog("Clear all data?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear everything", role: .destructive) {
                    onClearAll?()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every holding and transaction on this device will be removed. This cannot be undone.")
            }
            #if os(iOS)
            .fileExporter(isPresented: $showingExporter,
                          document: exportDocument,
                          contentType: .json,
                          defaultFilename: "argus-ledger") { result in
                if case .failure = result {
                    transferError = "Couldn't export the ledger."
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        pendingRestore = try LedgerArchive.decode(Data(contentsOf: url))
                    } catch {
                        transferError = "That file isn't an Argus ledger."
                    }
                case .failure:
                    transferError = "Couldn't read that file."
                }
            }
            .confirmationDialog("Replace the ledger on this device?",
                                isPresented: Binding(
                                    get: { pendingRestore != nil },
                                    set: { if !$0 { pendingRestore = nil } }),
                                titleVisibility: .visible) {
                Button("Replace", role: .destructive) {
                    if let entries = pendingRestore {
                        onRestoreLedger(entries)
                        pendingRestore = nil
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) { pendingRestore = nil }
            } message: {
                Text("Import replaces every holding and transaction on this device with the \(pendingRestore?.count ?? 0) entries in the file.")
            }
            .alert("Couldn't transfer the ledger",
                   isPresented: Binding(
                    get: { transferError != nil },
                    set: { if !$0 { transferError = nil } })) {
                Button("OK", role: .cancel) { transferError = nil }
            } message: {
                Text(transferError ?? "")
            }
            #endif
        }
    }

    #if os(iOS)
    private func exportLedger() {
        do {
            exportDocument = LedgerJSONDocument(data: try LedgerArchive.encode(ledgerEntries()))
            showingExporter = true
        } catch {
            transferError = "Couldn't export the ledger."
        }
    }
    #endif
}

#if os(iOS)
/// The entries file, shared through the system sheet. Decoding lives in
/// `LedgerArchive`, which is what the tests round-trip.
private struct LedgerJSONDocument: FileDocument {
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
#endif
