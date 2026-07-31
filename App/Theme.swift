import SwiftUI

/// Currency formatting for *unit prices*, which span nine orders of magnitude
/// in this app. Two decimal places is right for a portfolio total and wrong for
/// a coin: GRT at $0.0149 renders as "$0.01" and anything under half a cent
/// renders as "$0.00", which looks broken and makes the position maths appear
/// not to add up. Totals keep the plain 2dp style.
enum PriceFormat {
    static func fractionDigits(for price: Decimal) -> Int {
        let p = abs((price as NSDecimalNumber).doubleValue)
        if p == 0 { return 2 }
        if p < 0.01 { return 6 }
        if p < 1 { return 4 }
        return 2
    }

    static func usd(_ price: Decimal) -> Decimal.FormatStyle.Currency {
        .currency(code: "USD").precision(.fractionLength(fractionDigits(for: price)))
    }
}
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Argus "Tape" design tokens — the honest reading instrument.
///
/// Neutral figures on warm paper (or near-black phosphor), amber as the single
/// accent, color spent only where money moved. Colors resolve for light AND
/// dark on both iOS and the macOS preview.
enum Theme {
    static let paper        = Color(light: 0xF5F4EF, dark: 0x0B0B0D)  // app background
    static let panel        = Color(light: 0xFFFFFF, dark: 0x16171A)  // raised surfaces
    static let ink          = Color(light: 0x1A1918, dark: 0xECEBE6)  // primary figures/text
    static let inkSecondary = Color(light: 0x62605A, dark: 0x8E8C85)  // labels, rubrics, data-age
    static let hairline     = Color(light: 0xE2E0D9, dark: 0x26262B)  // separators, gridlines
    static let amber        = Color(light: 0xB26206, dark: 0xF5B13C)  // the lone accent — used as a scalpel
    static let gain         = Color(light: 0x0A7D4D, dark: 0x35D07F)  // positive deltas only
    static let loss         = Color(light: 0xC0392E, dark: 0xFF6B63)  // negative deltas only
    static let tickFlash    = Color(light: 0xF6E7C8, dark: 0x241C0C)  // cell wash on a refresh settle
}

extension Font {
    /// Tabular monospaced figures — the ledger texture. Always pair with
    /// `.monospacedDigit()` at the call site for live-value transitions.
    static func figure(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Uppercase, tracked rubric — column headers and section labels.
    static func rubric(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .semibold)
    }
    /// The single editorial voice — datelines and honest empty states.
    static func editorial(_ size: CGFloat = 15) -> Font {
        .system(size: size, design: .serif).italic()
    }
}

extension Color {
    /// A color that resolves differently in light vs dark, on iOS and macOS.
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self = Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
        #elseif canImport(AppKit)
        self = Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
        #else
        self = Color(rgbHex: light)
        #endif
    }

    init(rgbHex: UInt32) {
        self = Color(.sRGB,
                     red: Double((rgbHex >> 16) & 0xFF) / 255,
                     green: Double((rgbHex >> 8) & 0xFF) / 255,
                     blue: Double(rgbHex & 0xFF) / 255,
                     opacity: 1)
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#elseif canImport(AppKit)
private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif
