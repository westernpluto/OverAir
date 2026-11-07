import SwiftUI
import Combine
import UserNotifications

@main
struct OverAirApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var settings: AppSettings
    @State private var tuners: TunerStore
    @State private var guide: GuideStore
    @State private var dvr: DVRStore
    @State private var recorder: LocalRecorder
    @State private var playback: PlaybackCoordinator

    init() {
        let settings = AppSettings()
        let tuners = TunerStore(settings: settings)
        let guide = GuideStore()
        let dvr = DVRStore()
        let recorder = LocalRecorder()
        _settings = State(initialValue: settings)
        _tuners = State(initialValue: tuners)
        _guide = State(initialValue: guide)
        _dvr = State(initialValue: dvr)
        _recorder = State(initialValue: recorder)
        _playback = State(initialValue: PlaybackCoordinator(settings: settings, tuners: tuners, guide: guide, dvr: dvr, recorder: recorder))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(tuners)
                .environment(guide)
                .environment(dvr)
                .environment(recorder)
                .environment(playback)
                .preferredColorScheme(.dark)
                .tint(Color("AccentColor"))
                .onOpenURL { url in handle(url) }
                .onReceive(NotificationCenter.default.publisher(for: .overAirTuneChannel)) { note in
                    if let number = note.object as? String { _ = playback.tune(number: number) }
                }
        }
    }

    /// overair://channel/5.1  •  overair://guide  •  overair://dvr
    private func handle(_ url: URL) {
        guard url.scheme == "overair" else { return }
        if url.host == "channel", let number = url.pathComponents.dropFirst().first {
            if let ch = tuners.channel(number) { playback.play(ch) }
        }
    }
}

extension Notification.Name {
    static let overAirTuneChannel = Notification.Name("OverAirTuneChannel")
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let channel = response.notification.request.content.userInfo["channel"] as? String {
            await MainActor.run {
                NotificationCenter.default.post(name: .overAirTuneChannel, object: channel)
            }
        }
    }
}
