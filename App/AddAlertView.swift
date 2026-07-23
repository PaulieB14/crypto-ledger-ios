import SwiftUI

/// Sheet for arming a price alert on one coin: a direction and a target price.
struct AddAlertView: View {
    @Environment(\.dismiss) private var dismiss
    let assetID: String
    let currentPrice: Decimal?
    let onSave: (PriceAlert) -> Void

    @State private var direction: PriceAlert.Direction = .above
    @State private var targetText = ""

    private var target: Decimal? {
        Decimal(string: targetText.trimmingCharacters(in: .whitespaces))
    }
    private var isValid: Bool { (target ?? 0) > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Direction", selection: $direction) {
                        ForEach(PriceAlert.Direction.allCases) { d in
                            Text(d.label).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    LabeledContent("Target price") {
                        HStack(spacing: 6) {
                            TextField(placeholder, text: $targetText)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                            Text("USD").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Notify me when \(assetID) \(direction.verb) my target")
                } footer: {
                    if let p = currentPrice {
                        Text("\(assetID) is \(p.formatted(.currency(code: "USD"))) right now.")
                    } else {
                        Text("You'll get a notification even when Argus is closed. It checks periodically in the background.")
                    }
                }

                if let p = currentPrice {
                    Section {
                        quickChips(around: p)
                    }
                }
            }
            .navigationTitle("Price alert")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let t = target else { return }
                        onSave(PriceAlert(assetID: assetID, targetUSD: t, direction: direction))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
        }
        .frame(minWidth: 340, minHeight: 380)
        .tint(Theme.amber)
    }

    private var placeholder: String {
        guard let p = currentPrice else { return "0" }
        // Suggest a sensible starting target a little past the current price.
        let factor: Decimal = direction == .above ? 1.1 : 0.9
        return "\(roundedNice(p * factor))"
    }

    /// One-tap common targets relative to the current price.
    private func quickChips(around price: Decimal) -> some View {
        let steps: [Decimal] = direction == .above ? [1.05, 1.10, 1.25, 2.0]
                                                    : [0.95, 0.90, 0.75, 0.50]
        return HStack {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, f in
                let value = roundedNice(price * f)
                Button {
                    targetText = "\(value)"
                } label: {
                    Text(pct(f)).font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.amber)
            }
        }
    }

    private func pct(_ f: Decimal) -> String {
        let change = (f - 1) * 100
        let n = (change as NSDecimalNumber).intValue
        return n >= 0 ? "+\(n)%" : "\(n)%"
    }

    /// Trim a scaled price to a readable number of places for the target field.
    private func roundedNice(_ v: Decimal) -> Decimal {
        var input = v
        var result = Decimal()
        let scale: Int16 = v >= 100 ? 0 : (v >= 1 ? 2 : 4)
        NSDecimalRound(&result, &input, Int(scale), .plain)
        return result
    }
}
