import SwiftUI

/// Tier-1 "add what you hold", the effortless way: paste an address and Argus
/// pulls your balances from public block explorers. Imported coins become
/// holdings valued at today's price — same clean model as manual entry.
struct WalletImportView: View {
    @Environment(\.dismiss) private var dismiss
    var catalog: CoinCatalog
    let onImport: ([TransactionDraft]) -> Void

    @State private var address = ""
    @State private var chains: Set<WalletChain> = Set(WalletChain.allCases)
    @State private var phase: Phase = .input
    @State private var priced: [WalletHolding] = []
    @State private var selected: Set<String> = []

    private enum Phase { case input, scanning, results, empty }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .input:    inputForm
                case .scanning: scanning
                case .results:  results
                case .empty:    emptyResults
                }
            }
            .navigationTitle("Import from wallet")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if phase == .results {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add \(selected.count)") { importSelected() }
                            .fontWeight(.semibold)
                            .disabled(selected.isEmpty)
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 480)
        .tint(.indigo)
    }

    // MARK: Input

    private var inputForm: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("0x… wallet address", text: $address)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    #if os(iOS)
                    Button {
                        if let s = UIPasteboard.general.string { address = s }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(.plain).foregroundStyle(.indigo)
                    #endif
                }
            } header: {
                Text("Public wallet address")
            } footer: {
                if !address.isEmpty && !isValidEVMAddress(address) {
                    Text("That doesn't look like a 0x… address.").foregroundStyle(.orange)
                } else {
                    Text("Read-only. Argus never asks for a seed phrase or private key — only your public address.")
                }
            }

            Section("Chains to scan") {
                ForEach(WalletChain.allCases) { chain in
                    Toggle(chain.label, isOn: Binding(
                        get: { chains.contains(chain) },
                        set: { on in if on { chains.insert(chain) } else { chains.remove(chain) } }
                    ))
                    .tint(.indigo)
                }
            }

            Section {
                Button {
                    scan()
                } label: {
                    Label("Scan wallet", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValidEVMAddress(address) || chains.isEmpty)
            }
        }
    }

    private var scanning: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Scanning \(chains.count) chain\(chains.count == 1 ? "" : "s")…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Results

    private var results: some View {
        List {
            Section {
                ForEach(priced) { h in
                    holdingRow(h)
                }
            } header: {
                Text("Found \(priced.count) coin\(priced.count == 1 ? "" : "s")")
            } footer: {
                Text("Only coins with a live price are shown. Each is added at today's value, so gains start from now. Uncheck anything you don't want.")
            }
        }
    }

    private func holdingRow(_ h: WalletHolding) -> some View {
        let isOn = selected.contains(h.symbol)
        let value = catalog.price(for: h.symbol).map { $0 * h.quantity }
        return Button {
            if isOn { selected.remove(h.symbol) } else { selected.insert(h.symbol) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.indigo : Color.secondary)
                AssetBadge(symbol: h.symbol, imageURL: catalog.imageURL(for: h.symbol))
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.symbol).fontWeight(.semibold)
                    Text(h.quantity.formatted(.number.precision(.significantDigits(1...6))))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                if let v = value {
                    Text(v, format: .currency(code: "USD"))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var emptyResults: some View {
        ContentUnavailableView {
            Label("No priced coins found", systemImage: "questionmark.folder")
        } description: {
            Text("We didn't find tokens with a live price at that address on the selected chains. Double-check the address, or add holdings manually.")
        } actions: {
            Button("Try another address") { phase = .input }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Actions

    private func scan() {
        phase = .scanning
        let addr = address
        let selectedChains = Array(chains)
        Task {
            await catalog.load()   // ensure prices are available for filtering
            let found = await WalletImporter.fetch(address: addr, chains: selectedChains)
            let withPrice = found.filter { catalog.price(for: $0.symbol) != nil }
            priced = withPrice
            selected = Set(withPrice.map(\.symbol))
            phase = withPrice.isEmpty ? .empty : .results
        }
    }

    private func importSelected() {
        let drafts: [TransactionDraft] = priced
            .filter { selected.contains($0.symbol) }
            .map { h in
                var d = TransactionDraft()
                d.kind = .balance
                d.asset = h.symbol
                d.quantityText = "\(h.quantity)"
                if let p = catalog.price(for: h.symbol) { d.priceText = "\(p)" }
                return d
            }
        onImport(drafts)
        dismiss()
    }
}
