import SwiftUI
import LocalAuthentication

/// Optional Face ID / passcode lock, so a borrowed phone does not show holdings.
///
/// Off by default. When on, the app asks at launch and again after it has been
/// in the background for more than `relockAfter` seconds. While locked — and
/// whenever the app is inactive, which is the moment iOS snapshots it for the
/// app switcher — an opaque cover sits over everything, so balances never
/// appear in the switcher either.
///
/// `.deviceOwnerAuthentication` is Face ID / Touch ID with the device passcode
/// as fallback, so there is no separate Argus password to forget.
enum AppLock {
    static let enabledKey = "appLock.enabled"
    static let relockAfter: TimeInterval = 30

    /// Whether this device can authenticate its owner at all (biometrics or a
    /// passcode). Without a passcode set there is nothing to lock with.
    static func availability() -> (available: Bool, reason: String?) {
        let ctx = LAContext()
        var error: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) { return (true, nil) }
        return (false, "Set a passcode in iOS Settings to use App Lock.")
    }

    /// "Face ID", "Touch ID", "Optic ID" or "Passcode", for labels.
    static var methodName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    static func authenticate() async -> Bool {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            // The passcode was removed after the lock was turned on. Locking the
            // owner out of their own data would be worse than not locking.
            return true
        }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication,
                                              localizedReason: "Unlock Argus to see your holdings")) ?? false
    }
}

/// Wraps the root view: cover + authentication driven by scenePhase.
struct AppLockGate<Content: View>: View {
    @AppStorage(AppLock.enabledKey) private var enabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var locked: Bool
    @State private var authenticating = false
    @State private var backgroundedAt: Date?
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
        _locked = State(initialValue: UserDefaults.standard.bool(forKey: AppLock.enabledKey))
    }

    var body: some View {
        ZStack {
            content
            if enabled && (locked || scenePhase != .active) {
                LockCover(authenticating: authenticating, showButton: locked) { unlock() }
                    .transition(.opacity)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard enabled else { return }
            switch phase {
            case .background:
                if backgroundedAt == nil { backgroundedAt = Date() }
            case .active:
                if let t = backgroundedAt, Date().timeIntervalSince(t) > AppLock.relockAfter { locked = true }
                backgroundedAt = nil
                if locked { unlock() }
            default:
                break
            }
        }
        .onChange(of: enabled) { _, on in
            // Turning it on should not immediately lock you out mid-session;
            // turning it off clears any lock.
            if !on { locked = false }
        }
        .task { if enabled && locked && scenePhase == .active { unlock() } }
    }

    private func unlock() {
        guard !authenticating else { return }
        authenticating = true
        Task { @MainActor in
            let ok = await AppLock.authenticate()
            authenticating = false
            if ok { locked = false }
        }
    }
}

private struct LockCover: View {
    let authenticating: Bool
    let showButton: Bool
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.amber)
                Text("Argus is locked").font(.title3.weight(.semibold))
                if showButton {
                    Button {
                        onUnlock()
                    } label: {
                        Label("Unlock with \(AppLock.methodName)", systemImage: "faceid")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(authenticating)
                }
            }
        }
    }
}

/// The Settings row.
struct AppLockSettingsSection: View {
    @AppStorage(AppLock.enabledKey) private var enabled = false
    @State private var availability = AppLock.availability()

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                Label("App Lock", systemImage: "lock")
            }
            .disabled(!availability.available && !enabled)
        } header: {
            Text("Privacy")
        } footer: {
            if let reason = availability.reason {
                Text(reason)
            } else {
                Text("Require \(AppLock.methodName) (or your passcode) to open Argus, and again after it has been in the background for 30 seconds. Holdings are hidden in the app switcher.")
            }
        }
        .onAppear { availability = AppLock.availability() }
    }
}
