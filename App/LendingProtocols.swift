import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Compound v3, Fluid and Morpho — the same `Lending.Position` shape as Aave,
/// read three different ways because the protocols store positions three
/// different ways:
///
/// - Compound v3 is a short, fixed list of markets (one "Comet" per base
///   asset). `userBasic` says in one call whether a wallet has anything there.
/// - Fluid positions are NFTs. Its resolver lists a wallet's position ids and
///   returns each one as a flat, fixed-size struct.
/// - Morpho markets are permissionless — thousands, created by anyone — so no
///   fixed list exists to call. Its public API indexes them; one request covers
///   every chain.
///
/// Debt and collateral are separate legs in any coin: a USDC loan against
/// cbBTC is one position with a cbBTC collateral leg and a USDC debt leg.
///
/// Prices come from DefiLlama by contract (no wallet address is sent), except
/// Morpho, whose API returns its own. Compound's oracle is NOT used for USD: in
/// a WETH market it quotes in ETH (the base asset prices at exactly 1.0).
extension Lending {

    // MARK: - Shared

    /// Ledger drafts for one position: collateral as holdings, debt as a
    /// liability, both under the position's account. Priced at the
    /// protocol's current price, or `fallbackPrice` by symbol when a leg has
    /// none. No historical replay: the purchase price is editable afterwards.
    @MainActor
    static func drafts(for p: Position, fallbackPrice: (String) -> Decimal?) -> [TransactionDraft] {
        func draft(_ leg: Leg, _ kind: TransactionDraft.Kind) -> TransactionDraft {
            var d = TransactionDraft()
            d.kind = kind
            d.asset = leg.symbol
            d.account = p.accountLabel
            d.quantityText = UserNumber.text(leg.amount)
            d.healthFactor = p.healthFactor
            if let price = leg.unitPriceUSD ?? fallbackPrice(leg.symbol) { d.priceText = UserNumber.text(price) }
            return d
        }
        return p.collateral.map { draft($0, .balance) } + p.debt.map { draft($0, .liability) }
    }

    /// Symbols of debts the user typed in by hand. An imported loan in one of
    /// these coins may be the same loan, and adding both counts it twice.
    static func overlap(_ p: Position, manualDebts: Set<String>) -> [String] {
        p.debt.map { $0.symbol.uppercased() }.filter(manualDebts.contains)
    }

    /// Public RPCs, the same hosts the Aave reader uses, plus Unichain.
    static let rpc: [WalletChain: String] = [
        .ethereum: "https://ethereum-rpc.publicnode.com",
        .base: "https://base-rpc.publicnode.com",
        .arbitrum: "https://arbitrum-one-rpc.publicnode.com",
        .optimism: "https://optimism-rpc.publicnode.com",
        .polygon: "https://polygon-bor-rpc.publicnode.com",
        .scroll: "https://scroll-rpc.publicnode.com",
        .unichain: "https://mainnet.unichain.org",
    ]

    /// Fluid's marker for the chain's native coin.
    static let nativeMarker = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

    /// Native coins are priced through their wrapped contract.
    private static let wrappedNative: [WalletChain: (symbol: String, contract: String)] = [
        .ethereum: ("ETH", "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"),
        .base: ("ETH", "0x4200000000000000000000000000000000000006"),
        .optimism: ("ETH", "0x4200000000000000000000000000000000000006"),
        .arbitrum: ("ETH", "0x82af49447d8a07e3bd95bd0d56f35241523fbab1"),
        .polygon: ("POL", "0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270"),
    ]

    private struct TokenMeta: Sendable { var symbol: String; var decimals: Int }

    /// Symbol and decimals, read from the token itself. Nil when it does not
    /// answer — the caller must treat the position as not fully read.
    private static func meta(_ token: String, chain: WalletChain, rpc: String) async -> TokenMeta? {
        if token == nativeMarker {
            return wrappedNative[chain].map { TokenMeta(symbol: $0.symbol, decimals: 18) }
        }
        async let symW = ethCall(rpc: rpc, to: token, data: "0x95d89b41")
        async let decW = ethCall(rpc: rpc, to: token, data: "0x313ce567")
        guard let symW = await symW, let symbol = decodeSymbol(symW), !symbol.isEmpty,
              let decW = await decW, let first = decW.first,
              let decimals = tokenDecimals(uint(first)) else { return nil }
        return TokenMeta(symbol: symbol, decimals: decimals)
    }

