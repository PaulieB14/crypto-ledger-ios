import SwiftUI

/// Light / dark override.
///
/// The palette in Theme has always carried a dark value for every colour, so
/// dark mode worked — but only ever by following the system. That is the right
/// default and the wrong only-option: people read a portfolio in bed with the
/// phone on Light because the rest of the OS is, and a finance app that cannot
/// be pinned to dark gets closed rather than dimmed.
///
/// `.system` stores nothing and resolves to nil, so the untouched default stays
/// exactly the behaviour that shipped.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light:  "sun.max"
        case .dark:   "moon"
        }
    }

    /// Passed to `.preferredColorScheme`. nil means "whatever the system says".
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }
}
