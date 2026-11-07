import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(DVRStore.self) private var dvr
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: AppTab = .live
    @State private var didBoot = false

    var body: some View {
        @Bindable var playback = playback
        ZStack {
            if !settings.onboardingComplete && !tuners.hasDevice {
                OnboardingView()
            } else {
                MainTabs(selection: $tab)
            }

            // The player stays mounted while anything is playing; minimising only hides it.
            if playback.item != nil {
                PlayerOverlay()
                    .opacity(playback.isExpanded ? 1 : 0)
                    .offset(y: playback.isExpanded ? 0 : 60)
                    .allowsHitTesting(playback.isExpanded)
                    .accessibilityHidden(!playback.isExpanded)
                    .zIndex(1)
            }
        }
        .animation(.smooth(duration: 0.32), value: playback.isExpanded)
        .background(Theme.background.ignoresSafeArea())
        .fullScreenCover(isPresented: $playback.isMultiviewPresented) {
            MultiviewScreen()
        }
        .task { await boot() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, didBoot { Task { await refreshOnForeground() } }
            if phase == .background, !settings.backgroundAudio { playback.player.pause() }
        }
        .onChange(of: tuners.hasDevice) { _, has in
            if has { settings.onboardingComplete = true }
        }
        .onChange(of: tuners.deviceAuth) { _, auth in
            Task {
                await guide.load(deviceAuth: auth, hours: settings.guideHours)
                await dvr.refresh(tuners: tuners)
            }
        }
    }

    private func boot() async {
        guard !didBoot else { return }
        didBoot = true
        if tuners.hasDevice {
            await tuners.connect()
            async let g: Void = guide.load(deviceAuth: tuners.deviceAuth, hours: settings.guideHours)
            async let d: Void = dvr.refresh(tuners: tuners)
            _ = await (g, d)
            if settings.autoplayLastChannel, let last = settings.lastChannel, let ch = tuners.channel(last) {
                playback.play(ch, expand: false)
            }
        }
    }

    private func refreshOnForeground() async {
        guard tuners.hasDevice else { return }
        if tuners.connection != .connecting { await tuners.connect() }
        await guide.load(deviceAuth: tuners.deviceAuth, hours: settings.guideHours)
        await dvr.refresh(tuners: tuners)
    }
}

/// System tab view: a tab bar on iPhone, vertical bars on iPhone Duo's outer display,
/// and an adaptable sidebar on the Duo's inner display and iPad.
struct MainTabs: View {
    @Binding var selection: AppTab

    var body: some View {
        TabView(selection: $selection) {
            Tab("Live TV", systemImage: AppTab.live.symbol, value: AppTab.live) {
                NavigationStack { LiveTVView() }
            }
            Tab("Guide", systemImage: AppTab.guide.symbol, value: AppTab.guide) {
                NavigationStack { GuideView() }
            }
            Tab("Recordings", systemImage: AppTab.dvr.symbol, value: AppTab.dvr) {
                NavigationStack { DVRView() }
            }
            Tab("Settings", systemImage: AppTab.settings.symbol, value: AppTab.settings) {
                NavigationStack { SettingsView() }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack { SearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .modifier(MiniPlayerAccessory())
    }
}

/// Puts the mini player in the system's bottom-accessory slot (above the tab bar) where available.
struct MiniPlayerAccessory: ViewModifier {
    @Environment(PlaybackCoordinator.self) private var playback

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: playback.item != nil) {
                MiniPlayer()
            }
        } else {
            content.overlay(alignment: .bottom) {
                if playback.item != nil {
                    MiniPlayer()
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 10)
                        .padding(.bottom, 58)
                }
            }
        }
    }
}
