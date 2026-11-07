import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(DVRStore.self) private var dvr
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: AppTab = .live
    @State private var didBoot = false

    var body: some View {
        @Bindable var playback = playback
        Group {
            if !settings.onboardingComplete && !tuners.hasDevice {
                OnboardingView()
            } else if hSize == .regular {
                SplitRoot(selection: $tab)
            } else {
                TabRoot(selection: $tab)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .fullScreenCover(isPresented: $playback.isFullScreen) {
            PlayerScreen()
        }
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
                playback.play(ch, fullScreen: false)
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

/// iPhone layout.
struct TabRoot: View {
    @Binding var selection: AppTab

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack { tab.rootView.withMiniPlayer() }
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
    }
}

/// Large-screen layout (iPad, foldables unfolded, iPhone landscape Max) with a sidebar.
struct SplitRoot: View {
    @Binding var selection: AppTab
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppSettings.self) private var settings

    var body: some View {
        NavigationSplitView {
            List {
                Section {
                    ForEach(AppTab.allCases) { tab in
                        Button { selection = tab } label: {
                            Label(tab.title, systemImage: tab.symbol)
                                .foregroundStyle(selection == tab ? Color.accentColor : .primary)
                        }
                        .listRowBackground(selection == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                    }
                }
                if !tuners.favoriteChannels.isEmpty {
                    Section("Favorites") {
                        ForEach(tuners.favoriteChannels) { ch in
                            Button { playback.play(ch) } label: {
                                HStack {
                                    ChannelLogo(url: guide.logo(ch.number), number: ch.number, name: ch.name, size: 28)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text("\(ch.number) \(ch.name)").font(.subheadline.weight(.medium))
                                        Text(guide.nowPlaying(ch.number)?.title ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
                Section {
                    ConnectionBadge(state: tuners.connection)
                }
            }
            .navigationTitle("OverAir")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            NavigationStack { selection.rootView.withMiniPlayer() }
        }
    }
}

extension AppTab {
    @MainActor @ViewBuilder
    var rootView: some View {
        switch self {
        case .live: LiveTVView()
        case .guide: GuideView()
        case .dvr: DVRView()
        case .settings: SettingsView()
        }
    }
}

extension View {
    func withMiniPlayer() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer() }
    }
}
