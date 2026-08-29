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

    init(position: Position,
         onSave: @escaping (Decimal, Decimal) -> Void,
         onDelete: @escaping () -> Void) {
        self.position = position
        self.onSave = onSave
        self.onDelete = onDelete
        _qtyText = State(initialValue: UserNumber.text(position.qty))
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
    private var isValid: Bool { (qty ?? 0) > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Holding") {
                    field("Amount", $qtyText, suffix: position.assetID)
                    field("Cost per coin", $costText, suffix: "USD")
                }

                if let q = qty, let c = cost {
                    Section {
                        LabeledContent("Total cost basis") {
                            Text(q * c, format: .currency(code: "USD"))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onDelete(); dismiss()
                    } label: {
                        Label("Remove this holding", systemImage: "trash")
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