    /// USD by contract. Missing keys mean "no confident quote", never zero.
    private static func usd(_ tokens: Set<String>, chain: WalletChain) async -> [String: Decimal] {
        let pairs = tokens.map { token -> (chain: String, contract: String, id: String) in
            let contract = token == nativeMarker ? (wrappedNative[chain]?.contract ?? token) : token
            return (chain: chain.rawValue, contract: contract, id: token)
        }
        return await LlamaPrices.prices(pairs: pairs)
    }

    /// One row per coin. Two Morpho markets lending the same USDC are one debt.
    static func merged(_ legs: [Leg]) -> [Leg] {
        var out: [Leg] = []
        for leg in legs {
            if let i = out.firstIndex(where: { $0.underlying == leg.underlying }) {
                out[i].amount += leg.amount
            } else {
                out.append(leg)
            }
        }
        return out.sorted { $0.amount * ($0.unitPriceUSD ?? 0) > $1.amount * ($1.unitPriceUSD ?? 0) }
    }

    private static func value(_ legs: [Leg]) -> Decimal {
        legs.reduce(0) { $0 + $1.amount * ($1.unitPriceUSD ?? 0) }
    }

    private static func position(
        _ name: String, chain: WalletChain, user: String,
        collateral: [Leg], debt: [Leg], health: Decimal?,
        represented: [String], fullyRead: Bool
    ) -> Position {
        let c = merged(collateral), d = merged(debt)
        return Position(
            protocolName: name, chain: chain.rawValue, chainLabel: chain.label, wallet: user,
            collateral: c, debt: d, collateralUSD: value(c), debtUSD: value(d),
            healthFactor: d.isEmpty ? nil : health,
            representedTokens: represented, fullyRead: fullyRead)
    }

    // MARK: - Compound v3

    /// Comet addresses from the Compound-Foundation/comet `deployments/`
    /// folder, each checked on-chain (`baseToken`, `numAssets`) 2026-10-06.
    /// Linea, Mantle and Ronin markets exist but Argus has no wallet support
    /// on those chains.
    private static let comets: [(chain: WalletChain, address: String)] = [
        (.ethereum, "0xc3d688B66703497DAA19211EEdff47f25384cdc3"),  // USDC
        (.ethereum, "0x5D409e56D886231aDAf00c8775665AD0f9897b56"),  // USDS
        (.ethereum, "0x3Afdc9BCA9213A35503b077a6072F3D0d5AB0840"),  // USDT
        (.ethereum, "0xe85Dc543813B8c2CFEaAc371517b925a166a9293"),  // WBTC
        (.ethereum, "0xA17581A9E3356d9A858b789D68B4d866e593aE94"),  // WETH
        (.ethereum, "0x3D0bb1ccaB520A66e607822fC55BC921738fAFE3"),  // wstETH
        (.base, "0xb125E6687d4313864e53df431d5425969c15Eb2F"),      // USDC
        (.base, "0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf"),      // USDbC
        (.base, "0x46e6b214b524310239732D51387075E0e70970bf"),      // WETH
        (.base, "0x784efeB622244d2348d4F2522f8860B96fbEcE89"),      // AERO
        (.base, "0x2c776041CCFe903071AF44aa147368a9c8EEA518"),      // USDS
        (.arbitrum, "0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf"),  // USDC
        (.arbitrum, "0xA5EDBDD9646f8dFF606d7448e414884C7d905dCA"),  // USDC.e
        (.arbitrum, "0xd98Be00b5D27fc98112BdE293e487f8D4cA57d07"),  // USDT0
        (.arbitrum, "0x6f7D514bbD4aFf3BcD1140B7344b32f063dEe486"),  // WETH
        (.optimism, "0x2e44e174f7D53F0212823acC11C01A11d58c5bCB"),  // USDC
        (.optimism, "0x995E394b8B2437aC8Ce61Ee0bC610D617962B214"),  // USDT
        (.optimism, "0xE36A30D249f7761327fd973001A32010b521b6Fd"),  // WETH
        (.polygon, "0xF25212E676D1F7F89Cd72fFEe66158f541246445"),   // USDC
        (.polygon, "0xaeB318360f27748Acb200CE616E389A6C9409a07"),   // USDT
        (.scroll, "0xB2f97c1Bd3bf02f5e74d13f02E3e26F93D77CE44"),    // USDC
        (.unichain, "0x2c7118c4C88B9841FCF839074c26Ae8f035f2921"),  // USDC
        (.unichain, "0x6C987dDE50dB1dcDd32Cd4175778C2a291978E2a"),  // WETH
    ]

