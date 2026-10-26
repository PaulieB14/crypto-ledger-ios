import Foundation

/// Livepeer and The Graph delegations — the same "a balance scan cannot see it"
/// problem as StakeWise (see Staking.swift), read a different way.
///
/// WHY eth_call AND NOT A SUBGRAPH
/// Both protocols' subgraphs are served only through The Graph's gateway, which
/// needs an API key, and Argus ships with none. The contracts themselves are
/// public, so these read the state straight from Arbitrum One through its public
/// RPC. No key, no account.
///
/// Contract addresses and signatures were checked against the protocols' own
/// sources, not copied from memory:
///  - Livepeer BondingManager (proxy) on Arbitrum, per docs.livepeer.org
///    "contract addresses"; ABI from livepeer/protocol (branch delta),
///    contracts/bonding/BondingManager.sol.
///  - The Graph HorizonStaking on Arbitrum, per graphprotocol/contracts
///    packages/horizon/addresses.json (chain 42161). It is the same proxy that
///    was L2Staking, upgraded in place for Horizon, so pre-Horizon delegations
///    live at the same address.

enum ArbitrumRPC {
    /// Offchain Labs' public endpoint. It caps eth_getLogs at 10M blocks per
    /// request, which the Graph scan below is sized for.
    static let endpoint = "https://arb1.arbitrum.io/rpc"

    enum Failure: Error { case unreachable }

    static func request(_ method: String, _ params: [Any]) async throws -> Any {
        guard let url = URL(string: endpoint) else { throw Failure.unreachable }
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        for attempt in 0..<2 {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               root["error"] == nil, let result = root["result"] {
                return result
            }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 600_000_000) }
        }
        throw Failure.unreachable
    }

    /// Read-only contract call; returns the result's 32-byte words.
    static func call(_ to: String, _ data: String) async throws -> [String] {
        let r = try await request("eth_call", [["to": to, "data": data], "latest"])
        guard let hex = r as? String else { throw Failure.unreachable }
        return EthABI.words(hex)
    }

    static func blockNumber() async throws -> Int {
        guard let hex = try await request("eth_blockNumber", []) as? String,
              let n = Int(hex.dropFirst(2), radix: 16) else { throw Failure.unreachable }
        return n
    }

    /// Topics of every matching log in [from, to].
    static func logTopics(address: String, topics: [Any], from: Int, to: Int) async throws -> [[String]] {
        let r = try await request("eth_getLogs", [[
            "address": address, "topics": topics,
            "fromBlock": "0x" + String(from, radix: 16), "toBlock": "0x" + String(to, radix: 16),
        ]])
        guard let rows = r as? [[String: Any]] else { throw Failure.unreachable }
        return rows.compactMap { $0["topics"] as? [String] }
    }
}

private func short(_ a: String) -> String { "\(a.prefix(6))…\(a.suffix(4))" }

// MARK: - Livepeer

enum Livepeer {
    static let bondingManager = "0x35Bcf3c30594191d53231E4FF333E8A770453e40"

    // Selectors = first 4 bytes of keccak256(signature), computed and then
    // exercised with a live eth_call before being written down here.
    static let getDelegator = "0xa64ad595"               // getDelegator(address)
    static let pendingStake = "0x9d0b2c7a"               // pendingStake(address,uint256)
    static let getUnbondingLock = "0x412f83b6"           // getDelegatorUnbondingLock(address,uint256)

