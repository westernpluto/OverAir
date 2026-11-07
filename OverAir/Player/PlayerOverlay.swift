import SwiftUI

enum PlayerSheet: String, Identifiable {
    case keypad, info, streamInfo
    var id: String { rawValue }
}

/// The full-screen player. It stays mounted while anything plays (minimising just hides it).
/// On iPhone Duo an overlay ArrangementView puts the controls beside the picture when partially folded.
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

    private var player: TVPlayer { playback.player }

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
        .persistentSystemOverlays(playback.isExpanded && !controlsVisible ? .hidden : .automatic)
        .onChange(of: playback.isExpanded) { _, expanded in if expanded { showControls() } }
        .onChange(of: playback.currentChannel) { _, _ in scheduleHide() }
        .onChange(of: player.state) { _, state in
            if state == .playing { scheduleHide() }
            if case .failed = state { showControls(autoHide: false) }
            if state == .paused { showControls(autoHide: false) }
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
            case .streamInfo:
                StreamInfoSheet().presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: Video

    private func videoArea(separated: Bool) -> some View {
        ZStack {
            Color.black
            TVVideoView(player: player)
            CaptionOverlay(rows: player.captionRows, raised: controlsVisible && !separated)
            PlayerStatusView(controlsVisible: controlsVisible && !separated)
            if let banner = playback.channelBanner, !(controlsVisible || separated) {
                ChannelBanner(channel: banner)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(20)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            playback.setAspect(player.aspect == .fit ? .fill : .fit)
            flash(player.aspect == .fill ? "Fill Screen" : "Fit to Screen")
        }
        .onTapGesture { if controlsVisible { hideControls() } else { showControls() } }
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
                        player.skip(by: Double(s))
                        flash(s > 0 ? "Forward \(s) s" : "Back \(-s) s")
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
                .glass(in: Capsule(), interactive: false)
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
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            if player.state == .playing && !showChannels && sheet == nil { hideControls() }
        }
    }

    private func pollSignal() async {
        guard playback.isExpanded, playback.item?.isLive == true else { return }
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
    @ScaledMetric(relativeTo: .title) private var playSize: CGFloat = 68
    @ScaledMetric(relativeTo: .title) private var skipSize: CGFloat = 50

    var visible: Bool
    var separated: Bool
    @Binding var showChannels: Bool
    @Binding var sheet: PlayerSheet?
    var flash: (String) -> Void
    var poke: () -> Void

    private var player: TVPlayer { playback.player }
    private var isLive: Bool { playback.item?.isLive ?? true }
    private var compactHeight: Bool { vSize == .compact }

    var body: some View {
        ZStack {
            if separated {
                Color.black
            } else {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.7), location: 0),
                    .init(color: .clear, location: 0.25),
                    .init(color: .clear, location: 0.5),
                    .init(color: .black.opacity(0.85), location: 1),
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
                    .frame(maxWidth: 760)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, compactHeight ? 6 : 12)
        }
        .foregroundStyle(.white)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }

    private var isFailed: Bool {
        if case .failed = player.state { return true }
        return false
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: 10) {
            GlassIconButton(title: "Minimize", symbol: "chevron.down") { playback.isExpanded = false }
            Spacer()
            if let ch = playback.currentChannel, settings.showSignalOverlay, let s = tuners.status(forChannel: ch.number) {
                HStack(spacing: 6) {
                    SignalBars(percent: s.signalStrength)
                    Text("\(s.signalQuality ?? 0)%").font(.caption2.monospacedDigit())
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .glass(in: Capsule(), interactive: false)
            }
            if player.isPictureInPicturePossible {
                GlassIconButton(title: "Picture in Picture", symbol: player.isPictureInPictureActive ? "pip.exit" : "pip.enter") {
                    player.togglePictureInPicture()
                }
            }
            RoutePicker()
                .frame(width: 44, height: 44)
                .glass(in: Circle())
                .accessibilityLabel("AirPlay")
        }
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: compactHeight ? 36 : 44) {
            skipButton(seconds: -Double(isLive ? 10 : settings.skipBackSeconds))
            Button {
                player.togglePause()
                poke()
            } label: {
                ZStack {
                    if player.state.isLoading {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: player.state == .paused ? "play.fill" : "pause.fill")
                            .font(.system(size: playSize * 0.42, weight: .bold))
                    }
                }
                .frame(width: playSize, height: playSize)
                .glass(in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.state == .paused ? "Play" : "Pause")
            skipButton(seconds: Double(isLive ? 10 : settings.skipForwardSeconds))
                .disabled(isLive && player.isAtLiveEdge)
                .opacity(isLive && player.isAtLiveEdge ? 0.35 : 1)
        }
    }

    private func skipButton(seconds: Double) -> some View {
        let s = Int(abs(seconds))
        let symbol = seconds < 0 ? "gobackward.\(s)" : "goforward.\(s)"
        return Button {
            player.skip(by: seconds)
            poke()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: skipSize * 0.44, weight: .semibold))
                .frame(width: skipSize, height: skipSize)
                .glass(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(seconds < 0 ? "Back \(s) seconds" : "Forward \(s) seconds")
    }

    // MARK: Bottom

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: compactHeight ? 8 : 12) {
            NowPlayingTitle()
            if isLive { LiveTimeline(poke: poke) } else { RecordingScrubber(poke: poke) }
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

    private var actionBar: some View {
        HStack(spacing: 8) {
            if isLive {
                ActionButton(title: "Channels", symbol: "list.bullet", active: showChannels) {
                    withAnimation(.snappy) { showChannels.toggle() }
                    poke()
                }
            }
            ActionButton(title: "Captions", symbol: player.captionsEnabled ? "captions.bubble.fill" : "captions.bubble",
                         active: player.captionsEnabled) {
                player.toggleCaptions()
                flash(player.captionsEnabled ? (player.hasCaptions ? "Captions on" : "Captions on — none on this channel yet") : "Captions off")
                poke()
            }
            if isLive { recordMenu }
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
                Section("Save to HDHomeRun") {
                    Button { recordDVR(program, mode: .once) } label: { Label("This Episode", systemImage: "record.circle") }
                    Button { recordDVR(program, mode: .series) } label: { Label("Every Episode", systemImage: "square.stack.3d.down.right") }
                }
            }
            Section("Save to This iPhone") {
                if recordingHere, let ch {
                    Button(role: .destructive) {
                        for a in recorder.active.values where a.recording.channelNumber == ch.number { recorder.stop(a.id) }
                        flash("Saved to iPhone")
                    } label: { Label("Stop Recording", systemImage: "stop.circle") }
                } else if let ch {
                    if let program {
                        Button { recordLocal(ch, until: program.end.addingTimeInterval(TimeInterval(settings.endPaddingSeconds))) } label: {
                            Label("Until the Show Ends", systemImage: "iphone.and.arrow.forward")
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
            Section {
                Picker("Picture", selection: Binding(get: { player.aspect }, set: { playback.setAspect($0) })) {
                    Label("Fit", systemImage: "rectangle.arrowtriangle.2.inward").tag(AspectMode.fit)
                    Label("Fill", systemImage: "rectangle.arrowtriangle.2.outward").tag(AspectMode.fill)
                }
                if player.audioTracks.count > 1 || player.audioTracks.contains(where: { !$0.supported }) {
                    Picker("Audio", selection: Binding(get: { player.selectedAudio ?? -1 }, set: { pid in
                        if let t = player.audioTracks.first(where: { $0.id == pid }) { player.selectAudio(t) }
                    })) {
                        ForEach(player.audioTracks) { t in
                            Text(t.supported ? t.title : "\(t.title) — not supported").tag(t.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Button { player.isMuted.toggle() } label: {
                    Label(player.isMuted ? "Unmute" : "Mute", systemImage: player.isMuted ? "speaker.wave.2" : "speaker.slash")
                }
                if !isLive {
                    Picker("Speed", selection: Binding(get: { Double(player.rate) }, set: { player.rate = Float($0) })) {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                            Text(r == 1 ? "Normal Speed" : String(format: "%.2g×", r)).tag(r)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            if let ch = playback.currentChannel {
                Section {
                    Button { settings.toggleFavorite(ch.number); flash(settings.isFavorite(ch.number) ? "Added to Favorites" : "Removed from Favorites") } label: {
                        Label(settings.isFavorite(ch.number) ? "Remove from Favorites" : "Add to Favorites",
                              systemImage: settings.isFavorite(ch.number) ? "star.slash" : "star")
                    }
                    if playback.hasPreviousChannel {
                        Button { playback.lastChannel() } label: { Label("Previous Channel", systemImage: "arrow.uturn.backward") }
                    }
                    Button { sheet = .keypad } label: { Label("Enter Channel Number", systemImage: "number") }
                    Button { playback.openMultiview(with: Array(tuners.favoriteChannels.prefix(3))) } label: {
                        Label("Multiview", systemImage: "rectangle.split.2x2")
                    }
                    Button { sheet = .info } label: { Label("About This Show", systemImage: "info.circle") }
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
                        Button("Turn Off", role: .destructive) { playback.cancelSleepTimer() }
                    }
                } label: {
                    Label(playback.sleepTimerEnd.map { "Sleep Timer · \(Fmt.time.string(from: $0))" } ?? "Sleep Timer", systemImage: "moon.zzz")
                }
                Button { sheet = .streamInfo } label: { Label("Stream & Signal Info", systemImage: "waveform.path.ecg") }
            }
        } label: {
            ActionLabel(title: "More", symbol: "ellipsis", active: false)
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

// MARK: - Pieces

struct GlassIconButton: View {
    var title: String
    var symbol: String
    var action: () -> Void
    @ScaledMetric private var size: CGFloat = 44

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
                .glass(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Icon above a short title, so every control says what it does.
struct ActionLabel: View {
    var title: String
    var symbol: String
    var active: Bool
    var activeColor: Color = .accentColor

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(active ? activeColor : .white)
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .padding(.vertical, 2)
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    @ScaledMetric private var logoSize: CGFloat = 40

    var body: some View {
        HStack(spacing: 12) {
            if let ch = playback.currentChannel {
                ChannelLogo(url: guide.logo(ch.number), number: ch.number, name: ch.name, size: logoSize)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    if let subtitle { Text(subtitle).lineLimit(1) }
                    if let ch = playback.currentChannel, recorder.isRecording(channel: ch.number) {
                        Pill(text: "REC", color: Theme.record)
                    }
                    if tuners.connection == .remote { Pill(text: "AWAY", color: .cyan.opacity(0.5)) }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
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

/// Live timeline: the rewindable buffer, where you are in it, and a LIVE button.
struct LiveTimeline: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(GuideStore.self) private var guide
    var poke: () -> Void
    @State private var dragFraction: Double?

    private var player: TVPlayer { playback.player }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    let available = max(player.timeshiftAvailable, 1)
                    let fraction = dragFraction ?? (player.isAtLiveEdge ? 1 : min(max(player.position / available, 0), 1))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(Color.white.opacity(0.85)).frame(width: max(4, geo.size.width * fraction))
                    }
                    .frame(height: 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in dragFraction = min(max(v.location.x / geo.size.width, 0), 1); poke() }
                        .onEnded { _ in
                            if let f = dragFraction { player.seek(to: f * available) }
                            dragFraction = nil
                        })
                }
                .frame(height: 22)
                HStack {
                    if let ch = playback.currentChannel, let p = guide.nowPlaying(ch.number) {
                        Text(Fmt.range(p.start, p.end))
                    }
                    Spacer()
                    if !player.isAtLiveEdge {
                        Text("−" + Fmt.clock(player.behindLive)).monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
            }
            Button {
                player.goLive()
                poke()
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(player.isAtLiveEdge ? Theme.live : .white.opacity(0.5)).frame(width: 7, height: 7)
                    Text("LIVE").font(.caption.weight(.heavy))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .glass(in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(player.isAtLiveEdge)
            .accessibilityLabel(player.isAtLiveEdge ? "Watching live" : "Jump to live")
        }
    }
}

struct RecordingScrubber: View {
    @Environment(PlaybackCoordinator.self) private var playback
    var poke: () -> Void
    @State private var scrub: Double?

    private var player: TVPlayer { playback.player }

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { scrub ?? player.position }, set: { scrub = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                if !editing, let s = scrub { player.seek(to: s); scrub = nil }
                poke()
            }
            .tint(.white)
            HStack {
                Text(Fmt.clock(scrub ?? player.position))
                Spacer()
                Text("−" + Fmt.clock(max(0, player.duration - (scrub ?? player.position))))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// Closed captions drawn over the picture.
struct CaptionOverlay: View {
    var rows: [CEA608Decoder.Row]
    var raised: Bool

    var body: some View {
        VStack(spacing: 2) {
            Spacer()
            ForEach(rows) { row in
                Text(row.text)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .italic(row.italic)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .padding(.bottom, raised ? 190 : 36)
        .animation(.easeOut(duration: 0.2), value: raised)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
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
            .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: false)
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
        .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: false)
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
                tip("hand.tap", "Tap the picture to show or hide controls.")
                tip("hand.draw", "Swipe left or right to change channels.")
                tip("pause.circle", "Pause and rewind live TV — it keeps recording while you're paused.")
                tip("chevron.down", "Swipe down to keep watching while you browse.")
                Button {
                    withAnimation { settings.playerTipsSeen = true }
                } label: {
                    Text("Got It").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding()
        }
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
    @ScaledMetric private var cardWidth: CGFloat = 150
    var onSelect: (Channel) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(tuners.visibleChannels) { ch in
                        Button { onSelect(ch) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    ChannelLogo(url: guide.logo(ch.number), number: ch.number, name: ch.name, size: 26)
                                    Text(ch.number).font(.caption.weight(.bold).monospacedDigit())
                                }
                                Text(guide.nowPlaying(ch.number)?.title ?? ch.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let p = guide.nowPlaying(ch.number) { ProgressLine(value: p.progress(), tint: Theme.live, height: 2) }
                            }
                            .padding(10)
                            .frame(width: cardWidth)
                            .background(playback.currentChannel == ch ? AnyShapeStyle(Color.accentColor.opacity(0.45)) : AnyShapeStyle(Color.white.opacity(0.1)),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .id(ch.number)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { if let c = playback.currentChannel { proxy.scrollTo(c.number, anchor: .center) } }
        }
        .foregroundStyle(.white)
    }
}

struct StreamInfoSheet: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(TunerStore.self) private var tuners
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let info = playback.player.info
        NavigationStack {
            List {
                Section("Video") {
                    LabeledContent("Codec", value: info.videoCodec ?? "—")
                    LabeledContent("Resolution", value: info.width > 0 ? "\(info.width)×\(info.height) (\(info.resolutionLabel))" : "—")
                    if info.frameRate > 0 { LabeledContent("Frame Rate", value: String(format: "%.2f fps", info.frameRate)) }
                    if info.interlaced { LabeledContent("Deinterlacing", value: info.deinterlacing ? "On (60 fps)" : "Off") }
                }
                Section("Audio") {
                    LabeledContent("Codec", value: info.audioCodec ?? "—")
                    LabeledContent("Channels", value: info.channelLabel)
                    if info.sampleRate > 0 { LabeledContent("Sample Rate", value: "\(info.sampleRate / 1000) kHz") }
                }
                Section("Stream") {
                    LabeledContent("Bitrate", value: info.mbps > 0 ? String(format: "%.1f Mbps", info.mbps) : "—")
                    if playback.player.isLive {
                        LabeledContent("Rewind Available", value: Fmt.clock(playback.player.timeshiftAvailable))
                    }
                    LabeledContent("Connection", value: tuners.connection.title)
                }
                if let ch = playback.currentChannel, let s = tuners.status(forChannel: ch.number) {
                    Section("Signal") {
                        SignalMeter(label: "Strength", value: s.signalStrength)
                        SignalMeter(label: "Quality", value: s.signalQuality)
                        SignalMeter(label: "Symbol Quality", value: s.symbolQuality)
                        if let f = s.frequency { LabeledContent("Frequency", value: String(format: "%.1f MHz", Double(f) / 1_000_000)) }
                    }
                }
            }
            .navigationTitle("Stream Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            while !Task.isCancelled {
                await tuners.refreshStatus()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

struct KeypadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""
    var onSubmit: (String) -> Void

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "⌫"]

    var body: some View {
        VStack(spacing: 16) {
            Text(entry.isEmpty ? "Channel Number" : entry)
                .font(entry.isEmpty ? .title2 : .largeTitle)
                .fontWeight(.bold)
                .monospacedDigit()
                .foregroundStyle(entry.isEmpty ? .secondary : .primary)
                .frame(minHeight: 50)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(keys, id: \.self) { k in
                    Button {
                        Haptics.tap()
                        if k == "⌫" { if !entry.isEmpty { entry.removeLast() } } else if entry.count < 7 { entry.append(k) }
                    } label: {
                        Text(k).font(.title.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 52)
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
                Text("Watch").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(entry.isEmpty)
        }
        .padding(24)
    }
}