    /// Raw amounts from one Comet, before metadata and prices.
    private struct CometRead: Sendable {
        var base: String
        var supplied: Decimal
        var borrowed: Decimal
        /// (asset, raw amount, liquidation collateral factor scaled to 1).
        var collateral: [(String, Decimal, Decimal)]
        var complete: Bool
    }

    static func compoundScan(user: String, want: @Sendable (String, WalletChain) -> Bool) async -> Scan {
        let chains = Set(comets.map(\.chain)).filter { want("Compound", $0) && rpc[$0] != nil }
        var out = Scan()
        await withTaskGroup(of: (WalletChain, Bool, Position?).self) { group in
            for chain in chains {
                group.addTask { await compoundChain(chain, user: user) }
            }
            for await (chain, ok, p) in group {
                if ok { out.answered.insert(scopeKey("Compound", chain)) }
                if let p { out.positions.append(p) }
            }
        }
        return out
    }

    private static func compoundChain(_ chain: WalletChain, user: String) async -> (WalletChain, Bool, Position?) {
        guard let rpc = rpc[chain] else { return (chain, false, nil) }
        let markets = comets.filter { $0.chain == chain }.map { $0.address.lowercased() }
        var reads: [(comet: String, read: CometRead)] = []
        var answered = 0
        await withTaskGroup(of: (String, Bool, CometRead?).self) { group in
            for comet in markets {
                group.addTask {
                    let (ok, r) = await readComet(comet, user: user, rpc: rpc)
                    return (comet, ok, r)
                }
            }
            for await (comet, ok, r) in group {
                if ok { answered += 1 }
                if let r { reads.append((comet, r)) }
            }
        }
        // Every market on the chain must answer before "no position" means
        // "repaid"; a partial chain is reported as not answered.
        let chainAnswered = answered == markets.count
        guard !reads.isEmpty else { return (chain, chainAnswered, nil) }

        var tokens = Set<String>()
        for (_, r) in reads {
            tokens.insert(r.base)
            r.collateral.forEach { tokens.insert($0.0) }
        }
        var metas: [String: TokenMeta] = [:]
        await withTaskGroup(of: (String, TokenMeta?).self) { group in
            for t in tokens { group.addTask { (t, await meta(t, chain: chain, rpc: rpc)) } }
            for await (t, m) in group { if let m { metas[t] = m } }
        }
        let prices = await usd(tokens, chain: chain)

        var collateral: [Leg] = [], debt: [Leg] = []
        var fullyRead = chainAnswered
        var health: Decimal? = nil
        for (_, r) in reads {
            fullyRead = fullyRead && r.complete
            guard let baseMeta = metas[r.base] else { fullyRead = false; continue }
            let baseScale = pow10(baseMeta.decimals)
            if r.supplied > 0 {
                collateral.append(Leg(symbol: baseMeta.symbol, amount: r.supplied / baseScale,
                                      underlying: r.base, unitPriceUSD: prices[r.base]))
            }
            var liquidationValue: Decimal? = 0
            for (asset, raw, factor) in r.collateral {
                guard let m = metas[asset] else { fullyRead = false; continue }
                let amount = raw / pow10(m.decimals)
                collateral.append(Leg(symbol: m.symbol, amount: amount, underlying: asset, unitPriceUSD: prices[asset]))
                if let px = prices[asset], let v = liquidationValue { liquidationValue = v + amount * px * factor } else { liquidationValue = nil }
            }
            if r.borrowed > 0 {
                let amount = r.borrowed / baseScale
                debt.append(Leg(symbol: baseMeta.symbol, amount: amount, underlying: r.base, unitPriceUSD: prices[r.base]))
                // Each Comet is isolated, so the wallet is as safe as its
                // weakest market.
                if let lv = liquidationValue, let px = prices[r.base], px > 0 {
                    let hf = lv / (amount * px)
                    health = min(health ?? hf, hf)
                }
            }
        }
        guard !collateral.isEmpty || !debt.isEmpty else { return (chain, chainAnswered, nil) }
        // The Comet is itself the ERC-20 receipt for supplied base (cUSDCv3),
        // so the wallet scan must not list it as well.
        return (chain, chainAnswered, position("Compound", chain: chain, user: user,
                                                collateral: collateral, debt: debt, health: health,
                                                represented: reads.map(\.comet), fullyRead: fullyRead))
    }

