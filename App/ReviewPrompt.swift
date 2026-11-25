import Foundation

/// Whether to call `SKStoreReviewController` / `requestReview`.
///
/// One try per marketing version, and only after a wallet import that actually
/// added holdings. The system may still show nothing. We record the version
/// before the call so a second import in the same version does not ask again.
enum ReviewPrompt {
    static let askedVersionKey = "reviewPrompt.askedVersion"

    static func currentVersion(bundle: Bundle = .main) -> String {
        let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func askedVersion(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: askedVersionKey)
    }

    /// `succeeded` is "the import added at least one holding". A cancel, an
    /// empty selection, or a failed scan must not ask.
    static func shouldAsk(currentVersion: String, askedVersion: String?, succeeded: Bool) -> Bool {
        guard succeeded else { return false }
        let version = currentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return false }
        return askedVersion != version
    }

    static func markAsked(_ version: String, defaults: UserDefaults = .standard) {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults.set(trimmed, forKey: askedVersionKey)
    }
}
