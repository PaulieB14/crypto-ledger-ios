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
        UserNumber.decimal(targetText)
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
                    Text("Notify me when \(assetID) \(direction.conditionVerb) my target")
                } footer: {
                    // The background-timing disclosure must show on EVERY path.
                    // It used to live in the `else` branch, so any coin with a
                    // live price — i.e. every coin a user actually sets an alert
                    // on — never saw it, and the honest "not instant" caveat was
                    // effectively unreachable.
                    VStack(alignment: .leading, spacing: 4) {
                        if let p = currentPrice {
                            Text("\(assetID) is \(p.formatted(.currency(code: "USD"))) right now.")
                        }
                        Text("Argus checks this in the background — iOS schedules those checks, so a notification arrives shortly after the move rather than the instant it happens — and again whenever you open the app.")
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
                    targetText = UserNumber.text(value)
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