    /// (answered, read). A nil read with `true` is "no position here".
    private static func readComet(_ comet: String, user: String, rpc: String) async -> (Bool, CometRead?) {
        let u = addressWord(user)
        // userBasic: principal (signed; negative is a borrow) and the
        // assetsIn bitmap of collateral held. Both zero means nothing here.
        guard let basic = await ethCall(rpc: rpc, to: comet, data: callData("dc4abafd", u)),
              basic.count >= 4 else { return (false, nil) }
        let principalNonZero = !basic[0].allSatisfy { $0 == "0" }
        let assetsIn = int(uint(basic[3]))
        guard principalNonZero || assetsIn != 0 else { return (true, nil) }

        guard let baseW = await ethCall(rpc: rpc, to: comet, data: "0xc55dae63"), let b = baseW.first
        else { return (false, nil) }
        let base = address(fromWord: b)
        async let borrowW = ethCall(rpc: rpc, to: comet, data: callData("374c49b4", u))
        async let supplyW = ethCall(rpc: rpc, to: comet, data: callData("70a08231", u))
        guard let borrowW = await borrowW, let bw = borrowW.first,
              let supplyW = await supplyW, let sw = supplyW.first else { return (false, nil) }

        var collateral: [(String, Decimal, Decimal)] = []
        var complete = true
        if assetsIn != 0 {
            for i in 0..<16 where assetsIn & (1 << i) != 0 {
                let idx = String(repeating: "0", count: 62) + String(format: "%02x", i)
                // AssetInfo: offset, asset, priceFeed, scale, borrowCF,
                // liquidateCF, liquidationFactor, supplyCap.
                guard let info = await ethCall(rpc: rpc, to: comet, data: callData("c8c7fe6b", idx)),
                      info.count >= 6 else { complete = false; continue }
                let asset = address(fromWord: info[1])
                let factor = uint(info[5]) / pow10(18)
                guard let balW = await ethCall(rpc: rpc, to: comet, data: callData("5c2549ee", u + addressWord(asset))),
                      let bal = balW.first else { complete = false; continue }
                let raw = uint(bal)
                if raw > 0 { collateral.append((asset, raw, factor)) }
            }
        }
        let read = CometRead(base: base, supplied: uint(sw), borrowed: uint(bw),
                             collateral: collateral, complete: complete)
        guard read.supplied > 0 || read.borrowed > 0 || !collateral.isEmpty else { return (true, nil) }
        return (true, read)
    }

    // MARK: - Fluid

    /// Same VaultResolver address on every chain (Instadapp/fluid-contracts-public
    /// `deployments/*/VaultResolver.json`). Plasma also has one, but DefiLlama
    /// cannot price Plasma tokens yet, so a position there would read as $0.
    private static let fluidResolver = "0xA5C3E16523eeeDDcC34706b0E6bE88b4c6EA95cC"
    private static let fluidChains: [WalletChain] = [.ethereum, .base, .arbitrum, .polygon]

