import Foundation

/// Human-readable names for the orchestrators (Livepeer) and indexers (The
/// Graph) a wallet delegates to, plus a small registry tying each staked
/// ledger account back to the full delegate address.
///
/// DISPLAY ONLY. Ledger account labels stay "Livepeer Orchestrator 0xa031…b82f"
/// forever — they are the reconcile key (HoldingsRefresh.reconcile), so a name
/// that appears or changes later must never rename an account. Names are looked
/// up after the staking read, with a short timeout, and any failure just leaves
/// the short address showing.
///
/// Sources (keyless, checked live with curl before being written down):
///  - Livepeer Explorer's own ENS endpoint, which is what explorer.livepeer.org
///    shows for an orchestrator:
///      GET https://explorer.livepeer.org/api/ens-data/<addr>
///      -> {"id":"0x…","idShort":"0xa031…b82f","name":"embody-net.eth",…}
///    ("name": null when the address has no primary ENS name.)
///  - A generic ENS reverse lookup for everything else (Graph indexers), and as
///    the Livepeer fallback:
///      GET https://api.ensideas.com/ens/resolve/<addr>
///      -> {"address":"0x…","name":"embody-net.eth","displayName":…}
///
/// Pure Foundation, no app types, so the parsing runs in Tests/StakingABI.
enum DelegateNames {
    enum Kind: String, Codable, Sendable { case livepeer, graph, other }

    // MARK: Parsing

    /// `name` from either endpoint's JSON; nil when absent, null, empty, or
    /// not something we would want on screen.
    static func parseName(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["name"] as? String else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.hasPrefix("0x") else { return nil }
        return name
    }

    static func short(_ a: String) -> String { "\(a.prefix(6))…\(a.suffix(4))" }

    // MARK: Links

    static func explorerURL(kind: Kind, address: String) -> URL? {
        let a = address.lowercased()
        switch kind {
        case .livepeer: return URL(string: "https://explorer.livepeer.org/accounts/\(a)/orchestrating")
        case .graph: return URL(string: "https://thegraph.com/explorer/profile/\(a)?view=Indexing")
        case .other: return URL(string: "https://etherscan.io/address/\(a)")
        }
    }

    static func lookupURLs(kind: Kind, address: String) -> [URL] {
        let a = address.lowercased()
        var urls: [String] = []
        if kind == .livepeer { urls.append("https://explorer.livepeer.org/api/ens-data/\(a)") }
        urls.append("https://api.ensideas.com/ens/resolve/\(a)")
        return urls.compactMap(URL.init(string:))
    }

    // MARK: Cache

    private static let cacheKey = "argus.delegateNames.v1"
    /// A found name is kept a week; "no name" is re-asked after a day.
    static let ttlFound: TimeInterval = 7 * 86_400
    static let ttlMissing: TimeInterval = 86_400

    private static var cache: [String: [String: Any]] {
        get { (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: [String: Any]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: cacheKey) }
    }

    /// Cached name, even if stale — a stale name beats a hex string.
    static func cachedName(_ address: String) -> String? {
        let n = cache[address.lowercased()]?["name"] as? String
        return (n?.isEmpty ?? true) ? nil : n
    }

    /// Name if known, otherwise the short address.
    static func display(_ address: String) -> String { cachedName(address) ?? short(address) }

    private static func isFresh(_ address: String, now: Date = Date()) -> Bool {
        guard let row = cache[address.lowercased()], let at = row["at"] as? Double else { return false }
        let hasName = !((row["name"] as? String) ?? "").isEmpty
        return now.timeIntervalSince1970 - at < (hasName ? ttlFound : ttlMissing)
    }

    // MARK: Lookup

    /// Fill the cache for `addresses`. Never throws, never takes long: every
    /// request has a 6s timeout, and a failed request caches nothing (so it is
    /// retried next time) rather than caching "no name".
    static func resolve(_ addresses: [(kind: Kind, address: String)]) async {
        let todo = Dictionary(addresses.map { ($0.address.lowercased(), $0.kind) }, uniquingKeysWith: { a, _ in a })
            .filter { !isFresh($0.key) }
        guard !todo.isEmpty else { return }
        let found: [(String, String?)] = await withTaskGroup(of: (String, String?, Bool).self) { group in
            for (addr, kind) in todo {
                group.addTask {
                    var answered = false
                    for url in lookupURLs(kind: kind, address: addr) {
                        var req = URLRequest(url: url, timeoutInterval: 6)
                        req.setValue("application/json", forHTTPHeaderField: "accept")
                        guard let (data, resp) = try? await URLSession.shared.data(for: req),
                              (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                        answered = true
                        if let n = parseName(data) { return (addr, n, true) }
                    }
                    return (addr, nil, answered)
                }
            }
            var out: [(String, String?)] = []
            for await (a, n, ok) in group where ok { out.append((a, n)) }
            return out
        }
        guard !found.isEmpty else { return }
        var c = cache
        let now = Date().timeIntervalSince1970
        for (a, n) in found { c[a] = ["name": n ?? "", "at": now] }
        cache = c
    }
}

/// Which delegate each staked ledger account points at, and from which wallet.
/// Written whenever staking positions are read (import or refresh), so the
/// holdings screens can show the full address and a name without changing the
/// account label.
struct StakedDelegate: Codable, Hashable, Identifiable, Sendable {
    /// The ledger account label, e.g. "Livepeer Orchestrator 0xa031…b82f".
    var account: String
    var protocolName: String
    var symbol: String
    var kind: DelegateNames.Kind
    /// Full delegate address (orchestrator / indexer), lowercased.
    var address: String
    /// Wallets (lowercased) that delegate to it.
    var wallets: [String]
    var id: String { account + "|" + symbol }

    var displayName: String { DelegateNames.display(address) }
    var hasName: Bool { DelegateNames.cachedName(address) != nil }
    var explorerURL: URL? { DelegateNames.explorerURL(kind: kind, address: address) }
}

enum StakedDelegates {
    private static let key = "argus.stakedDelegates.v1"

    static var all: [StakedDelegate] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([StakedDelegate].self, from: data) else { return [] }
        return list
    }

    /// Merge `incoming` into `existing`: same account+symbol updates the
    /// address and unions wallets. Pure, so it is unit-tested.
    static func merge(_ existing: [StakedDelegate], _ incoming: [StakedDelegate]) -> [StakedDelegate] {
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for d in incoming {
            if var old = byID[d.id] {
                old.address = d.address
                old.wallets = Array(Set(old.wallets + d.wallets)).sorted()
                byID[d.id] = old
            } else {
                var n = d
                n.wallets = Array(Set(d.wallets)).sorted()
                byID[d.id] = n
            }
        }
        return byID.values.sorted { ($0.symbol, $0.account) < ($1.symbol, $1.account) }
    }

    static func record(_ incoming: [StakedDelegate]) {
        guard !incoming.isEmpty else { return }
        if let data = try? JSONEncoder().encode(merge(all, incoming)) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Delegates for one asset, limited to accounts the ledger still holds.
    static func delegates(symbol: String, accounts: Set<String>) -> [StakedDelegate] {
        all.filter { $0.symbol.uppercased() == symbol.uppercased() && accounts.contains($0.account) }
    }
}
