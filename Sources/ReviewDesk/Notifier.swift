import Foundation
import ReviewDeskCore
import UserNotifications

/// Posts update notifications; clicking one opens its PR. Needs the app bundle (`make app`):
/// a bare `swift run` binary has no bundle identifier and UserNotifications would crash.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func setUp() {
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ pr: PullRequest, kinds: [UpdateKind]) {
        let content = UNMutableNotificationContent()
        content.title = "\(pr.repo)#\(pr.number)"
        content.subtitle = pr.title
        content.body = kinds.map(\.text).joined(separator: " · ")
        content.userInfo = ["pr": pr.id]
        content.threadIdentifier = pr.id // groups notifications per PR
        center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["pr"] as? String
        Task { @MainActor in if let id { self.onOpen?(id) } }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
