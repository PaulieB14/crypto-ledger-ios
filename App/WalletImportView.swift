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
    /// Did any block explorer answer? Distinguishes an empty wallet from a
    /// network outage so the empty state stops blaming a valid address.
    @State private var reachedAnyChain = true
    /// holding.id -> USD price, resolved by contract address at scan time.
    @State private var resolvedPrices: [String: Decimal] = [:]
    /// False when the token-identity index could not be fetched (CoinGecko
    /// rate-limits its free tier hard). Without it only native coins can be
    /// identified, and a wallet full of ERC-20s would otherwise look empty.
    @State private var identityReady = true
    /// Real, identified holdings we could not price — surfaced as a count so
    /// nothing is dropped silently.
    @State private var skippedUnpriced = 0
    /// Staked positions, which a token-balance scan cannot see at all.
    @State private var staking: [StakingPosition] = []

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
        .tint(Theme.amber)
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
                    .buttonStyle(.plain).foregroundStyle(Theme.amber)
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
                    .tint(Theme.amber)
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
            if !staking.isEmpty {
                Section {
                    ForEach(staking) { p in stakingRow(p) }
                } header: {
                    Text("Staked")
                } footer: {
                    // The double-count trap: osETH minted against a vault deposit
                    // is a LIABILITY, and the user usually holds that osETH as a
                    // token too — so it already appears in the list below. Adding
                    // both the stake and the minted token overstates the
                    // portfolio, and unlike a spam token the user cannot see it.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Staked assets are held in the protocol, so they don't appear as wallet tokens.")
                        // Same caveat as a token holding, but easier to miss here:
                        // you did not buy this at today's price, you staked it
                        // earlier and it has been earning since. The import has no
                        // way to know your real basis, so it uses spot and starts
                        // your gains from zero. Editable afterwards.
                        Text("Added at today's price, so gains start from now — tap the holding afterwards to set what you actually paid.")
                        if staking.contains(where: { $0.mintedOsToken > 0 }) {
                            Text("You also have osETH minted against a position. That osETH is listed below as a token, so adding both would count the same value twice.")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            Section {
                ForEach(priced) { h in
                    holdingRow(h)
                }
            } header: {
                Text("Found \(priced.count) coin\(priced.count == 1 ? "" : "s")")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Each is added at today's value, so gains start from now. Uncheck anything you don't want.")
                    if skippedUnpriced > 0 {
                        Text("\(skippedUnpriced) other recognised token\(skippedUnpriced == 1 ? "" : "s") had no live price and were left out.")
                    }
                    if !identityReady {
                        Text("Token identification is unavailable right now (the price service is rate-limiting), so only native coins could be matched. Try again shortly.")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    /// Selection key for a staked position. Prefixed because a vault IS a
    /// contract, so its id could otherwise collide with a token holding's.
    private func stakeKey(_ p: StakingPosition) -> String { "stake:" + p.id }

    private func stakingRow(_ p: StakingPosition) -> some View {
        let isOn = selected.contains(stakeKey(p))
        return Button {
            if isOn { selected.remove(stakeKey(p)) } else { selected.insert(stakeKey(p)) }
        } label: {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Theme.amber : Color.secondary)
                Text("\(p.vaultName)").fontWeight(.semibold)
                Spacer()
                Text(p.amount.formatted(.number.precision(.significantDigits(1...6))) + " " + p.symbol)
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                Text(p.protocolName)
                Text("·")
                Text(String(format: "%.2f%% APY", p.apy))
                if p.earned > 0 {
                    Text("·")
                    Text("earned " + p.earned.formatted(.number.precision(.significantDigits(1...4))))
                }
                if p.exiting > 0 {
                    Text("·")
                    Text("exiting " + p.exiting.formatted(.number.precision(.significantDigits(1...4))))
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        }
        .buttonStyle(.plain)
    }

    private func holdingRow(_ h: WalletHolding) -> some View {
        let isOn = selected.contains(h.id)
        let value = resolvedPrices[h.id].map { $0 * h.quantity }
        return Button {
            if isOn { selected.remove(h.id) } else { selected.insert(h.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Theme.amber : Color.secondary)
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

    /// Two different failures live here and they need different words: we
    /// couldn't reach the price service, versus the address genuinely holds
    /// nothing we recognise. Telling someone to check their address when the
    /// network is the problem is how an app earns a one-star review.
    private var emptyResults: some View {
        // Three cases, not two. The third — every block explorer unreachable —
        // used to fall through to "Double-check the address", which accuses the
        // user of a typo during a network outage.
        ContentUnavailableView {
            Label(!reachedAnyChain ? "Couldn't reach the block explorers"
                    : catalog.coins.isEmpty ? "Couldn't load prices" : "No coins found",
                  systemImage: (!reachedAnyChain || catalog.coins.isEmpty)
                    ? "wifi.slash" : "questionmark.folder")
        } description: {
            if !reachedAnyChain {
                Text("Argus couldn't reach any of the selected block explorers, so it can't read this wallet yet. Your address is probably fine — check your connection and try again.")
            } else if catalog.coins.isEmpty {
                Text(catalog.lastError?.errorDescription
                     ?? "Argus couldn't reach the price service, so it can't value this wallet yet.")
            } else {
                Text("We didn't find tokens at that address on the selected chains. Double-check the address, or add holdings manually.")
            }
        } actions: {
            if !reachedAnyChain {
                Button("Try again") { scan() }
                    .buttonStyle(.borderedProminent)
                Button("Try another address") { phase = .input }
                    .buttonStyle(.bordered)
            } else if catalog.coins.isEmpty {
                Button("Try again") {
                    Task { await catalog.retry(); scan() }
                }
                .buttonStyle(.borderedProminent)
                Button("Try another address") { phase = .input }
                    .buttonStyle(.bordered)
            } else {
                Button("Try another address") { phase = .input }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Actions

    private func scan() {
        phase = .scanning
        let addr = address
        let selectedChains = Array(chains)
        Task {
            await catalog.load()   // ensure prices are available for filtering
            // Staked assets live in the protocol's contract, not the wallet, so
            // the balance scan above is blind to them. Fetch both concurrently.
            async let stakingTask = StakeWise.positions(address: addr)
            let scan = await WalletImporter.fetch(address: addr, chains: selectedChains)
            staking = (await stakingTask) ?? []
            reachedAnyChain = scan.reachedAnyChain
            // Only filter on "has a live price" when we actually have prices. If
            // the catalog didn't load, every holding fails that test and the
            // screen would blame the user's address for a price outage. The
            // balances are true either way — import them and let the value fill
            // in when prices come back.
            // Resolve every holding by CONTRACT, not symbol. The old filter
            // (`price(for: symbol) != nil`) looked like a quality gate and was the
            // opposite: it SELECTED counterfeits that impersonate a listed symbol
            // and discarded genuine but unlisted holdings.
            let havePrices = !catalog.coins.isEmpty
            // MERGE ON RESOLVED IDENTITY, NOT ON THE RAW CONTRACT.
            //
            // Keying holdings by (chain, contract) is what kills the counterfeit
            // problem, but taken all the way to the UI it also splits assets that
            // genuinely ARE the same thing: native ETH showed up as eight separate
            // rows, one per L2, and real USDC on Base and Arbitrum as two. A
            // portfolio tracker should say "ETH 10.19".
            //
            // The CoinGecko id is the right identity: every chain's native ETH
            // resolves to `ethereum`, real USDC everywhere resolves to `usd-coin`,
            // and a counterfeit resolves to nothing at all — so it can never merge
            // into a genuine holding. Anything unresolved stays separate and
            // unpriced, which is the honest outcome.
            identityReady = await ContractIndex.shared.ready()
            // One batched round trip for every ERC-20 on the scan, before the
            // loop, so per-holding resolution stays synchronous below.
            let llama = await LlamaPrices.prices(for: scan.holdings)
            var merged: [String: WalletHolding] = [:]
            var priceByID: [String: Decimal] = [:]
            var unpriced = 0
            for h in scan.holdings {
                // Identity + price, in priority order:
                //  1. DefiLlama, addressed by (chain, contract) and filtered on
                //     its own confidence score. Addressing by contract means a
                //     counterfeit cannot impersonate a real coin by borrowing its
                //     symbol, and it prices the long tail the other two sources
                //     miss entirely.
                //  2. the explorer's own per-contract exchange_rate. Present only
                //     for contracts it can match to a market feed, so it is
                //     simultaneously a price AND an anti-counterfeit check — but
                //     it can be thin or stale, which is why it is no longer first.
                //  3. the CoinGecko catalog, for native coins (whose symbol we
                //     control) and for cross-chain merging when the index loaded.
                let coinID = await catalog.coinID(forContract: h.contract, chain: h.chain,
                                                  nativeSymbol: h.symbol)
                let price = llama[h.id] ?? h.priceUSD ?? coinID.flatMap { catalog.price(forID: $0) }
                guard let p = price else {
                    if coinID != nil { unpriced += 1 }
                    continue
                }
                // Merge key: the CoinGecko id when known (so ETH across eight L2s
                // is one row), otherwise the contract, which never merges.
                let mergeKey = coinID ?? h.id
                if let existing = merged[mergeKey] {
                    merged[mergeKey] = WalletHolding(symbol: existing.symbol, name: existing.name,
                                                     quantity: existing.quantity + h.quantity,
                                                     contract: existing.contract, chain: existing.chain,
                                                     priceUSD: existing.priceUSD ?? h.priceUSD,
                                                     chainCount: existing.chainCount + 1)
                } else {
                    merged[mergeKey] = h
                }
                priceByID[mergeKey] = p
            }
            // Re-key prices onto the surviving holdings' ids for the row lookup.
            var byHoldingID: [String: Decimal] = [:]
            for (k, h) in merged { byHoldingID[h.id] = priceByID[k] }
            skippedUnpriced = unpriced
            resolvedPrices = byHoldingID
            // Sort by USD value, biggest first. With every holding pre-selected,
            // alphabetical order buries the positions that matter under dust —
            // a wallet can easily return 500+ rows, and the user's job here is to
            // glance down and uncheck what they don't want.
            let usable = havePrices
                ? merged.values.sorted { a, b in
                    let av = (byHoldingID[a.id] ?? 0) * a.quantity
                    let bv = (byHoldingID[b.id] ?? 0) * b.quantity
                    return av == bv ? a.symbol < b.symbol : av > bv
                  }
                : scan.holdings
            priced = usable
            selected = Set(usable.map(\.id)).union(staking.map(stakeKey))
            // "Nothing found" must account for STAKED positions too. Keyed on
            // usable alone, a wallet holding no priced tokens but a large vault
            // deposit fell through to the empty state and never rendered the
            // Staked section — the 27,444 ETH test address is exactly that
            // shape, and it would have reported an empty wallet.
            phase = (usable.isEmpty && staking.isEmpty) ? .empty : .results
        }
    }

    /// Short label for the wallet these holdings came from, so a second wallet
    /// imported later is distinguishable from the first. Built by the refresh so
    /// the two cannot drift apart — if they disagree, nothing ever reconciles.
    private var walletAccount: String { HoldingsRefresh.walletAccount(for: address) }

    private func importSelected() {
        let drafts: [TransactionDraft] = priced
            .filter { selected.contains($0.id) }
            .map { h in
                var d = TransactionDraft()
                d.kind = .balance
                d.asset = h.symbol
                // Provenance. Lots still pool per asset, but the portfolio can
                // now say which part of your ETH is sitting in a wallet and
                // which part is staked, instead of showing one merged number.
                d.account = walletAccount
                // Keep the contract, or this symbol can never be repriced: the
                // ledger stores "STLINK" and the catalog has never heard of it.
                TokenRegistry.remember(symbol: h.symbol, chain: h.chain, contract: h.contract)
                d.quantityText = "\(h.quantity)"
                if let p = resolvedPrices[h.id] { d.priceText = "\(p)" }
                return d
            }
        let stakeDrafts: [TransactionDraft] = staking
            .filter { selected.contains(stakeKey($0)) }
            .map { p in
                var d = TransactionDraft()
                d.kind = .balance
                // A StakeWise vault deposit is exposure to the vault's underlying
                // asset (ETH on mainnet, GNO on Gnosis), so it imports as that
                // asset. `exiting` is deliberately included: assets in the exit
                // queue are still owned, just no longer earning.
                d.asset = p.symbol
                d.account = "\(p.protocolName) \(p.vaultName)"
                d.quantityText = "\(p.amount)"
                if let price = catalog.price(for: p.symbol) { d.priceText = "\(price)" }
                return d
            }
        // Remember the address only when a staking position was actually taken,
        // so the launch refresh has something to re-check and nothing to do for
        // people who never staked.
        if !stakeDrafts.isEmpty {
            HoldingsRefresh.remember(address: address)
        }
        onImport(drafts + stakeDrafts)
        dismiss()
    }
}
