import SwiftUI

/// A short, friendly explainer the user can open any time from the toolbar.
/// Onboarding lives in the empty state; this is the reference version — the
/// three ways to add, what the numbers mean, and the privacy promise.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    section("Three ways to add — easiest first") {
                        step(1, "Add holding",
                             "The quick way. Choose a coin and type how much you own. "
                             + "It's valued at today's price, so your gains start from now. "
                             + "Perfect if you just want to see your net worth.")
                        step(2, "Add transaction",
                             "Log individual buys, sells, deposits, and coins you received. "
                             + "This is what tracks your cost basis and real gains over time.")
                        step(3, "Import a CSV",
                             "The complete way. Export your history from an exchange and import "
                             + "it all at once. Argus reads the date, coin, amount, and price.")
                    }

                    section("Reading your portfolio") {
                        bullet("Net worth", "Your cash plus the live value of every coin you hold.")
                        bullet("Unrealized", "Paper gain or loss — what you'd make if you sold now.")
                        bullet("Realized gains", "Locked-in profit from coins you've actually sold. "
                               + "Switch cost-basis method (FIFO/LIFO/HIFO) to see how it changes.")
                        bullet("Remove a holding", "Press and hold any coin, then tap Remove.")
                    }

                    section("Your privacy") {
                        Text("Argus keeps everything on your device. There are no accounts, "
                             + "no sign-in, and your holdings are never uploaded. Prices and "
                             + "coin logos come from public market data.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("How Argus works")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 480)
        .tint(.indigo)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 40))
                .foregroundStyle(.indigo)
            Text("Track everything you hold in one place, with live prices and real cost-basis math.")
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func step(_ number: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.indigo.opacity(0.14)).frame(width: 30, height: 30)
                Text("\(number)").font(.subheadline.weight(.bold)).foregroundStyle(.indigo)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bullet(_ term: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Color.indigo).frame(width: 5, height: 5).padding(.top, 6)
            Text("**\(term).** \(body)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if os(iOS)
#Preview {
    HelpView()
}
#endif
