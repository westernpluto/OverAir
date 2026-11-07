import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// "Remind me" local notifications for programs in the guide.
enum Reminders {
    static func identifier(for program: GuideProgram) -> String { "reminder-\(program.id)" }

    static func schedule(_ program: GuideProgram, channelName: String, minutesBefore: Int) async -> Bool {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return false }
        let content = UNMutableNotificationContent()
        content.title = program.title
        content.body = "Starts \(minutesBefore == 0 ? "now" : "in \(minutesBefore) min") on \(program.channelNumber) \(channelName)"
        content.sound = .default
        content.userInfo = ["channel": program.channelNumber]
        let fire = program.start.addingTimeInterval(TimeInterval(-60 * minutesBefore))
        let interval = max(fire.timeIntervalSinceNow, 5)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: identifier(for: program), content: content, trigger: trigger)
        do { try await center.add(request); return true } catch { return false }
        #else
        return false
        #endif
    }

    static func cancel(_ program: GuideProgram) {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier(for: program)])
        #endif
    }

    static func pendingIDs() async -> Set<String> {
        #if canImport(UserNotifications)
        let reqs = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return Set(reqs.map(\.identifier))
        #else
        return []
        #endif
    }
}
