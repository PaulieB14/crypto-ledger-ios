import Foundation

/// Parses numbers a person typed, in whatever format their keyboard offers.
///
/// `Decimal(string:)` has no locale and stops at the first character it does
/// not understand, so it does not fail on European input — it silently
/// truncates it. Reported from Germany 2026-08-29 with a screenshot: the
/// decimal-pad offers a comma, the user types "0,5", and the Add button never
/// enables because the value parses as 0. The worse case never reaches a
/// disabled button at all — "1,5" parsed as 1, so someone entering 1.5 BTC
/// silently recorded 1 BTC, in an app whose whole job is being right about
/// what you own.
///
///     Decimal(string: "0,5")      -> 0        (Add stays disabled)
///     Decimal(string: "1,5")      -> 1        (silently wrong)
///     Decimal(string: "1.234,56") -> 1.234    (silently wrong)
///
/// Use this for anything a person types. Do NOT use it on API responses —
/// JSON numbers are always dot-decimal, and running them through a
/// locale-aware parser would break them for exactly the users this fixes.

enum UserNumber {
    static func decimal(_ raw: String, locale: Locale = .current) -> Decimal? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // Grouping can arrive as space, NBSP, narrow NBSP or apostrophe (de-CH).
        for junk in ["\u{00A0}", "\u{202F}", "\u{2009}", "'", "’", " "] { s = s.replacingOccurrences(of: junk, with: "") }
        var negative = false
        if s.hasPrefix("-") { negative = true; s.removeFirst() }
        else if s.hasPrefix("+") { s.removeFirst() }
        guard !s.isEmpty, s.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) else { return nil }

        // Is `sep` usable as a grouping separator here? Grouping means the
        // first group is 1-3 digits and every later group is exactly 3.
        // "1.234" can group; "0.5" cannot, which is what tells a German
        // user's "0.5" apart from their "1.234".
        func groups(_ t: String, _ sep: Character) -> Bool {
            let parts = t.split(separator: sep, omittingEmptySubsequences: false)
            guard parts.count >= 2, let first = parts.first,
                  (1...3).contains(first.count), first.allSatisfy({ $0.isNumber }) else { return false }
            return parts.dropFirst().allSatisfy { $0.count == 3 && $0.allSatisfy { $0.isNumber } }
        }

        let dots = s.filter { $0 == "." }.count
        let commas = s.filter { $0 == "," }.count
        var decimalSep: Character?
        if dots > 0 && commas > 0 {
            // Both present: the later one is the decimal, the earlier must group.
            let d = s.lastIndex(of: ".")!, c = s.lastIndex(of: ",")!
            decimalSep = d > c ? "." : ","
            let other: Character = decimalSep == "." ? "," : "."
            let intSide = String(s[s.startIndex..<(decimalSep == "." ? d : c)])
            guard groups(intSide, other) else { return nil }
        } else if dots > 1 || commas > 1 {
            // Repeated single separator: only valid as grouping.
            let sep: Character = dots > 1 ? "." : ","
            guard groups(s, sep) else { return nil }
            decimalSep = nil
        } else if dots == 1 || commas == 1 {
            let sep: Character = dots == 1 ? "." : ","
            let localeGroup = locale.groupingSeparator.flatMap { $0.first }
            // Grouping only if it could group AND that is this locale's grouping mark.
            decimalSep = (groups(s, sep) && sep == localeGroup) ? nil : sep
        }

        var intPart = s, fracPart = ""
        if let sep = decimalSep, let idx = s.lastIndex(of: sep) {
            intPart = String(s[s.startIndex..<idx]); fracPart = String(s[s.index(after: idx)...])
        }
        intPart = intPart.filter { $0.isNumber }
        guard fracPart.allSatisfy({ $0.isNumber }) else { return nil }
        if intPart.isEmpty && fracPart.isEmpty { return nil }
        let normalized = (intPart.isEmpty ? "0" : intPart) + (fracPart.isEmpty ? "" : "." + fracPart)
        guard let d = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return negative ? -d : d
    }
}
