import Foundation

/// Staked positions — value you hold that a token-balance scan cannot see.
///
/// WHY THIS IS A SEPARATE SOURCE FROM WalletImporter
/// Wallet import reads ERC-20 balances. Staked assets are not balances: the
/// tokens sit in the protocol's own contract and the wallet holds a claim, not a
/// coin. StakeWise's own dashboard has the same split — its wallet panel shows
/// liquid tokens only, and vault deposits have to be read from the protocol.
/// So a wallet scan can be entirely correct and still miss most of what someone
/// owns.
///
/// Liquid staking tokens (stETH, rETH, cbETH, osETH) are ordinary ERC-20s and
/// already arrive through WalletImporter. This file is for the positions that do
/// not: currently StakeWise V3 vault deposits.
///
/// Keyless by design, like everything else here — StakeWise publish their own
/// graph nodes, so no credential ships in the app.

/// One vault deposit.
struct StakingPosition: Identifiable, Hashable, Sendable {
    /// Protocol that holds the stake, for display ("StakeWise").
    let protocolName: String
    /// Human vault name, e.g. "Genesis Vault".
    let vaultName: String
    let vaultAddress: String
    let chain: String
    /// Asset the stake is denominated in — ETH on mainnet, GNO on Gnosis.
    let symbol: String
    /// Current value of the position, in whole units of `symbol`.
    let amount: Decimal
    /// Lifetime rewards earned in this vault, in whole units.
    let earned: Decimal
    /// Current vault APY as a percentage, e.g. 2.31.
    let apy: Double
    /// Assets currently leaving the vault via the exit queue, if any. Still
    /// yours, but not earning — worth showing separately rather than silently
    /// folding into `amount`.
    let exiting: Decimal
    /// osETH minted against this position. It is a LIABILITY: the user holds
    /// that osETH as a token too, so counting both the stake and the minted
    /// token as assets would double-count. Surfaced so the UI can say so.
    let mintedOsToken: Decimal

    var id: String { "\(chain):\(vaultAddress)" }
}

enum StakeWise {
    /// StakeWise publish these graph nodes themselves — no API key, and no Graph
    /// Network query budget consumed. Replica is a straight failover.
    private struct Network {
        let chain: String, symbol: String, primary: String, replica: String
    }
    private static let networks = [
        Network(chain: "ethereum", symbol: "ETH",
                primary: "https://graphs.stakewise.io/mainnet/subgraphs/name/stakewise/prod",
                replica: "https://graphs-replica.stakewise.io/mainnet/subgraphs/name/stakewise/prod"),
        Network(chain: "gnosis", symbol: "GNO",
                primary: "https://graphs.stakewise.io/gnosis/subgraphs/name/stakewise/prod",
                replica: "https://graphs-replica.stakewise.io/gnosis/subgraphs/name/stakewise/prod"),
    ]

    /// Withdrawn positions leave wei-level dust behind that passes `assets_gt: 0`
    /// but renders as "0.0000" and makes a user think something is broken.
    /// 1e14 wei = 0.0001 ETH, cleanly above dust and below any real deposit.
    private static let dustWei = "100000000000000"

    private static let query = """
    query Positions($address: Bytes!) {
      allocators(
        first: 100
        where: { address: $address, assets_gt: "\(dustWei)" }
        orderBy: assets
        orderDirection: desc
      ) {
        assets exitingAssets apy mintedOsTokenShares totalEarnedAssets
        vault { id displayName tokenSymbol apy }
      }
    }
    """

    /// Fetch every StakeWise position for `address`, across both networks.
    /// Returns nil ONLY if no network could be reached — an empty array means
    /// "asked, and there are none", which the UI must not confuse with an error.
    static func positions(address: String) async -> [StakingPosition]? {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidEVMAddress(addr) else { return [] }

        var out: [StakingPosition] = []
        var reachedAny = false
        await withTaskGroup(of: (Bool, [StakingPosition]).self) { group in
            for n in networks {
                group.addTask { await fetch(network: n, address: addr) }
            }
            for await (ok, list) in group {
                if ok { reachedAny = true; out.append(contentsOf: list) }
            }
        }
        guard reachedAny else { return nil }
        return out.sorted { $0.amount > $1.amount }
    }

    private static func fetch(network n: Network, address: String) async -> (Bool, [StakingPosition]) {
        for endpoint in [n.primary, n.replica] {
            guard let url = URL(string: endpoint) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "query": query, "variables": ["address": address],
            ])
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { continue }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 { continue }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // A GraphQL error is an ANSWER, not an outage — do not fail over to
            // the replica for it, or a malformed query silently costs two calls.
            if root["errors"] != nil { return (true, []) }
            guard let d = root["data"] as? [String: Any],
                  let rows = d["allocators"] as? [[String: Any]] else { continue }

            let wei = Decimal(sign: .plus, exponent: 18, significand: 1)
            var list: [StakingPosition] = []
            for r in rows {
                let v = r["vault"] as? [String: Any] ?? [:]
                func dec(_ k: String, _ src: [String: Any]) -> Decimal {
                    Decimal(string: (src[k] as? String) ?? "0").map { $0 / wei } ?? 0
                }
                let amount = dec("assets", r)
                guard amount > 0 else { continue }
                let vaultApy = Double((v["apy"] as? String) ?? "") ?? Double((r["apy"] as? String) ?? "") ?? 0
                list.append(StakingPosition(
                    protocolName: "StakeWise",
                    vaultName: (v["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? (v["tokenSymbol"] as? String) ?? "Vault",
                    vaultAddress: ((v["id"] as? String) ?? "").lowercased(),
                    chain: n.chain,
                    symbol: n.symbol,
                    amount: amount,
                    earned: dec("totalEarnedAssets", r),
                    apy: vaultApy,
                    exiting: dec("exitingAssets", r),
                    mintedOsToken: dec("mintedOsTokenShares", r)))
            }
            return (true, list)
        }
        return (false, [])
    }
}
