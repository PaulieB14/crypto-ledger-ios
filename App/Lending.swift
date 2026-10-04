import Foundation
import LedgerCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Crypto-backed loans — collateral you still own, and the debt against it.
///
/// WalletImporter reads ERC-20 balances. On Aave that is the wrong shape: the
/// aToken is a receipt for collateral, and the variable-debt token is a
/// positive balance that is actually money you owe. Adding either one as a
/// holding misstates net worth, and adding both the receipt and the underlying
/// counts the collateral twice.
///
/// This is the same idea as StakeWise in Staking.swift — a position the token
/// list cannot see — with one difference. A vault deposit is a holding of the
/// underlying. A loan is not. Collateral is recorded as the underlying you
/// supplied (the receipt token is left out of the wallet list). Debt is a
/// liability, not a deposit and not a sale.
///
/// The position shape is protocol-agnostic (collateral legs, debt legs, an
/// optional health factor) so Morpho or Compound can fill it later. What is
/// wired today is Aave v3, plus Spark, which speaks the same Pool ABI.
///
/// Prices are the protocol oracle's current price, not a replay of the borrow.
/// Purchase price is editable afterwards; inventing one from history would be
/// a guess.
enum Lending {

    struct Leg: Hashable, Sendable {
        var symbol: String
        var amount: Decimal
        /// Underlying contract, lowercased.
        var underlying: String
        /// Oracle price in USD, when the market has one. Not a historical fill.
        var unitPriceUSD: Decimal?
    }

    struct Position: Identifiable, Hashable, Sendable {
        var protocolName: String
        /// `WalletChain.rawValue`, so a refresh can tell Ethereum from Base.
        var chain: String
        var chainLabel: String
        /// Lowercased address this position was read for. Part of the account key.
        var wallet: String
        var collateral: [Leg]
        var debt: [Leg]
        var collateralUSD: Decimal
        var debtUSD: Decimal
        /// Nil when the user has no debt, or the protocol does not expose one.
        var healthFactor: Decimal?
        /// aToken and debt-token contracts. The wallet scan must not also
        /// count these as holdings.
        var representedTokens: [String]
        /// True only when every reserve answered. A partial read must not be
        /// treated as "you repaid".
        var fullyRead: Bool

        var id: String { "\(protocolName):\(chain):\(wallet)" }
        /// Label from before the key included a wallet (`Aave Ethereum`).
        /// Refresh still matches it for a single-wallet row.
        var legacyAccountLabel: String {
            LendingAccountKey.legacyAccountID(protocolName: protocolName, chainLabel: chainLabel)
        }
        /// Protocol, chain, and wallet. Two addresses on one market are not one account.
        var accountLabel: String {
            LendingAccountKey.accountID(protocolName: protocolName, chainLabel: chainLabel, wallet: wallet)
        }
        var netUSD: Decimal { collateralUSD - debtUSD }
    }

    /// Nil only when no market could be reached. An empty array means every
    /// market that was asked answered, and none of them has a position.
    static func positions(address: String, chains: [WalletChain]) async -> [Position]? {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidEVMAddress(addr) else { return [] }
        let wanted = Set(chains)
        let markets = Self.markets.filter { wanted.contains($0.chain) }
        guard !markets.isEmpty else { return [] }

        var out: [Position] = []
        var reachedAny = false
        await withTaskGroup(of: (Bool, Position?).self) { group in
            for market in markets {
                group.addTask { await fetch(market: market, user: addr) }
            }
            for await (ok, position) in group {
                if ok { reachedAny = true }
                if let position { out.append(position) }
            }
        }
        guard reachedAny else { return nil }
        return out.sorted { $0.netUSD > $1.netUSD }
    }

    // MARK: - Markets

    /// One Aave-style pool. Data provider and oracle are discovered from the
    /// pool's addresses provider, so a fork only needs the pool address.
    private struct Market: Sendable {
        let protocolName: String
        let chain: WalletChain
        let pool: String
        let rpc: String
    }

