import SwiftUI
#if os(iOS)
import BackgroundTasks
import UIKit
import UserNotifications
#endif

@main
struct CryptoLedgerApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            NetWorthView()
        }
    }
}

#if os(iOS)
/// Registers and drives the background price-check task and lets alert
/// notifications appear as banners even while the app is open.
///
/// iOS runs the refresh task opportunistically (typically when the device is
/// idle/charging), so alerts are near-real-time, not to-the-second. The app
/// also re-checks every time it returns to the foreground.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    static let taskIdentifier = "com.paulbarba.cryptoledger.pricecheck"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier, using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false); return
            }
            Self.handle(refresh)
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Self.scheduleNextCheck()
    }

    /// Ask iOS to run our price check again later. Timing is the system's call.
    static func scheduleNextCheck() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        scheduleNextCheck()  // chain the next opportunity before we might expire
        let work = Task {
            await PriceAlertChecker.runOnce()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Show alert notifications as banners even when Argus is in the foreground.
    /// `nonisolated` to match the delegate requirement — `AppDelegate` is
    /// inferred `@MainActor` via `UIApplicationDelegate`, but this callback isn't
    /// and its parameters aren't `Sendable`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
#endif
