import Foundation

/// One headline for a coin.
struct NewsItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let title: String
    let source: String
    let url: URL
    let published: Date?
}

/// Keyless per-coin news via Google News RSS — search by coin *name* (+ "crypto")
/// rather than the raw ticker, so ambiguous symbols (OP, SUI…) don't pull in
/// unrelated stories. No API key, works anywhere; upgradeable to CryptoPanic
/// later for sentiment tags.
enum News {
    static func fetch(query: String, limit: Int = 12) async -> [NewsItem] {
        var comps = URLComponents(string: "https://news.google.com/rss/search")!
        comps.queryItems = [
            .init(name: "q", value: query),
            .init(name: "hl", value: "en-US"),
            .init(name: "gl", value: "US"),
            .init(name: "ceid", value: "US:en"),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Mozilla/5.0 (crypto-ledger)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return [] }
        return RSSParser.parse(data, limit: limit)
    }
}

/// Minimal RSS item extractor. Google News items are
/// `<item><title>Headline - Source</title><link/><pubDate/><source/></item>`.
private final class RSSParser: NSObject, XMLParserDelegate {
    static func parse(_ data: Data, limit: Int) -> [NewsItem] {
        let d = RSSParser()
        let parser = XMLParser(data: data)
        parser.delegate = d
        parser.parse()
        return Array(d.items.prefix(limit))
    }

    private var items: [NewsItem] = []
    private var inItem = false
    private var element = ""
    private var title = "", link = "", pub = "", source = ""

    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        element = e
        if e == "item" { inItem = true; title = ""; link = ""; pub = ""; source = "" }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) {
        guard inItem else { return }
        switch element {
        case "title": title += s
        case "link": link += s
        case "pubDate": pub += s
        case "source": source += s
        default: break
        }
    }

    func parser(_ p: XMLParser, foundCDATA block: Data) {
        guard inItem, element == "title", let s = String(data: block, encoding: .utf8) else { return }
        title += s
    }

    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        if e == "item" {
            inItem = false
            let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
            var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !src.isEmpty, t.hasSuffix(" - \(src)") { t = String(t.dropLast(src.count + 3)) }
            if let u = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), !t.isEmpty {
                items.append(NewsItem(title: t, source: src.isEmpty ? "News" : src,
                                      url: u, published: Self.rfc822(pub)))
            }
        }
        element = ""
    }

    private static func rfc822(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