    /// Pool addresses from the Aave address book (bgd-labs). Spark's Ethereum
    /// pool implements the same `getUserAccountData`.
    private static let markets: [Market] = [
        Market(protocolName: "Aave", chain: .ethereum, pool: "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
               rpc: "https://ethereum-rpc.publicnode.com"),
        Market(protocolName: "Aave", chain: .base, pool: "0xA238Dd80C259a72e81d7e4664a9801593F98d1c5",
               rpc: "https://base-rpc.publicnode.com"),
        Market(protocolName: "Aave", chain: .arbitrum, pool: "0x794a61358D6845594F94dc1DB02A252b5b4814aD",
               rpc: "https://arbitrum-one-rpc.publicnode.com"),
        Market(protocolName: "Aave", chain: .optimism, pool: "0x794a61358D6845594F94dc1DB02A252b5b4814aD",
               rpc: "https://optimism-rpc.publicnode.com"),
        Market(protocolName: "Aave", chain: .polygon, pool: "0x794a61358D6845594F94dc1DB02A252b5b4814aD",
               rpc: "https://polygon-bor-rpc.publicnode.com"),
        Market(protocolName: "Aave", chain: .gnosis, pool: "0xb50201558B00496A145fE76f7424749556E326D8",
               rpc: "https://gnosis-rpc.publicnode.com"),
        Market(protocolName: "Aave", chain: .scroll, pool: "0x11fCfe756c05AD438e312a7fd934381537D3cFfe",
               rpc: "https://scroll-rpc.publicnode.com"),
        Market(protocolName: "Aave", chain: .celo, pool: "0x3E59A31363E2ad014dcbc521c4a0d5757d9f3402",
               rpc: "https://forno.celo.org"),
        Market(protocolName: "Aave", chain: .zksync, pool: "0x78e30497a3c7527d953c6B1E3541b021A98Ac43c",
               rpc: "https://mainnet.era.zksync.io"),
        Market(protocolName: "Spark", chain: .ethereum, pool: "0xC13e21B648A5Ee794902342038FF3aDAB66BE987",
               rpc: "https://ethereum-rpc.publicnode.com"),
    ]

    // MARK: - One market

    private static func fetch(market: Market, user: String) async -> (Bool, Position?) {
        let userWord = addressWord(user)
        guard let account = await ethCall(rpc: market.rpc, to: market.pool,
                                           data: callData("bf92857c", userWord)),
              account.count >= 6 else { return (false, nil) }

        let collateralBase = uint(account[0])
        let debtBase = uint(account[1])
        guard collateralBase > 0 || debtBase > 0 else { return (true, nil) }

        let collateralUSD = collateralBase / pow10(8)
        let debtUSD = debtBase / pow10(8)
        let health: Decimal? = debtBase > 0 && !account[5].allSatisfy { $0 == "f" }
            ? uint(account[5]) / pow10(18) : nil

        guard let provider = await addressCall(rpc: market.rpc, to: market.pool, selector: "0542975c"),
              let dataProvider = await addressCall(rpc: market.rpc, to: provider, selector: "e860accb"),
              let oracle = await addressCall(rpc: market.rpc, to: provider, selector: "fca513a8"),
              let reserves = await reservesList(rpc: market.rpc, pool: market.pool)
        else {
            // The pool answered, so this is not an outage, but without reserves
            // we cannot tell a receipt token from a holding. Say nothing rather
            // than book a loan we cannot keep from being double-counted.
            return (true, nil)
        }

        var legs: [(asset: String, supplied: Decimal, debt: Decimal)] = []
        var fullyRead = true
        // A handful at a time. A mainnet pool has ~70 reserves; unbounded
        // fan-out gets the public RPC to start dropping calls, which then
        // looks like a partial repay.
        let batches = stride(from: 0, to: reserves.count, by: 8).map {
            Array(reserves[$0..<min($0 + 8, reserves.count)])
        }
        for batch in batches {
            await withTaskGroup(of: (String, Decimal, Decimal)?.self) { group in
                for asset in batch {
                    group.addTask {
                        guard let w = await ethCall(rpc: market.rpc, to: dataProvider,
                                                     data: callData("28dd2d01", addressWord(asset) + userWord)),
                              w.count >= 3 else { return nil }
                        let supplied = uint(w[0])
                        let owed = uint(w[1]) + uint(w[2])
                        guard supplied > 0 || owed > 0 else { return (asset, 0, 0) }
                        return (asset, supplied, owed)
                    }
                }
                for await row in group {
                    if let row {
                        if row.1 > 0 || row.2 > 0 { legs.append((row.0, row.1, row.2)) }
                    } else {
                        fullyRead = false
                    }
                }
            }
        }

        var collateral: [Leg] = []
        var debt: [Leg] = []
        var represented: [String] = []
        for leg in legs {
            async let tokens = ethCall(rpc: market.rpc, to: dataProvider,
                                        data: callData("d2493b6c", addressWord(leg.asset)))
            async let config = ethCall(rpc: market.rpc, to: dataProvider,
                                        data: callData("3e150141", addressWord(leg.asset)))
            async let priceWords = ethCall(rpc: market.rpc, to: oracle,
                                            data: callData("b3596f07", addressWord(leg.asset)))
            async let symbolWords = ethCall(rpc: market.rpc, to: leg.asset, data: "0x95d89b41")
            let (tokenW, configW, priceW, symW) = await (tokens, config, priceWords, symbolWords)
            guard let configW, let first = configW.first,
                  let symW,
                  let decimals = tokenDecimals(uint(first)),
                  let symbol = decodeSymbol(symW), !symbol.isEmpty
            else { fullyRead = false; continue }

            if let tokenW, tokenW.count >= 3 {
                for w in tokenW.prefix(3) {
                    let a = address(fromWord: w)
                    if !isZero(a) { represented.append(a) }
                }
            }
            let scale = pow10(decimals)
            let px: Decimal? = priceW.flatMap { $0.isEmpty ? nil : uint($0[0]) / pow10(8) }
            let price = (px ?? 0) > 0 ? px : nil
            if leg.supplied > 0 {
                collateral.append(Leg(symbol: symbol, amount: leg.supplied / scale,
                                       underlying: leg.asset.lowercased(), unitPriceUSD: price))
            }
            if leg.debt > 0 {
                debt.append(Leg(symbol: symbol, amount: leg.debt / scale,
                                 underlying: leg.asset.lowercased(), unitPriceUSD: price))
            }
        }

        guard !collateral.isEmpty || !debt.isEmpty else { return (true, nil) }
        return (true, Position(
            protocolName: market.protocolName,
            chain: market.chain.rawValue,
            chainLabel: market.chain.label,
            wallet: user,
            collateral: collateral.sorted { $0.amount > $1.amount },
            debt: debt.sorted { $0.amount > $1.amount },
            collateralUSD: collateralUSD,
            debtUSD: debtUSD,
            healthFactor: health,
            representedTokens: represented,
            fullyRead: fullyRead))
    }

