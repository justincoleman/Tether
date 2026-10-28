import TetherProtocol
import UIKit
import UserNotifications

/// Notification setup and handling. Allow, Deny and Reply run without
/// opening the app: iOS launches it in the background, it connects to the
/// Mac over Tailscale, sends the answer and disconnects.
@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    let store = PhoneStore()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.categories)
        LiveActivities.observeTokens(store: store)
        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        store.setDeviceToken(LiveActivities.hex(deviceToken))
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Push registration failed: \(error)")
    }

    // MARK: UNUserNotificationCenterDelegate

    /// No banner for the tab you're already looking at.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let pane = (notification.request.content.userInfo[PushKeys.paneId] as? String).flatMap(UUID.init(uuidString:))
        if let pane, pane == store.visiblePaneId {
            completionHandler([])
        } else {
            completionHandler([.banner, .list, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let macId = (info[PushKeys.macId] as? String).flatMap(UUID.init(uuidString:))
        let paneId = (info[PushKeys.paneId] as? String).flatMap(UUID.init(uuidString:))
        let requestId = (info[PushKeys.requestId] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let store = self.store
        Task {
            if let macId {
                switch action {
                case PushKeys.allowAction, PushKeys.denyAction:
                    if let requestId {
                        let allow = action == PushKeys.allowAction
                        await store.perform(on: macId) { $0.decide(requestId, allow: allow) }
                    }
                case PushKeys.replyAction:
                    if let paneId, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await store.perform(on: macId) { $0.send(text, to: paneId) }
                    }
                case UNNotificationDefaultActionIdentifier:
                    if let paneId { store.openRoute = SessionRoute(macId: macId, paneId: paneId) }
                default:
                    break
                }
            }
            completionHandler()
        }
    }

    static var categories: Set<UNNotificationCategory> {
        // Allowing a command needs the phone unlocked; denying doesn't.
        let allow = UNNotificationAction(identifier: PushKeys.allowAction, title: "Allow",
                                         options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: PushKeys.denyAction, title: "Deny", options: [.destructive])
        let reply = UNTextInputNotificationAction(identifier: PushKeys.replyAction, title: "Reply",
                                                  options: [.authenticationRequired],
                                                  textInputButtonTitle: "Send",
                                                  textInputPlaceholder: "Message Claude")
        return [
            UNNotificationCategory(identifier: PushKeys.permissionCategory, actions: [allow, deny],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: PushKeys.replyCategory, actions: [reply], intentIdentifiers: []),
        ]
    }
}
