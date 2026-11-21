import Foundation
import UserNotifications

/// Optional macOS banners for new notifications. Clicking one opens it in the browser.
@MainActor
enum SystemNotifier {
    /// UNUserNotificationCenter only works inside an app bundle (not under `swift run`).
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    private static let delegate = Delegate()
    static var onOpen: ((Int) -> Void)?

    static func setUp(onOpen: @escaping (Int) -> Void) {
        guard available else { return }
        self.onOpen = onOpen
        UNUserNotificationCenter.current().delegate = delegate
    }

    static func requestAuthorization() async -> Bool {
        guard available else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func post(_ threads: [NotificationThread]) {
        guard available, !threads.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        if threads.count > 5 {
            let content = UNMutableNotificationContent()
            content.title = "\(threads.count) new Forgejo notifications"
            content.body = threads.prefix(3).map(\.subject.title).joined(separator: "\n")
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return
        }
        for thread in threads {
            let content = UNMutableNotificationContent()
            content.title = [thread.repository.fullName, thread.number].compactMap { $0 }.joined(separator: " ")
            content.body = thread.subject.title
            content.userInfo = ["thread": thread.id]
            content.threadIdentifier = thread.repository.fullName
            center.add(UNNotificationRequest(identifier: "thread-\(thread.id)-\(thread.updatedAt.timeIntervalSince1970)",
                                             content: content, trigger: nil))
        }
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            let id = response.notification.request.content.userInfo["thread"] as? Int
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let id { SystemNotifier.onOpen?(id) }
                }
            }
            completionHandler()
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .list])
        }
    }
}