    /// The one LPT stake an address can have. nil = RPC unreachable; [] = none.
    static func positions(address: String) async -> [StakingPosition]? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidEVMAddress(a) else { return [] }
        let arg = EthABI.pad(address: a)
        do {
            // (bondedAmount, fees, delegateAddress, delegatedAmount, startRound,
            //  lastClaimRound, nextUnbondingLockId)
            let d = try await ArbitrumRPC.call(bondingManager, getDelegator + arg)
            guard d.count >= 7 else { return nil }
            let bonded = EthABI.tokens(EthABI.uint(d[0]))
            let orchestrator = EthABI.address(d[2])
            // The deployed pendingStake ignores its round argument and always
            // uses the current round; it is bonded + rewards not yet claimed.
            let pw = try await ArbitrumRPC.call(bondingManager, pendingStake + arg + EthABI.pad(uint: 0))
            let pending = pw.first.map { EthABI.tokens(EthABI.uint($0)) } ?? bonded

            // Unbonding locks are numbered 0..<next. A withdrawn or rebonded lock
            // reads back as zero; only the recent ones can still hold anything
            // in practice, so cap the walk.
            let next = NSDecimalNumber(decimal: EthABI.uint(d[6])).intValue
            var unbonding = Decimal(0)
            for id in max(0, next - 25)..<max(0, next) {
                let w = try await ArbitrumRPC.call(bondingManager, getUnbondingLock + arg + EthABI.pad(uint: id))
                if let first = w.first { unbonding += EthABI.tokens(EthABI.uint(first)) }
            }

            let staked = max(pending, bonded)
            guard staked + unbonding >= Decimal(string: "0.0001")! else { return [] }
            return [StakingPosition(
                protocolName: "Livepeer",
                vaultName: "Orchestrator \(short(orchestrator))",
                vaultAddress: orchestrator,
                chain: "arbitrum",
                symbol: "LPT",
                amount: staked + unbonding,
                earned: max(0, staked - bonded),
                apy: 0,
                exiting: unbonding,
                mintedOsToken: 0)]
        } catch {
            return nil
        }
    }
}

// MARK: - The Graph

enum GraphDelegation {
    static let horizonStaking = "0x00669A4CF01450B64E8A2A20E9b1FCB71E61eF03"

    static let getSubgraphService = "0x9363c522"   // getSubgraphService()
    static let getDelegation = "0xccebcabb"        // getDelegation(address,address,address)
    static let getDelegationPool = "0x561285e4"    // getDelegationPool(address,address)
    static let getThawRequestList = "0xe56f8a1d"   // getThawRequestList(uint8,address,address,address)
    static let getThawRequest = "0xd48de845"       // getThawRequest(uint8,bytes32)

    /// Pre-Horizon: StakeDelegated(address indexed indexer, address indexed delegator, uint256, uint256)
    static let stakeDelegatedTopic = "0xcd0366dce5247d874ffc60a762aa7abbb82c1695bbb171609c1b8861e279eb73"
    /// Horizon: TokensDelegated(address indexed serviceProvider, address indexed verifier, address indexed delegator, uint256, uint256)
    static let tokensDelegatedTopic = "0x237818af8bb47710142edd8fc301fbc507064fb357cf122fb161ca447e3cb13e"

    /// No delegation event exists before this block (the staking proxy's first
    /// StakeDelegated on Arbitrum is at ~60.6M), so the scan starts here.
    static let firstBlock = 60_000_000
    static let span = 10_000_000          // arb1.arbitrum.io's per-request getLogs cap

    /// ThawRequestType.Delegation in IHorizonStakingTypes.
    private static let thawTypeDelegation = 1

    /// Delegations cannot be enumerated by a view call — the contract only answers
    /// "how many shares does X hold with indexer Y". The indexers come from the
    /// delegator's own delegation events (filtered by the indexed delegator
    /// topic, so the RPC returns only this address's logs), cached per address
    /// with the last block scanned so later refreshes read only new blocks.
    private static func cacheKey(_ a: String) -> String { "argus.grt.delegations.\(a)" }

    /// (indexer, verifier) pairs this address has ever delegated to.
    static func candidates(address a: String, subgraphService: String) async throws -> Set<String> {
        let saved = UserDefaults.standard.dictionary(forKey: cacheKey(a))
        var pairs = Set((saved?["pairs"] as? [String]) ?? [])
        let start = ((saved?["block"] as? Int).map { $0 + 1 }) ?? firstBlock
        let head = try await ArbitrumRPC.blockNumber()
        guard start <= head else { return pairs }

        let me = "0x" + EthABI.pad(address: a)
        let ranges = stride(from: start, through: head, by: span).map { ($0, min($0 + span - 1, head)) }
        // A handful at a time — the public endpoint rate-limits bursts.
        for batch in stride(from: 0, to: ranges.count, by: 6) {
            let slice = ranges[batch..<min(batch + 6, ranges.count)]
            try await withThrowingTaskGroup(of: [String].self) { group in
                for (from, to) in slice {
                    group.addTask {
                        let legacy = try await ArbitrumRPC.logTopics(
                            address: horizonStaking, topics: [stakeDelegatedTopic, NSNull(), me], from: from, to: to)
                        let horizon = try await ArbitrumRPC.logTopics(
                            address: horizonStaking, topics: [tokensDelegatedTopic, NSNull(), NSNull(), me], from: from, to: to)
                        // Legacy delegations were migrated into the Subgraph
                        // Service's pool, so that is their verifier now.
                        return legacy.compactMap { t in t.count > 1 ? EthABI.address(t[1]) + ":" + subgraphService : nil }
                            + horizon.compactMap { t in t.count > 2 ? EthABI.address(t[1]) + ":" + EthABI.address(t[2]) : nil }
                    }
                }
                for try await found in group { pairs.formUnion(found) }
            }
        }
        UserDefaults.standard.set(["pairs": Array(pairs).sorted(), "block": head], forKey: cacheKey(a))
        return pairs
    }