    // MARK: - JSON-RPC / ABI

    private static func addressCall(rpc: String, to: String, selector: String) async -> String? {
        guard let w = await ethCall(rpc: rpc, to: to, data: callData(selector)), let first = w.first else { return nil }
        let a = address(fromWord: first)
        return isZero(a) ? nil : a
    }

    private static func reservesList(rpc: String, pool: String) async -> [String]? {
        guard let w = await ethCall(rpc: rpc, to: pool, data: "0xd1946dbc"),
              let first = w.first else { return nil }
        let offset = int(uint(first) / 32)
        guard offset >= 0, offset < w.count else { return nil }
        let n = int(uint(w[offset]))
        guard n >= 0, offset + 1 + n <= w.count else { return nil }
        return (0..<n).map { address(fromWord: w[offset + 1 + $0]) }
    }

    /// Hex words of an eth_call result, without the 0x. Nil if the node did
    /// not answer — which the caller must not confuse with a zero balance.
    private static func ethCall(rpc: String, to: String, data: String) async -> [String]? {
        guard let url = URL(string: rpc) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("argus", forHTTPHeaderField: "user-agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "eth_call",
            "params": [["to": to, "data": data], "latest"],
        ])
        guard let (body, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              obj["error"] == nil,
              let hex = obj["result"] as? String, hex.hasPrefix("0x") else { return nil }
        let raw = hex.dropFirst(2)
        guard raw.count >= 64, raw.count.isMultiple(of: 64) else { return raw.isEmpty ? [] : nil }
        var words: [String] = []
        var i = raw.startIndex
        while i < raw.endIndex {
            let j = raw.index(i, offsetBy: 64)
            words.append(String(raw[i..<j]))
            i = j
        }
        return words
    }

    private static func callData(_ selector: String, _ words: String = "") -> String {
        "0x" + selector + words
    }

    private static func addressWord(_ address: String) -> String {
        let hex = address.lowercased().hasPrefix("0x") ? String(address.lowercased().dropFirst(2)) : address.lowercased()
        return String(repeating: "0", count: max(0, 64 - hex.count)) + hex
    }

    private static func address(fromWord word: String) -> String {
        "0x" + word.suffix(40).lowercased()
    }

    private static func isZero(_ address: String) -> Bool {
        address == "0x" + String(repeating: "0", count: 40)
    }

    private static func int(_ value: Decimal) -> Int {
        Int(truncating: NSDecimalNumber(decimal: value))
    }

    private static func tokenDecimals(_ value: Decimal) -> Int? {
        let n = int(value)
        return (0...36).contains(n) ? n : nil
    }

    private static func uint(_ word: String) -> Decimal {
        var value = Decimal(0)
        for ch in word {
            guard let n = ch.hexDigitValue else { return 0 }
            value = value * 16 + Decimal(n)
        }
        return value
    }

    /// `symbol()` is a string on most tokens and a bytes32 on a few old ones.
    private static func decodeSymbol(_ words: [String]) -> String? {
        guard let first = words.first else { return nil }
        if words.count == 1, let byte = first.first, byte != "0" {
            let raw = Data(Data(hex: first).prefix { $0 != 0 })
            return String(data: raw, encoding: .utf8)
        }
        let offset = int(uint(first) / 32)
        guard offset >= 0, offset < words.count else { return nil }
        let length = int(uint(words[offset]))
        guard length > 0, length < 64 else { return nil }
        let packed = words[(offset + 1)...].joined()
        let bytes = Data(hex: String(packed.prefix(length * 2)))
        return String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespaces)
    }

    private static func pow10(_ n: Int) -> Decimal {
        var r = Decimal(1)
        for _ in 0..<max(0, n) { r *= 10 }
        return r
    }
}

private extension Data {
    init(hex: String) {
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let b = UInt8(hex[i..<j], radix: 16) { out.append(b) }
            i = j
        }
        self = out
    }
}
