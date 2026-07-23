import SwiftUI
import LedgerCore

/// A focused sheet for entering one transaction. Collects intent into a
/// `TransactionDraft`; the store turns it into immutable ledger entries.
struct AddTransactionView: View {
    @Environment(\.dismiss) private var dismiss
    var catalog: CoinCatalog
    /// When set, the sheet is fixed to one kind and hides the type picker — used
    /// for the simplest "Add holding" on-ramp (`.balance`).
    var lockedKind: TransactionDraft.Kind?
    let onSave: (TransactionDraft) -> Void

    @State private var draft: TransactionDraft

    init(catalog: CoinCatalog,
         lockedKind: TransactionDraft.Kind? = nil,
         onSave: @escaping (TransactionDraft) -> Void) {
        self.catalog = catalog
        self.lockedKind = lockedKind
        self.onSave = onSave
        var initial = TransactionDraft()
        if let lockedKind { initial.kind = lockedKind }
        // Seed the live price for the default coin so a balance holding is priced
        // from the moment the sheet opens (the catalog is usually already loaded).
        if lockedKind == .balance, let p = catalog.price(for: initial.asset), p > 0 {
            initial.priceText = "\(p)"
        }
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                typeSection
                if draft.kind.isCrypto { assetSection }
                amountSection
                detailSection
                if let est = draft.estimatedUSD { estimateSection(est) }
            }
            .task(id: draft.asset) {
                // A balance holding is valued at today's price. Capture a live
                // price for the current asset — on appear (covers the pre-filled
                // default, which an onChange would miss) and on every change,
                // loading the catalog first if it isn't ready yet.
                guard draft.kind == .balance else { return }
                if catalog.coins.isEmpty { await catalog.load() }
                if let p = catalog.price(for: draft.asset), p > 0 {
                    draft.priceText = "\(p)"
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onSave(draft); dismiss() }
                        .fontWeight(.semibold)
                        .disabled(!draft.isValid)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 480)
    }

    private var navigationTitle: String {
        lockedKind == .balance ? "Add Holding" : "New Transaction"
    }

    // MARK: Sections

    private var typeSection: some View {
        Section {
            if lockedKind == nil {
                Picker("Type", selection: $draft.kind) {
                    ForEach(TransactionDraft.Kind.transactionKinds) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(spacing: 10) {
                Image(systemName: draft.kind.icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text(draft.kind.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var assetSection: some View {
        Section("Asset") {
            NavigationLink {
                CoinPickerView(catalog: catalog) { coin in
                    draft.asset = coin.symbol
                    if draft.kind.requiresPrice || draft.kind == .receive || draft.kind == .balance {
                        draft.priceText = "\(coin.priceUSD)"
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    AssetBadge(symbol: draft.asset.isEmpty ? "?" : draft.asset,
                               imageURL: catalog.imageURL(for: draft.asset))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.asset.isEmpty ? "Choose a coin" : draft.asset)
                            .fontWeight(.medium)
                        if let p = catalog.price(for: draft.asset) {
                            Text("Live · \(p.formatted(.currency(code: "USD")))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Search all coins").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            TextField("Or type any symbol", text: $draft.asset)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
        }
    }

    private var amountHeader: String {
        switch draft.kind {
        case .deposit: "Amount"
        case .balance: "How much you hold"
        default: "Details"
        }
    }

    private var amountSection: some View {
        Section(amountHeader) {
            decimalField(
                label: draft.kind == .balance ? "Amount you own" : "Quantity",
                text: $draft.quantityText,
                placeholder: draft.kind.isCash ? "1000" : "0.5",
                suffix: draft.kind.isCash ? "USD" : draft.asset.uppercased())

            if draft.kind.requiresPrice {
                decimalField(label: "Price / unit", text: $draft.priceText,
                             placeholder: "60000", suffix: "USD")
                decimalField(label: "Fee (optional)",
                             text: $draft.feeText, placeholder: "0", suffix: "USD")
            } else if draft.kind == .receive {
                decimalField(label: "Cost / unit (optional)", text: $draft.priceText,
                             placeholder: "0", suffix: "USD")
            } else if draft.kind == .balance {
                Text("Valued at today's live price. No purchase price needed — your gain starts from here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detailSection: some View {
        Section {
            LabeledContent("Account") {
                TextField("Manual", text: $draft.account)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
            }
            DatePicker("Date", selection: $draft.date,
                       displayedComponents: [.date, .hourAndMinute])
        }
    }

    private func estimateSection(_ est: Decimal) -> some View {
        Section {
            LabeledContent(draft.estimateLabel) {
                Text(est, format: .currency(code: "USD"))
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
            }
        }
    }

    // MARK: Helpers

    private func decimalField(label: String, text: Binding<String>,
                              placeholder: String, suffix: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(placeholder, text: text)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Text(suffix)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .leading)
            }
        }
    }
}

/// A small colored badge showing an asset's initials — the professional touch
/// that makes a list of holdings scannable.
struct AssetBadge: View {
    let symbol: String
    var size: CGFloat = 34
    var imageURL: URL? = nil

    var body: some View {
        let hue = AssetCatalog.hue(for: symbol)
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        initials(hue)          // loading or failed → initials
                    }
                }
            } else {
                initials(hue)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .shadow(color: Color(hue: hue, saturation: 0.5, brightness: 0.7).opacity(0.3),
                radius: 3, y: 1)
    }

    private func initials(_ hue: Double) -> some View {
        Circle()
            .fill(Color(hue: hue, saturation: 0.55, brightness: 0.85))
            .overlay(
                Text(symbol.prefix(2).uppercased())
                    .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white))
    }
}