    static func fluidScan(user: String, want: @Sendable (String, WalletChain) -> Bool) async -> Scan {
        var out = Scan()
        await withTaskGroup(of: (WalletChain, Bool, Position?).self) { group in
            for chain in fluidChains where want("Fluid", chain) {
                group.addTask { await fluidChain(chain, user: user) }
            }
            for await (chain, ok, p) in group {
                if ok { out.answered.insert(scopeKey("Fluid", chain)) }
                if let p { out.positions.append(p) }
            }
        }
        return out
    }

    private static func fluidChain(_ chain: WalletChain, user: String) async -> (WalletChain, Bool, Position?) {
        guard let rpc = rpc[chain],
              let idsW = await ethCall(rpc: rpc, to: fluidResolver, data: callData("c67b5093", addressWord(user)))
        else { return (chain, false, nil) }
        // uint256[]: offset, length, items.
        guard idsW.count >= 2 else { return (chain, true, nil) }
        let n = int(uint(idsW[1]))
        guard n > 0, idsW.count >= 2 + n else { return (chain, true, nil) }
        let ids = idsW[2..<(2 + n)].map { String($0) }

        // positionByNftId returns two static structs, so the answer is a flat
        // run of words: UserPosition (0–11) then VaultEntireData from 12.
        // supply 9, borrow 10, isSmartCol 13, isSmartDebt 14, supplyToken.token0
        // 23, borrowToken.token0 25, liquidationThreshold 36 (basis points).
        // Amounts are in each token's own decimals (checked against live Base
        // positions, e.g. 1.5 cbBTC against 47,025 USDC).
        struct Raw { var col: String; var debt: String; var supply: Decimal; var borrow: Decimal; var lt: Decimal }
        var raws: [Raw] = []
        var fullyRead = true
        await withTaskGroup(of: Raw??.self) { group in
            for id in ids {
                group.addTask {
                    guard let w = await ethCall(rpc: rpc, to: fluidResolver, data: callData("144128e8", id)),
                          w.count >= 37 else { return .some(nil) }
                    // Smart collateral / smart debt vaults hold DEX shares, not
                    // one token; not read yet.
                    if uint(w[13]) != 0 || uint(w[14]) != 0 { return .none }
                    return .some(Raw(col: address(fromWord: w[23]), debt: address(fromWord: w[25]),
                                     supply: uint(w[9]), borrow: uint(w[10]), lt: uint(w[36]) / 10_000))
                }
            }
            for await r in group {
                switch r {
                case .some(.some(let raw)): if raw.supply > 0 || raw.borrow > 0 { raws.append(raw) }
                case .some(.none): fullyRead = false
                case .none: break
                }
            }
        }
        guard !raws.isEmpty else { return (chain, true, nil) }

        let tokens = Set(raws.flatMap { [$0.col, $0.debt] })
        var metas: [String: TokenMeta] = [:]
        await withTaskGroup(of: (String, TokenMeta?).self) { group in
            for t in tokens { group.addTask { (t, await meta(t, chain: chain, rpc: rpc)) } }
            for await (t, m) in group { if let m { metas[t] = m } }
        }
        let prices = await usd(tokens, chain: chain)

        var collateral: [Leg] = [], debt: [Leg] = []
        var health: Decimal? = nil
        for r in raws {
            guard let cm = metas[r.col], let dm = metas[r.debt] else { fullyRead = false; continue }
            let c = r.supply / pow10(cm.decimals), d = r.borrow / pow10(dm.decimals)
            let cName = r.col == nativeMarker ? nativeMarker : r.col
            if c > 0 { collateral.append(Leg(symbol: cm.symbol, amount: c, underlying: cName, unitPriceUSD: prices[r.col])) }
            if d > 0 {
                debt.append(Leg(symbol: dm.symbol, amount: d, underlying: r.debt, unitPriceUSD: prices[r.debt]))
                // Each NFT is its own isolated position.
                if let cp = prices[r.col], let dp = prices[r.debt], dp > 0 {
                    let hf = c * cp * r.lt / (d * dp)
                    health = min(health ?? hf, hf)
                }
            }
        }
        guard !collateral.isEmpty || !debt.isEmpty else { return (chain, true, nil) }
        return (chain, true, position("Fluid", chain: chain, user: user, collateral: collateral, debt: debt,
                                      health: health, represented: [], fullyRead: fullyRead))
    }

