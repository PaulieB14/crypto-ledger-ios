import Foundation
import Observation
#if os(iOS)
import UserNotifications
#endif

/// A user-set price threshold. When a coin's live price crosses it, Argus posts
/// a local notification. One-shot by design: it deactivates after firing so you
/// aren't pinged repeatedly on the same move — re-enable it to arm again.
struct PriceAlert: Identifiable, Codable, Hashable {
    enum Direction: String, Codable, CaseIterable, Identifiable {
        case above, below
        var id: String { rawValue }
        var label: String { self == .above ? "Rises above" : "Falls below" }
        var icon: String { self == .above ? "arrow.up.right" : "arrow.down.right" }
        /// Past tense, for the notification announcing that it happened:
        /// "BTC rose above $85,911".
        var verb: String { self == .above ? "rose above" : "fell below" }
        /// Present tense, for the setup screen describing what will happen:
        /// "Notify me when BTC rises above my target". The past-tense form was
        /// being reused here and read as a bug in a screenshot.
        var conditionVerb: String { self == .above ? "rises above" : "falls below" }
    }

    var id: UUID = UUID()
    var assetID: String
    var targetUSD: Decimal
    var direction: Direction
    var isActive: Bool = true
    var createdAt: Date = Date()
    var lastTriggeredAt: Date?

    func isCrossed(by price: Decimal) -> Bool {
        switch direction {
        case .above: price >= targetUSD
        case .below: price <= targetUSD
        }
    }
}

/// Local JSON persistence for alerts, alongside `LedgerStore`.
enum AlertPersistence {
    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("CryptoLedger", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("alerts.json")
    }

    static func load() -> [PriceAlert] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PriceAlert].self, from: data)) ?? []
    }

    static func save(_ alerts: [PriceAlert]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(alerts) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Observable owner of the user's price alerts. Handles CRUD, notification
/// permission, and foreground evaluation. Background evaluation runs through the
/// standalone `PriceAlertChecker` so it doesn't need the main actor.
@Observable
@MainActor
final class AlertStore {

    enum Permission { case unknown, granted, denied }

    private(set) var alerts: [PriceAlert] = []
    private(set) var permission: Permission = .unknown

    func load() {
        alerts = AlertPersistence.load()
        Task { await refreshPermission() }
    }

    func alerts(for assetID: String) -> [PriceAlert] {
        alerts.filter { $0.assetID == assetID }
              .sorted { ($0.isActive ? 0 : 1, $0.targetUSD) < ($1.isActive ? 0 : 1, $1.targetUSD) }
    }

    var activeCount: Int { alerts.filter(\.isActive).count }

    func add(_ alert: PriceAlert) {
        alerts.append(alert)
        AlertPersistence.save(alerts)
        Task { await requestPermission() }
    }

    func remove(_ alert: PriceAlert) {
        alerts.removeAll { $0.id == alert.id }
        AlertPersistence.save(alerts)
    }

    func setActive(_ alert: PriceAlert, _ active: Bool) {
        guard let i = alerts.firstIndex(where: { $0.id == alert.id }) else { return }
        alerts[i].isActive = active
        if active { alerts[i].lastTriggeredAt = nil }
        AlertPersistence.save(alerts)
        if active { Task { await requestPermission() } }
    }

    /// Compare live prices to every armed alert; fire and deactivate the ones
    /// that have crossed. Called after each foreground price refresh.
    func evaluate(spot: [String: Decimal]) {
        guard !alerts.isEmpty else { return }
        var changed = false
        for i in alerts.indices where alerts[i].isActive {
            guard let price = spot[alerts[i].assetID], price > 0,
                  alerts[i].isCrossed(by: price) else { continue }
            Notifier.fire(alerts[i], price: price)
            alerts[i].isActive = false
            alerts[i].lastTriggeredAt = Date()
            changed = true
        }
        if changed { AlertPersistence.save(alerts) }
    }

    func refreshPermission() async {
        #if os(iOS)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .denied: permission = .denied
        case .notDetermined: permission = .unknown
        default: permission = .granted
        }
        #else
        permission = .granted
        #endif
    }

    private func requestPermission() async {
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            await refreshPermission(); return
        }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        permission = granted ? .granted : .denied
        #endif
    }
}

/// Posts the actual local notification. Kept free of the main actor so both the
/// foreground store and the background checker can call it.
enum Notifier {
    static func fire(_ alert: PriceAlert, price: Decimal) {
        #if os(iOS)
        let content = UNMutableNotificationContent()
        content.title = "\(alert.assetID) \(alert.direction == .above ? "is up 📈" : "is down 📉")"
        content.body = "\(alert.assetID) \(alert.direction.verb) "
            + money(alert.targetUSD) + " — now " + money(price) + "."
        content.sound = .default
        let req = UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
        #endif
    }

    static func money(_ v: Decimal) -> String {
        v.formatted(.currency(code: "USD"))
    }
}

/// Standalone, main-actor-free alert evaluation for background refresh: fetch
/// current prices, fire any crossed alerts, and persist the updated state.
/// Returns the number of alerts that fired.
enum PriceAlertChecker {
    @discardableResult
    static func runOnce() async -> Int {
        var alerts = AlertPersistence.load()
        guard alerts.contains(where: \.isActive) else { return 0 }

        // A background refresh that can't reach CoinGecko simply does nothing —
        // iOS will hand us another opportunity shortly.
        let markets = (try? await CoinGecko.topMarkets()) ?? []
        guard !markets.isEmpty else { return 0 }
        var spot: [String: Decimal] = [:]
        for m in markets where spot[m.symbol] == nil { spot[m.symbol] = m.priceUSD }

        var fired = 0
        for i in alerts.indices where alerts[i].isActive {
            guard let price = spot[alerts[i].assetID], price > 0,
                  alerts[i].isCrossed(by: price) else { continue }
            Notifier.fire(alerts[i], price: price)
            alerts[i].isActive = false
            alerts[i].lastTriggeredAt = Date()
            fired += 1
        }
        if fired > 0 { AlertPersistence.save(alerts) }
        return fired
    }
}
