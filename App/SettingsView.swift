import SwiftUI

/// Settings.
///
/// Appearance first shipped as a Picker in the toolbar's secondaryAction,
/// which on iPhone collapses into the "•••" overflow beside "How it works" —
/// a submenu, two taps deep, next to a help entry. The person who asked for
/// dark mode could not find it, which is all the evidence that placement
/// needed.
///
/// Deliberately small. Cost basis stays in the Realized gains card, beside the
/// numbers it changes — a preference belongs next to its effect when it has an
/// obvious home, and only comes here when it has none. Appearance has none.
///
/// The links are duplicated from HelpView rather than moved: guideline
/// 5.1.1(i) wants the privacy policy reachable from inside the app, and
/// "inside a long explainer, below the fold" is a weak reading of reachable.
struct SettingsView: View {
    @AppStorage("appearance") private var appearance: Appearance = .system
    @Environment(\.dismiss) private var dismiss

    /// Wipes every holding and transaction. Lives here rather than in the "+"
    /// menu, where a destructive action sat under the heading "Add what you
    /// own".
    var onClearAll: (() -> Void)?
    var hasData: Bool = false

    @State private var confirmingClear = false

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Theme", selection: $appearance) {
                        ForEach(Appearance.allCases) { a in
                            Label(a.label, systemImage: a.icon).tag(a)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("System follows your device setting.")
                }

                Section {
                    Link(destination: URL(string: "https://paulieb14.github.io/crypto-ledger-ios/privacy.html")!) {
                        Label("Privacy policy", systemImage: "hand.raised")
                    }
                    Link(destination: URL(string: "https://paulieb14.github.io/crypto-ledger-ios/")!) {
                        Label("Support", systemImage: "lifepreserver")
                    }
                    Link(destination: URL(string: "mailto:barba334@gmail.com")!) {
                        Label("Contact the developer", systemImage: "envelope")
                    }
                    LabeledContent("Version", value: version)
                } header: {
                    Text("About")
                } footer: {
                    Text("Your holdings stay on your device. No account, no sign-in.")
                }

                if hasData, onClearAll != nil {
                    Section {
                        Button(role: .destructive) { confirmingClear = true } label: {
                            Label("Clear all data", systemImage: "trash")
                        }
                    } footer: {
                        Text("Removes every holding and transaction from this device. This cannot be undone.")
                    }
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // A confirmation step the "+" menu never had: Clear all was one tap
            // from a menu people open to add things.
            .confirmationDialog("Clear all data?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear everything", role: .destructive) {
                    onClearAll?()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every holding and transaction on this device will be removed. This cannot be undone.")
            }
        }
    }
}