    /// Every GRT delegation `address` holds, one position per indexer.
    /// nil = RPC unreachable; [] = none.
    static func positions(address: String) async -> [StakingPosition]? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidEVMAddress(a) else { return [] }
        do {
            guard let ssWord = try await ArbitrumRPC.call(horizonStaking, getSubgraphService).first else { return nil }
            let subgraphService = EthABI.address(ssWord)
            var out: [StakingPosition] = []
            for pair in try await candidates(address: a, subgraphService: subgraphService).sorted() {
                let parts = pair.split(separator: ":").map(String.init)
                guard parts.count == 2 else { continue }
                if let p = try await position(delegator: a, indexer: parts[0], verifier: parts[1],
                                              isLegacyPool: parts[1] == subgraphService) {
                    out.append(p)
                }
            }
            return out.sorted { $0.amount > $1.amount }
        } catch {
            return nil
        }
    }

    private static func position(delegator: String, indexer: String, verifier: String,
                                 isLegacyPool: Bool) async throws -> StakingPosition? {
        let sp = EthABI.pad(address: indexer), v = EthABI.pad(address: verifier), me = EthABI.pad(address: delegator)
        let shares = try await ArbitrumRPC.call(horizonStaking, getDelegation + sp + v + me).first.map(EthABI.uint) ?? 0
        // (tokens, shares, tokensThawing, sharesThawing, thawingNonce)
        let pool = try await ArbitrumRPC.call(horizonStaking, getDelegationPool + sp + v).map(EthABI.uint)
        guard pool.count >= 5 else { return nil }
        let active = EthABI.tokens(EthABI.proRata(EthABI.tokens(shares), pool[0], pool[1]))

        // Undelegated GRT thaws before it can be withdrawn. Each request holds
        // thawing shares; one from an older nonce was invalidated by a slash.
        // Still the delegator's until withdrawn, so it is shown, as `exiting`.
        var thawing = Decimal(0)
        let list = try await ArbitrumRPC.call(horizonStaking, getThawRequestList
            + EthABI.pad(uint: thawTypeDelegation) + sp + v + me)
        var cursor = list.first ?? String(repeating: "0", count: 64)
        var steps = 0
        while !EthABI.isZero(cursor) && steps < 50 {
            let r = try await ArbitrumRPC.call(horizonStaking, getThawRequest + EthABI.pad(uint: thawTypeDelegation) + cursor)
            guard r.count >= 4 else { break }
            if EthABI.uint(r[3]) == pool[4] {
                thawing += EthABI.tokens(EthABI.proRata(EthABI.tokens(EthABI.uint(r[0])), pool[2], pool[3]))
            }
            cursor = r[2]; steps += 1
        }

        guard active + thawing >= Decimal(string: "0.0001")! else { return nil }
        return StakingPosition(
            protocolName: "The Graph",
            vaultName: "Indexer \(short(indexer))" + (isLegacyPool ? "" : " (\(short(verifier)))"),
            vaultAddress: indexer,
            chain: "arbitrum",
            symbol: "GRT",
            amount: active + thawing,
            earned: 0,
            apy: 0,
            exiting: thawing,
            mintedOsToken: 0)
    }
}

// MARK: - All sources

enum Staking {
    /// Every staked position for `address` across StakeWise, Livepeer and The
    /// Graph. nil only if NO source could be reached; a source that failed is
    /// simply absent — callers already treat a missing position as "leave it".
    static func positions(address: String) async -> [StakingPosition]? {
        async let sw = StakeWise.positions(address: address)
        async let lp = Livepeer.positions(address: address)
        async let grt = GraphDelegation.positions(address: address)
        let all = [await sw, await lp, await grt]
        guard all.contains(where: { $0 != nil }) else { return nil }
        return all.compactMap { $0 }.flatMap { $0 }.sorted { $0.amount > $1.amount }
    }
}
