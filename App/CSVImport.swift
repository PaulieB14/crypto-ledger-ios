import Foundation

/// Parses a CSV of transactions into `TransactionDraft`s. Lenient by design:
/// it skips a header row, tolerates extra whitespace/quotes, accepts several
/// date formats and type aliases, and reports per-line problems rather than
/// failing the whole import.
///
/// Columns: `date, type, asset, quantity, price, account`
/// Types:   buy · sell · receive · deposit  (aliases accepted)
enum CSVImport {

    struct Result {
        var drafts: [TransactionDraft]
        var errors: [String]
    }

    static func parse(_ raw: String) -> Result {
        var drafts: [TransactionDraft] = []
        var errors: [String] = []
        var sawHeader = false

        let lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let cols = splitCSV(trimmed)

            if !sawHeader {
                let lowered = cols.map { $0.lowercased() }
                if lowered.contains("type") || lowered.contains("asset") || lowered.contains("date") {
                    sawHeader = true
                    continue                       // it's a header row
                }
                sawHeader = true                    // no header; treat as data
            }

            switch row(cols, line: idx + 1) {
            case .success(let d): drafts.append(d)
            case .failure(let msg): errors.append(msg)
            }
        }
        return Result(drafts: drafts, errors: errors)
    }

    private enum RowResult { case success(TransactionDraft); case failure(String) }

    private static func row(_ c: [String], line: Int) -> RowResult {
        guard c.count >= 4 else {
            return .failure("Line \(line): need at least date, type, asset, quantity")
        }
        guard let kind = kind(from: c[1].lowercased()) else {
            return .failure("Line \(line): unknown type “\(c[1])”")
        }
        let qtyText = c[3].trimmingCharacters(in: .whitespaces)
        guard UserNumber.decimal(qtyText) != nil else {
            return .failure("Line \(line): quantity “\(c[3])” isn’t a number")
        }

        var d = TransactionDraft()
        d.kind = kind
        d.asset = kind.isCash ? "USD" : c[2].uppercased()
        d.quantityText = qtyText
        d.priceText = c.count > 4 ? c[4].trimmingCharacters(in: .whitespaces) : ""
        d.account = (c.count > 5 && !c[5].isEmpty) ? c[5] : "Import"
        d.date = parseDate(c[0]) ?? .now

        guard d.isValid else {
            return .failure("Line \(line): \(kind.title.lowercased()) needs a positive price")
        }
        return .success(d)
    }

    private static func kind(from s: String) -> TransactionDraft.Kind? {
        switch s {
        case "buy", "purchase", "bought": .buy
        case "sell", "sale", "sold": .sell
        case "receive", "received", "airdrop", "reward", "transfer", "transfer_in", "transferin": .receive
        case "deposit", "cash", "fiat", "add_cash", "addcash": .deposit
        default: nil
        }
    }

    private static func splitCSV(_ line: String) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
              .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }

    private static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .now }
        if let d = try? Date(t, strategy: .iso8601) { return d }
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd", "MM/dd/yyyy", "yyyy/MM/dd", "dd-MM-yyyy"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .gmt
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    /// The header row on its own — a genuine starting point for someone typing
    /// their own history in. Deliberately not a set of pre-filled holdings: a
    /// one-tap path to a fabricated portfolio is indistinguishable from demo
    /// content left in a shipped app.
    static let headerTemplate = "date,type,asset,quantity,price,account\n"

    /// Shown as read-only help so the expected shape is obvious without putting
    /// invented transactions anywhere near the user's ledger.
    static let formatExample = """
    date,type,asset,quantity,price,account
    2024-01-15,buy,BTC,0.25,42000,Coinbase
    2024-03-10,deposit,USD,5000,,Bank
    2024-05-20,sell,BTC,0.1,66000,Coinbase
    """
}
