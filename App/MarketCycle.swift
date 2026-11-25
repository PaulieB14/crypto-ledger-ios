import SwiftUI
#if os(iOS)
import SafariServices
import UIKit
#endif

/// Entry to the public Bitcoin cycle dashboard.
///
/// The card is a native control, not a fetched banner: pulling the site's
/// Open Graph image would look like an ad and would fail offline. Safari loads
/// the page only after a tap, inside SFSafariViewController, so the person
/// never leaves Argus and the app still ships with no API key.
enum MarketCycle {
    static let page = URL(string: "https://bitcoin-cycle-cockpit.vercel.app")!
}

struct MarketCycleCard: View {
    var body: some View {
        MarketCycleLink {
            HStack(spacing: 14) {
                CycleArcMark()
                VStack(alignment: .leading, spacing: 2) {
                    Text("BITCOIN")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.7)
                        .foregroundStyle(Theme.inkSecondary)
                    Text("Market Cycle")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text("Score, indicators, and the halving countdown.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.hairline, lineWidth: 1))
        }
        .accessibilityHint("Opens the Bitcoin cycle dashboard in Argus")
    }
}

/// Settings row. Same destination as the portfolio card.
struct MarketCycleSettingsRow: View {
    var body: some View {
        MarketCycleLink {
            HStack {
                Label("Market Cycle", systemImage: "gauge.with.dots.needle.67percent")
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityHint("Opens the Bitcoin cycle dashboard in Argus")
    }
}

private struct MarketCycleLink<Label: View>: View {
    @Environment(\.openURL) private var openURL
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: open) {
            label
        }
        .buttonStyle(.plain)
    }

    private func open() {
        #if os(iOS)
        InAppSafari.present(MarketCycle.page)
        #else
        openURL(MarketCycle.page)
        #endif
    }
}

/// Gold gauge. A fixed arc, not a live score: the number lives on the dashboard.
private struct CycleArcMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.amber.opacity(0.14))
            Circle()
                .trim(from: 0.08, to: 0.92)
                .stroke(Theme.hairline, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .padding(7)
                .rotationEffect(.degrees(90))
            Circle()
                .trim(from: 0.08, to: 0.46)
                .stroke(Theme.amber, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .padding(7)
                .rotationEffect(.degrees(90))
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}

#if os(iOS)
/// Presents SFSafariViewController from the topmost controller.
///
/// Done is Safari's own button, which dismisses a controller presented this
/// way. A SwiftUI sheet around the same controller fights that button.
enum InAppSafari {
    @MainActor
    static func present(_ url: URL) {
        let configuration = SFSafariViewController.Configuration()
        configuration.barCollapsingEnabled = true
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        // Amber, the app's only accent, on Safari's own chrome.
        controller.preferredControlTintColor = UIColor(red: 178 / 255, green: 98 / 255, blue: 6 / 255, alpha: 1)
        guard let presenter = topViewController() else { return }
        presenter.present(controller, animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let root = scene?.keyWindow?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
#endif
