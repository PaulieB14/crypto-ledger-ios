import SwiftUI
import LedgerCore

/// A focused sheet for entering one transaction. Collects intent into a
/// `TransactionDraft`; the store turns it into immutable ledger entries.
struct AddTransactionView: View {
    @Environment(\.dismiss) private var dismiss
    var catalog: CoinCatalog
    let onSave: (TransactionDraft) -> Void

    @State private var draft = TransactionDraft()

    var body: some View {
        NavigationStack {
            Form {
                typeSection
                if draft.kind.isCrypto { assetSection }
                amountSection
                detailSection
                if let est = draft.estimatedUSD { estimateSection(est) }
            }
            .navigationTitle("New Transaction")
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

    // MARK: Sections

    private var typeSection: some View {
        Section {
            Picker("Type", selection: $draft.kind) {
                ForEach(TransactionDraft.Kind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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
                    if draft.kind.requiresPrice || draft.kind == .receive {
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

    private var amountSection: some View {
        Section(draft.kind.isCash ? "Amount" : "Details") {
            decimalField(
                label: "Quantity",
                text: $draft.quantityText,
                placeholder: draft.kind.isCash ? "1000" : "0.5",
                suffix: draft.kind.isCash ? "USD" : draft.asset.uppercased())

            if draft.kind.requiresPrice {
                decimalField(label: "Price / unit", text: $draft.priceText,
                             placeholder: "60000", suffix: "USD")
            } else if draft.kind == .receive {
                decimalField(label: "Cost / unit (optional)", text: $draft.priceText,
                             placeholder: "0", suffix: "USD")
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
            LabeledContent("Estimated value") {
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
