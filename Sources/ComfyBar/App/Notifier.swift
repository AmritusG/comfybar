import Foundation
import UserNotifications

/// Job finished / job failed / server went down. Each is switched in Settings;
/// the Monitor checks the switch before calling post().
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let log: EventLog
    private let center = UNUserNotificationCenter.current()
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    init(log: EventLog) {
        self.log = log
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            self?.log.add(.info, "notifications authorization: granted=\(granted)\(error.map { " error=\($0.localizedDescription)" } ?? "")")
            self?.refreshStatus()
        }
    }

    func refreshStatus(_ done: ((UNAuthorizationStatus) -> Void)? = nil) {
        center.getNotificationSettings { [weak self] s in
            self?.authorization = s.authorizationStatus
            done?(s.authorizationStatus)
        }
    }

    static func describe(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "allowed"
        case .denied: return "denied in System Settings"
        case .notDetermined: return "not yet allowed"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    func post(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        center.add(req) { [weak self] error in
            if let error {
                self?.log.add(.error, "notification NOT delivered (\(title)): \(error.localizedDescription)")
            } else {
                self?.log.add(.info, "notification posted: \(title) - \(body)")
            }
        }
    }

    // Show banners even though ComfyBar is the active app while its panel is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