    // MARK: - Morpho

    /// Morpho's public GraphQL API (docs.morpho.org). No key; 750 requests a
    /// minute per IP, no SLA — so an outage must read as "not answered", never
    /// as "no loans".
    private static let morphoAPI = "https://api.morpho.org/graphql"
    private static let morphoChains: [Int: WalletChain] = [
        1: .ethereum, 8453: .base, 42161: .arbitrum, 10: .optimism, 137: .polygon, 130: .unichain,
    ]

    static func morphoScan(user: String, want: @Sendable (String, WalletChain) -> Bool) async -> Scan {
        let chains = morphoChains.filter { want("Morpho", $0.value) }
        guard !chains.isEmpty, let url = URL(string: morphoAPI) else { return Scan() }
        let query = """
        query($u:[String!],$c:[Int!]){ marketPositions(first:200, where:{userAddress_in:$u, chainId_in:$c}) { items { \
        healthFactor market { listed chain { id } \
        loanAsset { symbol address decimals priceUsd } collateralAsset { symbol address decimals priceUsd } } \
        state { borrowAssets collateral supplyAssets } } } }
        """
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": query, "variables": ["u": [user], "c": Array(chains.keys)],
        ])
        guard let (body, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              obj["errors"] == nil,
              let data = obj["data"] as? [String: Any],
              let mp = data["marketPositions"] as? [String: Any],
              let items = mp["items"] as? [[String: Any]] else { return Scan() }

        var out = Scan()
        for chain in chains.values { out.answered.insert(scopeKey("Morpho", chain)) }

        struct Acc { var collateral: [Leg] = []; var debt: [Leg] = []; var health: Decimal? }
        var byChain: [WalletChain: Acc] = [:]
        for item in items {
            guard let market = item["market"] as? [String: Any],
                  // Anyone can create a Morpho market from any token, including
                  // fakes. Listed markets only — the same rule that keeps
                  // counterfeits out of the wallet scan.
                  market["listed"] as? Bool == true,
                  let chainID = (market["chain"] as? [String: Any])?["id"] as? Int,
                  let chain = morphoChains[chainID],
                  let state = item["state"] as? [String: Any],
                  let loan = market["loanAsset"] as? [String: Any] else { continue }
            var acc = byChain[chain] ?? Acc()
            if let leg = morphoLeg(loan, raw: state["borrowAssets"]) {
                acc.debt.append(leg)
                if let hf = decimal(item["healthFactor"]) { acc.health = min(acc.health ?? hf, hf) }
            }
            if let leg = morphoLeg(loan, raw: state["supplyAssets"]) { acc.collateral.append(leg) }
            if let col = market["collateralAsset"] as? [String: Any],
               let leg = morphoLeg(col, raw: state["collateral"]) { acc.collateral.append(leg) }
            byChain[chain] = acc
        }
        for (chain, acc) in byChain where !acc.collateral.isEmpty || !acc.debt.isEmpty {
            out.positions.append(position("Morpho", chain: chain, user: user, collateral: acc.collateral,
                                          debt: acc.debt, health: acc.health, represented: [], fullyRead: true))
        }
        return out
    }

    /// A leg from one Morpho asset and a raw amount, or nil when the amount is
    /// zero or the asset has no USD price (an unpriced asset in a listed
    /// market is rare, and booking it at $0 would understate a loan).
    private static func morphoLeg(_ asset: [String: Any], raw: Any?) -> Leg? {
        guard let amount = decimal(raw), amount > 0,
              let symbol = asset["symbol"] as? String, !symbol.isEmpty,
              let address = asset["address"] as? String,
              let decimals = asset["decimals"] as? Int,
              let price = decimal(asset["priceUsd"]), price > 0 else { return nil }
        return Leg(symbol: symbol, amount: amount / pow10(decimals),
                   underlying: address.lowercased(), unitPriceUSD: price)
    }

    /// The API returns big amounts as strings and small ones as numbers.
    private static func decimal(_ v: Any?) -> Decimal? {
        switch v {
        case let s as String: return Decimal(string: s)
        case let n as NSNumber: return Decimal(string: n.stringValue)
        default: return nil
        }
    }
}
