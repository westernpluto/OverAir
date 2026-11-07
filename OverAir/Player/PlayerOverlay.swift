import SwiftUI

enum PlayerSheet: String, Identifiable {
    case keypad, info, cast
    var id: String { rawValue }
}

/// The full-screen player. It stays mounted while anything plays (minimising just hides it).
///
/// On iPhone Duo it uses an overlay ArrangementView: on a flat display the controls float over
/// the video; when the device is partially folded, video sits on one half and the controls on
/// the other, always visible.
struct PlayerOverlay: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(TunerStore.self) private var tuners
    @Environment(AppSettings.self) private var settings
    @Environment(GuideStore.self) private var guide

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showChannels = false
    @State private var sheet: PlayerSheet?
    @State private var toast: String?
    @State private var dragOffset: CGFloat = 0

    private var player: PlayerController { playback.player }

    var body: some View {
        GeometryReader { proxy in
            let separated = Fold.division(in: proxy) != nil
            FoldAwareOverlay {
                PlayerControls(
                    visible: separated || controlsVisible,
                    separated: separated,
                    showChannels: $showChannels,
                    sheet: $sheet,
                    flash: flash,
                    poke: scheduleHide
                )
            } secondary: {
                videoArea(separated: separated)
            }
            .environment(\.playerControlsSeparated, separated)
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .top) { toastView }
        .overlay { if !settings.playerTipsSeen && playback.isExpanded { PlayerTips() } }
        .offset(y: max(0, dragOffset))
        .preferredColorScheme(.dark)
        .statusBarHidden(playback.isExpanded && !controlsVisible)
        .persistentSystemOverlays(playback.isExpanded ? .hidden : .automatic)
        .onChange(of: playback.isExpanded) { _, expanded in
            if expanded { showControls() }
        }
        .onChange(of: playback.currentChannel) { _, _ in scheduleHide() }
        .onChange(of: player.state) { _, state in
            if state == .playing { scheduleHide() } else if case .failed = state { showControls(autoHide: false) }
        }
        .task(id: playback.isExpanded ? playback.currentChannel?.number : nil) { await pollSignal() }
        .sheet(item: $sheet) { which in
            switch which {
            case .keypad:
                KeypadSheet { number in
                    if !playback.tune(number: number) { flash("Channel \(number) isn't in your lineup") }
                }
                .presentationDetents([.medium])
            case .info:
                if let ch = playback.currentChannel, let program = guide.nowPlaying(ch.number) {
                    NavigationStack { ProgramDetailView(program: program) }
                        .presentationDetents([.medium, .large])
                } else {
                    Text("No program information.").presentationDetents([.fraction(0.25)])
                }
            case .cast:
                CastSheet().presentationDetents([.medium])
            }
        }
    }

    // MARK: Video

    private func videoArea(separated: Bool) -> some View {
        ZStack {
            Color.black
            VideoSurface(player: player)
            PlayerStatusView(controlsVisible: controlsVisible && !separated)
            if let banner = playback.channelBanner, !(controlsVisible || separated) {
                ChannelBanner(channel: banner)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(24)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {
            if controlsVisible { hideControls() } else { showControls() }
        }
        .gesture(swipeGesture)
        .simultaneousGesture(
            MagnifyGesture().onEnded { value in
                playback.setAspect(value.magnification > 1 ? .fill : .fit)
                flash(value.magnification > 1 ? "Fill Screen" : "Fit to Screen")
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video")
        .accessibilityAction(named: "Show Controls") { showControls() }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                if abs(value.translation.height) > abs(value.translation.width), value.translation.height > 0 {
                    dragOffset = value.translation.height * 0.6
                }
            }
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                if abs(dy) > abs(dx) {
                    if dy > 120 { playback.isExpanded = false }
                    else if dy < -60, playback.item?.isLive == true {
                        withAnimation(.snappy) { showChannels = true }
                        showControls(autoHide: false)
                    }
                } else if abs(dx) > 80 {
                    if playback.item?.isLive == true {
                        if dx < 0 { playback.channelUp() } else { playback.channelDown() }
                    } else {
                        let s = dx < 0 ? settings.skipForwardSeconds : -settings.skipBackSeconds
                        player.skip(by: s)
                        flash(s > 0 ? "Forward \(s)s" : "Back \(-s)s")
                    }
                }
            }
    }

    // MARK: Toast

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 56)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    private func flash(_ text: String) {
        withAnimation(.snappy) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeOut) { if toast == text { toast = nil } }
        }
    }

    // MARK: Controls visibility

    private func showControls(autoHide: Bool = true) {
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private func hideControls() {
        hideTask?.cancel()
        withAnimation(.easeIn(duration: 0.2)) {
            controlsVisible = false
            showChannels = false
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            if player.state == .playing && !showChannels && sheet == nil {
                hideControls()
            }
        }
    }

    private func pollSignal() async {
        guard playback.isExpanded, playback.item?.isLive == true, settings.showSignalOverlay else { return }
        while !Task.isCancelled {
            await tuners.refreshStatus()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}

// MARK: - Controls

struct PlayerControls: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(DVRStore.self) private var dvr
    @Environment(LocalRecorder.self) private var recorder
    @Environment(AppSettings.self) private var settings
    @Environment(\.verticalSizeClass) private var vSize

    var visible: Bool
    var separated: Bool
    @Binding var showChannels: Bool
    @Binding var sheet: PlayerSheet?
    var flash: (String) -> Void
    var poke: () -> Void

    @State private var scrub: Double?

    private var player: PlayerController { playback.player }
    private var isLive: Bool { playback.item?.isLive ?? true }

    var body: some View {
        ZStack {
            if separated {
                Color.black
            } else {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.75), location: 0),
                    .init(color: .clear, location: 0.28),
                    .init(color: .clear, location: 0.55),
                    .init(color: .black.opacity(0.85), location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 8)
                if !isFailed { transport }
                Spacer(minLength: 8)
                bottomPanel
                    .frame(maxWidth: 680)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .foregroundStyle(.white)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }

    private var isFailed: Bool {
        if case .failed = player.state { return true }
        return false
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                playback.isExpanded = false
            } label: {
                Label("Minimize", systemImage: "chevron.down")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            NowPlayingTitle()

            Spacer(minLength: 8)

            if settings.showSignalOverlay, let ch = playback.currentChannel, let s = tuners.status(forChannel: ch.number) {
                HStack(spacing: 6) {
                    SignalBars(percent: s.signalStrength)
                    Text("\(s.signalQuality ?? 0)%").font(.caption2.monospacedDigit())
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityLabel("Signal quality \(s.signalQuality ?? 0) percent")
            }

            RoutePicker()
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
                .accessibilityLabel("AirPlay")
        }
    }

    // MARK: Transport

    @ViewBuilder
    private var transport: some View {
        if isLive {
            HStack(spacing: 18) {
                adjacentChannelButton(offset: -1)
                Spacer(minLength: 0)
                playPauseButton
                Spacer(minLength: 0)
                adjacentChannelButton(offset: 1)
            }
            .frame(maxWidth: 520)
        } else {
            HStack(spacing: 40) {
                transportButton("Back \(settings.skipBackSeconds) seconds", symbol: "gobackward.\(settings.skipBackSeconds)") {
                    player.skip(by: -settings.skipBackSeconds); poke()
                }
                playPauseButton
                transportButton("Forward \(settings.skipForwardSeconds) seconds", symbol: "goforward.\(settings.skipForwardSeconds)") {
                    player.skip(by: settings.skipForwardSeconds); poke()
                }
            }
        }
    }

    private var playPauseButton: some View {
        Button {
            player.togglePause()
            poke()
        } label: {
            ZStack {
                if player.state.isLoading {
                    ProgressView().controlSize(.large).tint(.white)
                } else {
                    Image(systemName: player.state == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 32, weight: .bold))
                }
            }
            .frame(width: 76, height: 76)
            .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.state == .paused ? "Play" : "Pause")
    }

    private func transportButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 58, height: 58)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    /// Clearly labelled previous/next channel buttons showing where they'll take you.
    @ViewBuilder
    private func adjacentChannelButton(offset: Int) -> some View {
        if let ch = playback.nextChannel(offset: offset) {
            Button {
                if offset > 0 { playback.channelUp() } else { playback.channelDown() }
                poke()
            } label: {
                HStack(spacing: 8) {
                    if offset < 0 { Image(systemName: "chevron.left").font(.headline) }
                    VStack(alignment: offset < 0 ? .leading : .trailing, spacing: 1) {
                        Text(ch.number).font(.subheadline.weight(.bold).monospacedDigit())
                        Text(ch.name).font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    }
                    if offset > 0 { Image(systemName: "chevron.right").font(.headline) }
                }
                .padding(.horizontal, 12)
                .frame(minWidth: 96, minHeight: 52)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(offset > 0 ? "Next" : "Previous") channel, \(ch.number) \(ch.name)")
        } else {
            Color.clear.frame(width: 96, height: 52)
        }
    }

    // MARK: Bottom

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            if isLive {
                LiveProgressInfo()
            } else {
                scrubber
            }
            if showChannels && isLive {
                ChannelStrip { ch in
                    playback.play(ch)
                    withAnimation(.snappy) { showChannels = false }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            actionBar
        }
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { scrub ?? player.currentTime }, set: { scrub = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                if !editing, let s = scrub { player.seek(to: s); scrub = nil }
                poke()
            }
            .tint(.white)
            HStack {
                Text(Fmt.clock(scrub ?? player.currentTime))
                Spacer()
                Text("-" + Fmt.clock(max(0, player.duration - (scrub ?? player.currentTime))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var actionBar: some View {
        HStack(spacing: 4) {
            if isLive {
                ActionButton(title: "Channels", symbol: "list.bullet.rectangle", active: showChannels) {
                    withAnimation(.snappy) { showChannels.toggle() }
                    poke()
                }
            }
            ActionButton(title: "Captions", symbol: player.captionsOn ? "captions.bubble.fill" : "captions.bubble", active: player.captionsOn) {
                player.toggleCaptions()
                flash(player.captionsOn ? "Captions on" : "Captions off")
                poke()
            }
            Menu {
                if player.audioTracks.isEmpty {
                    Text("Only one audio track")
                }
                ForEach(player.audioTracks) { t in
                    Button { player.selectAudio(t) } label: {
                        if t.id == player.selectedAudio { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                    }
                }
                Divider()
                Button { player.isMuted.toggle() } label: {
                    Label(player.isMuted ? "Unmute" : "Mute", systemImage: player.isMuted ? "speaker.wave.2" : "speaker.slash")
                }
            } label: {
                ActionLabel(title: "Audio", symbol: player.isMuted ? "speaker.slash" : "speaker.wave.2", active: player.isMuted)
            }
            if isLive {
                recordMenu
            } else {
                Menu {
                    Picker("Speed", selection: Binding(get: { Double(player.rate) }, set: { player.rate = Float($0) })) {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                            Text(r == 1 ? "Normal" : String(format: "%.2g×", r)).tag(r)
                        }
                    }
                } label: {
                    ActionLabel(title: "Speed", symbol: "gauge.with.dots.needle.67percent", active: player.rate != 1)
                }
            }
            moreMenu
        }
        .menuOrder(.fixed)
    }

    private var recordMenu: some View {
        let ch = playback.currentChannel
        let program = ch.flatMap { guide.nowPlaying($0.number) }
        let recordingHere = ch.map { recorder.isRecording(channel: $0.number) } ?? false
        return Menu {
            if let program, program.seriesID != nil, !tuners.storageDevices.isEmpty {
                Section("Save to HDHomeRun storage") {
                    Button { recordDVR(program, mode: .once) } label: { Label("Record “\(program.title)”", systemImage: "record.circle") }
                    Button { recordDVR(program, mode: .series) } label: { Label("Record Every Episode", systemImage: "square.stack.3d.down.right") }
                }
            }
            Section("Save to this iPhone") {
                if recordingHere, let ch {
                    Button(role: .destructive) {
                        for a in recorder.active.values where a.recording.channelNumber == ch.number { recorder.stop(a.id) }
                        flash("Recording saved to iPhone")
                    } label: { Label("Stop Recording", systemImage: "stop.circle") }
                } else if let ch {
                    if let program {
                        Button { recordLocal(ch, until: program.end.addingTimeInterval(TimeInterval(settings.endPaddingSeconds))) } label: {
                            Label("Until “\(program.title)” Ends", systemImage: "iphone.and.arrow.forward")
                        }
                    }
                    Button { recordLocal(ch, until: nil) } label: { Label("Until I Stop It", systemImage: "iphone") }
                }
            }
        } label: {
            ActionLabel(title: recordingHere ? "Recording" : "Record", symbol: recordingHere ? "record.circle.fill" : "record.circle",
                        active: recordingHere, activeColor: Theme.record)
        }
    }

    private var moreMenu: some View {
        Menu {
            Section("Picture") {
                Picker("Picture Size", selection: Binding(get: { player.aspect }, set: { playback.setAspect($0) })) {
                    ForEach(AspectMode.allCases) { m in Label(m.title, systemImage: m.symbol).tag(m) }
                }
            }
            if let ch = playback.currentChannel {
                Section("Channel") {
                    Button { settings.toggleFavorite(ch.number); flash(settings.isFavorite(ch.number) ? "Added to Favorites" : "Removed from Favorites") } label: {
                        Label(settings.isFavorite(ch.number) ? "Remove from Favorites" : "Add to Favorites",
                              systemImage: settings.isFavorite(ch.number) ? "star.slash" : "star")
                    }
                    if playback.hasPreviousChannel {
                        Button { playback.lastChannel() } label: { Label("Back to Previous Channel", systemImage: "arrow.uturn.backward") }
                    }
                    Button { sheet = .keypad } label: { Label("Enter Channel Number", systemImage: "number") }
                    Button { sheet = .info } label: { Label("About This Program", systemImage: "info.circle") }
                    Button { playback.openMultiview(with: Array(tuners.favoriteChannels.prefix(3))) } label: {
                        Label("Multiview (Watch Several)", systemImage: "rectangle.split.2x2")
                    }
                }
            }
            Section {
                Menu {
                    ForEach([15, 30, 60, 90, 120], id: \.self) { m in
                        Button("\(m) minutes") { playback.setSleepTimer(minutes: m); flash("Sleep timer: \(m) min") }
                    }
                    if let ch = playback.currentChannel, let now = guide.nowPlaying(ch.number) {
                        Button("When This Show Ends") {
                            playback.setSleepTimer(minutes: max(1, Int(now.end.timeIntervalSinceNow / 60) + 1))
                            flash("Stops at \(Fmt.time.string(from: now.end))")
                        }
                    }
                    if playback.sleepTimerEnd != nil {
                        Button("Turn Off Sleep Timer", role: .destructive) { playback.cancelSleepTimer() }
                    }
                } label: {
                    Label(playback.sleepTimerEnd.map { "Sleep Timer (\(Fmt.time.string(from: $0)))" } ?? "Sleep Timer", systemImage: "moon.zzz")
                }
                Button { sheet = .cast } label: { Label("Cast to Chromecast", systemImage: "tv.and.mediabox") }
            }
        } label: {
            ActionLabel(title: "More", symbol: "ellipsis.circle", active: false)
        }
    }

    // MARK: Actions

    private func recordDVR(_ program: GuideProgram, mode: DVRStore.RecordMode) {
        Task {
            do {
                try await dvr.record(program, mode: mode, settings: settings, tuners: tuners)
                Haptics.success()
                flash(mode == .series ? "Recording every episode" : "Recording on your HDHomeRun")
            } catch {
                Haptics.error()
                flash(error.localizedDescription)
            }
        }
    }

    private func recordLocal(_ channel: Channel, until: Date?) {
        guard let url = tuners.streamURL(for: channel) else { return }
        recorder.start(url: url, channel: channel, program: guide.nowPlaying(channel.number), until: until)
        Haptics.success()
        flash("Recording to iPhone")
    }
}

/// Icon + title, so every control says what it does.
struct ActionLabel: View {
    var title: String
    var symbol: String
    var active: Bool
    var activeColor: Color = .accentColor

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(active ? activeColor : .white)
                .frame(height: 22)
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct ActionButton: View {
    var title: String
    var symbol: String
    var active: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) { ActionLabel(title: title, symbol: symbol, active: active) }
            .buttonStyle(.plain)
            .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct NowPlayingTitle: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(GuideStore.self) private var guide
    @Environment(TunerStore.self) private var tuners
    @Environment(LocalRecorder.self) private var recorder

    var body: some View {
        HStack(spacing: 10) {
            if let ch = playback.currentChannel {
                ChannelLogo(url: guide.logo(ch.number), number: ch.number, name: ch.name, size: 38)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if playback.item?.isLive == true { LiveBadge() }
                    if let ch = playback.currentChannel, recorder.isRecording(channel: ch.number) {
                        Pill(text: "REC", color: Theme.record, symbol: "record.circle")
                    }
                    if tuners.connection == .remote { Pill(text: "AWAY", color: .cyan.opacity(0.6), symbol: "globe") }
                }
                Text(title).font(.headline).lineLimit(1)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
            }
        }
    }

    private var title: String {
        switch playback.item {
        case let .live(ch)?: return guide.nowPlaying(ch.number)?.title ?? ch.name
        case let .recording(ep)?: return ep.title
        case let .local(rec)?: return rec.title
        case nil: return ""
        }
    }

    private var subtitle: String? {
        switch playback.item {
        case let .live(ch)?: return "\(ch.number) \(ch.name)"
        case let .recording(ep)?: return ep.subtitleLine ?? ep.channelName
        case let .local(rec)?: return rec.subtitle ?? "\(rec.channelNumber) \(rec.channelName)"
        case nil: return nil
        }
    }
}

struct LiveProgressInfo: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(GuideStore.self) private var guide

    var body: some View {
        NowTicker(interval: 15) { now in
            if let ch = playback.currentChannel, let p = guide.nowPlaying(ch.number, at: now) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(Fmt.range(p.start, p.end)).font(.caption.monospacedDigit())
                        Spacer()
                        Text(Fmt.remaining(until: p.end)).font(.caption)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    ProgressLine(value: p.progress(at: now), tint: Theme.live, height: 4)
                    if let next = guide.upNext(ch.number, at: now) {
                        Text("Next at \(Fmt.time.string(from: next.start)): \(next.title)")
                            .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// Loading / error states over the video.
struct PlayerStatusView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    var controlsVisible: Bool

    var body: some View {
        switch playback.player.state {
        case .opening, .buffering:
            if !controlsVisible {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.white)
                    if let ch = playback.currentChannel {
                        Text("Tuning \(ch.number) \(ch.name)…").font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .allowsHitTesting(false)
            }
        case let .failed(message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                Text(message).multilineTextAlignment(.center).font(.callout).foregroundStyle(.white)
                if let ch = playback.currentChannel, ch.isATSC3 {
                    Text("This is an ATSC 3.0 channel. Some stations use DRM or AC-4 audio that third-party apps can't decode.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                }
                HStack(spacing: 12) {
                    Button { playback.retry() } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderedProminent)
                    if playback.item?.isLive == true {
                        Button { playback.channelUp() } label: { Label("Next Channel", systemImage: "chevron.right") }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 440)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding()
        case .ended where playback.item?.isLive == false:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                Text("Finished").font(.headline)
                Button("Close Player") { playback.stop() }.buttonStyle(.borderedProminent)
            }
        default:
            EmptyView()
        }
    }
}

struct ChannelBanner: View {
    @Environment(GuideStore.self) private var guide
    var channel: Channel

    var body: some View {
        HStack(spacing: 10) {
            ChannelLogo(url: guide.logo(channel.number), number: channel.number, name: channel.name, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(channel.number)  \(channel.name)").font(.headline)
                if let p = guide.nowPlaying(channel.number) {
                    Text(p.title).font(.subheadline).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .foregroundStyle(.white)
    }
}

/// One-time explanation of the player's gestures.
struct PlayerTips: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("Watching Live TV").font(.title3.weight(.bold))
                tip("hand.tap", "Tap the picture to show or hide the controls.")
                tip("hand.draw", "Swipe left or right on the picture to change channels.")
                tip("chevron.down", "Swipe down, or tap the arrow, to keep watching while you browse.")
                tip("list.bullet.rectangle", "Tap Channels to see what's on everywhere else.")
                Button {
                    withAnimation { settings.playerTipsSeen = true }
                } label: {
                    Text("Got It").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding()
        }
        .foregroundStyle(.primary)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).frame(width: 28).foregroundStyle(Color.accentColor)
            Text(text).font(.subheadline)
        }
    }
}

/// Horizontal strip of channels with what's on now.
struct ChannelStrip: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(PlaybackCoordinator.self) private var playback
    var onSelect: (Channel) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(tuners.visibleChannels) { ch in
                        Button { onSelect(ch) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    ChannelLogo(url: guide.logo(ch.number), number: ch.number, name: ch.name, size: 28)
                                    Text(ch.number).font(.caption.weight(.bold).monospacedDigit())
                                    Spacer(minLength: 0)
                                }
                                Text(guide.nowPlaying(ch.number)?.title ?? ch.name)
                                    .font(.caption.weight(.semibold)).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if let p = guide.nowPlaying(ch.number) { ProgressLine(value: p.progress(), tint: Theme.live, height: 2) }
                            }
                            .padding(10)
                            .frame(width: 148, height: 96)
                            .background(playback.currentChannel == ch ? AnyShapeStyle(Color.accentColor.opacity(0.4)) : AnyShapeStyle(.ultraThinMaterial),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .id(ch.number)
                    }
                }
            }
            .frame(height: 96)
            .onAppear { if let c = playback.currentChannel { proxy.scrollTo(c.number, anchor: .center) } }
        }
        .foregroundStyle(.white)
    }
}

struct KeypadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""
    var onSubmit: (String) -> Void

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "⌫"]

    var body: some View {
        VStack(spacing: 18) {
            Text(entry.isEmpty ? "Channel Number" : entry)
                .font(.system(size: entry.isEmpty ? 24 : 40, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(entry.isEmpty ? .secondary : .primary)
                .frame(height: 50)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(keys, id: \.self) { k in
                    Button {
                        Haptics.tap()
                        if k == "⌫" { if !entry.isEmpty { entry.removeLast() } } else if entry.count < 7 { entry.append(k) }
                    } label: {
                        Text(k).font(.title.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(k == "⌫" ? "Delete" : k)
                }
            }
            Button {
                onSubmit(entry)
                dismiss()
            } label: {
                Text("Watch Channel").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(entry.isEmpty)
        }
        .padding(24)
    }
}

struct CastSheet: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if playback.player.castTargets.isEmpty {
                        HStack(spacing: 12) { ProgressView(); Text("Looking for Chromecast devices…").foregroundStyle(.secondary) }
                    }
                    ForEach(playback.player.castTargets) { t in
                        Button {
                            playback.player.cast(to: t)
                            dismiss()
                        } label: {
                            Label(t.name, systemImage: playback.player.activeCast == t ? "checkmark.circle.fill" : "tv")
                        }
                    }
                } footer: {
                    Text("Sends this channel to a Chromecast or Google TV on your Wi-Fi. For Apple TV, use the AirPlay button for sound.")
                }
                if playback.player.activeCast != nil {
                    Button("Stop Casting", role: .destructive) { playback.player.cast(to: nil); dismiss() }
                }
            }
            .navigationTitle("Cast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { playback.player.startCastDiscovery() }
    }
}
