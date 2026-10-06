import SwiftUI
import LedgerCore

/// Edit an existing holding — change how much you hold and what it cost, or
/// remove it. Pre-filled from the current position.
struct EditHoldingView: View {
    @Environment(\.dismiss) private var dismiss
    let position: Position
    let onSave: (_ quantity: Decimal, _ unitCostUSD: Decimal) -> Void
    let onDelete: () -> Void

    @State private var qtyText: String
    @State private var costText: String

    /// Debt read from a lending protocol. Shown, not edited: a refresh
    /// rewrites it from the chain on every launch.
    private var imported: [AccountQty] {
        guard position.isLiability else { return [] }
        return position.byAccount.filter { LendingAccountKey.isImported($0.accountID) }
    }
    private var importedQty: Decimal { imported.reduce(0) { $0 + $1.qty } }

    init(position: Position,
         onSave: @escaping (Decimal, Decimal) -> Void,
         onDelete: @escaping () -> Void) {
        self.position = position
        self.onSave = onSave
        self.onDelete = onDelete
        // For a debt, the field holds only what the user entered; imported
        // loan legs are listed separately.
        let importedQty = position.isLiability
            ? position.byAccount.filter { LendingAccountKey.isImported($0.accountID) }.reduce(Decimal(0)) { $0 + $1.qty }
            : 0
        let editable = position.qty - importedQty
        _qtyText = State(initialValue: editable > 0 ? UserNumber.text(editable) : "")
        // Cost per coin is a division, which can produce a long repeating
        // decimal — round it for display (cents for $1+ coins, more places for
        // sub-dollar coins).
        var unit = position.qty > 0 ? position.costBasisUSD / position.qty : 0
        var rounded = Decimal()
        NSDecimalRound(&rounded, &unit, unit >= 1 ? 2 : 8, .plain)
        _costText = State(initialValue: UserNumber.text(rounded))
    }

    private var qty: Decimal? { UserNumber.decimal(qtyText) }
    private var cost: Decimal? { UserNumber.decimal(costText) }
    private var isValid: Bool {
        // A debt that is all imported can still be saved, to change its price.
        if position.isLiability && importedQty > 0 { return qtyText.isEmpty || qty != nil }
        return (qty ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                if !imported.isEmpty {
                    Section {
                        ForEach(imported) { a in
                            LabeledContent(lenderLabel(a.accountID)) {
                                Text("\(UserNumber.text(a.qty)) \(position.assetID)")
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Read from your wallet")
                    } footer: {
                        Text("Updated from the lending app each time you open Argus. Borrow or repay there and it changes here.")
                    }
                }

                Section {
                    field(position.isLiability
                            ? (importedQty > 0 ? "Other debt you owe" : "Amount you owe")
                            : "Amount",
                          $qtyText, suffix: position.assetID)
                    field(position.isLiability ? "Price per coin" : "Cost per coin", $costText, suffix: "USD")
                } header: {
                    Text(position.isLiability ? "Debt" : "Holding")
                } footer: {
                    if position.isLiability && importedQty > 0 {
                        Text("For a loan Argus can't read, like one from an exchange. Leave blank if there isn't one.")
                    }
                }

                if let c = cost, let q = position.isLiability ? (qty ?? 0) + importedQty : qty {
                    Section {
                        LabeledContent(position.isLiability ? "Total owed" : "Total cost basis") {
                            Text(q * c, format: .currency(code: "USD"))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onDelete(); dismiss()
                    } label: {
                        Label(position.isLiability ? "Remove this debt" : "Remove this holding", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationTitle("Edit \(position.assetID)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(qty ?? 0, cost ?? 0); dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
        }
        .frame(minWidth: 340, minHeight: 360)
        .tint(Theme.amber)
    }

    /// `Aave Base · 0x1234…abcd` — the full address does not fit a row.
    private func lenderLabel(_ accountID: String) -> String {
        let parts = accountID.components(separatedBy: LendingAccountKey.separator)
        guard parts.count == 2, parts[1].count > 12 else { return accountID }
        return "\(parts[0]) · \(parts[1].prefix(6))…\(parts[1].suffix(4))"
    }

    private func field(_ label: String, _ text: Binding<String>, suffix: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("0", text: text)
                    .multilineTextAlignment(.trailing).monospacedDigit()
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Text(suffix).font(.caption).foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .leading)
            }
        }
    }
}
