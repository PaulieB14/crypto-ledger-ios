import Foundation

/// Minimal ABI word handling for the handful of read-only `eth_call`s the
/// staking sources make. Pure Foundation and no app types, so the parsing can be
/// checked by the SwiftPM runner in Tests/StakingABI without Xcode.
///
/// Every value here is a static-size return (uint256 / address / bytes32), so a
/// response is just consecutive 32-byte words — no dynamic offsets to follow.
enum EthABI {
    /// 32-byte words of an `eth_call` result ("0x" + 64·n hex chars).
    static func words(_ hex: String) -> [String] {
        var s = hex.lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard s.count % 64 == 0 else { return [] }
        var out: [String] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 64)
            out.append(String(s[i..<j]))
            i = j
        }
        return out
    }

    /// A word as an unsigned integer. Decimal keeps 38 significant digits,
    /// which is exact for any token amount below ~1e20 whole tokens.
    static func uint(_ word: String) -> Decimal {
        var v = Decimal(0)
        for c in word {
            guard let d = c.hexDigitValue else { return 0 }
            v = v * 16 + Decimal(d)
        }
        return v
    }

    /// Lowercased 0x address held in the low 20 bytes of a word.
    static func address(_ word: String) -> String {
        "0x" + String(word.suffix(40)).lowercased()
    }

    static func isZero(_ word: String) -> Bool { word.allSatisfy { $0 == "0" } }

    /// Encode an address argument (with or without 0x) as one word.
    static func pad(address a: String) -> String {
        var s = a.lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) }
        return String(repeating: "0", count: max(0, 64 - s.count)) + s
    }

    /// Encode a small unsigned integer argument as one word.
    static func pad(uint n: Int) -> String {
        let h = String(n, radix: 16)
        return String(repeating: "0", count: max(0, 64 - h.count)) + h
    }

    /// Base units (18 decimals) to whole tokens.
    static func tokens(_ base: Decimal) -> Decimal {
        base / Decimal(sign: .plus, exponent: 18, significand: 1)
    }

    /// `shares × numerator ÷ denominator`, the share-to-token conversion Graph
    /// delegation pools use. Zero when the pool is empty.
    static func proRata(_ shares: Decimal, _ numerator: Decimal, _ denominator: Decimal) -> Decimal {
        guard denominator > 0 else { return 0 }
        return shares * numerator / denominator
    }
}
