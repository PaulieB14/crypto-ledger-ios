import SwiftUI
import LedgerCore

struct NetWorthView: View {
    @State private var store = PortfolioStore.fixtures()

    var body: some View {
        NavigationStack {
            Group {
                switch store.state {
                case .idle, .loading:
                    ProgressView()
                case .failed(let message):
                    ContentUnavailableView(
                        "Couldn't load your accounts",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message))
                case .loaded:
                    if let snapshot = store.snapshot {
                        content(snapshot)
                    } else {
                        ContentUnavailableView(
                            "No transactions yet",
                            systemImage: "tray",
                            description: Text("Add an account or enter a transaction to start tracking."))
                    }
                }
            }
            .navigationTitle("Portfolio")
            .task { await store.load() }
        }
    }

    private func content(_ snapshot: PortfolioSnapshot) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.netWorthUSD, format: .currency(code: "USD"))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    HStack(spacing: 4) {
                        Image(systemName: snapshot.unrealizedUSD >= 0
                              ? "arrow.up.right" : "arrow.down.right")
                        Text(snapshot.unrealizedUSD, format: .currency(code: "USD"))
                            .monospacedDigit()
                        Text("unrealized")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .foregroundStyle(snapshot.unrealizedUSD >= 0 ? .green : .red)
                }
                .padding(.vertical, 4)
            }

            if snapshot.hasOpenQuestions {
                Section {
                    NavigationLink {
                        ReviewQueueView(snapshot: snapshot)
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text("\(openItemCount(snapshot)) transfers need review")
                                Text("Totals are incomplete until you resolve them.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "questionmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            Section("Holdings") {
                ForEach(snapshot.positions) { position in
                    PositionRow(position: position)
                }
                if snapshot.cashUSD != 0 {
                    LabeledContent("Cash") {
                        Text(snapshot.cashUSD, format: .currency(code: "USD"))
                            .monospacedDigit()
                    }
                }
            }

            Section {
                LabeledContent("Short term") {
                    Text(snapshot.realizedShortTermUSD, format: .currency(code: "USD"))
                        .monospacedDigit()
                }
                LabeledContent("Long term") {
                    Text(snapshot.realizedLongTermUSD, format: .currency(code: "USD"))
                        .monospacedDigit()
                }
                Picker("Cost basis", selection: $store.method) {
                    ForEach(CostBasisMethod.allCases, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
            } header: {
                Text("Realized gains")
            } footer: {
                Text("Changing the method moves gains between realized and unrealized. It never changes what you own.")
            }
        }
    }

    private func openItemCount(_ snapshot: PortfolioSnapshot) -> Int {
        snapshot.transfersNeedingReview.count + snapshot.unpairedTransfers.count
    }
}

private struct PositionRow: View {
    let position: Position

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(position.assetID)
                    .font(.body.weight(.medium))
                Text(position.qty.formatted(.number.precision(.significantDigits(1...8))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing) {
                if let value = position.marketValueUSD {
                    Text(value, format: .currency(code: "USD"))
                        .monospacedDigit()
                } else {
                    Text("No price")
                        .foregroundStyle(.secondary)
                }
                if let unrealized = position.unrealizedUSD {
                    Text(unrealized, format: .currency(code: "USD"))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(unrealized >= 0 ? .green : .red)
                }
            }
        }
    }
}

private struct ReviewQueueView: View {
    let snapshot: PortfolioSnapshot

    var body: some View {
        List {
            if !snapshot.transfersNeedingReview.isEmpty {
                Section("Possible transfers") {
                    ForEach(snapshot.transfersNeedingReview, id: \.self) { candidate in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(candidate.outbound.accountID) → \(candidate.inbound.accountID)")
                                .font(.body.weight(.medium))
                            Text("\(candidate.outbound.assetID) · \(Int(candidate.confidence * 100))% confident")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !snapshot.unpairedTransfers.isEmpty {
                Section {
                    ForEach(snapshot.unpairedTransfers) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.assetID) · \(entry.accountID)")
                                .font(.body.weight(.medium))
                            Text(entry.timestamp, format: .dateTime.year().month().day())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("No matching account")
                } footer: {
                    Text("These moved in or out without a counterpart. Connect the other account, or mark them as a purchase or sale.")
                }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NetWorthView()
}
