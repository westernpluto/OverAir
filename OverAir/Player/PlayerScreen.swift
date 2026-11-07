import SwiftUI

/// Full-screen player for live TV and recordings.
struct PlayerScreen: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(DVRStore.self) private var dvr
    @Environment(LocalRecorder.self) private var recorder
    @Environment(AppSettings.self) private var settings

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showChannelStrip = false
    @State private var showKeypad = false
    @State private var showInfo = false
    @State private var dragOffset: CGSize = .zero
    @State private var toast: String?
    @State private var scrubbing: Double?
    @State private var showCastSheet = false

    private var player: PlayerController { playback.player }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                VideoSurface(player: player)
                    .ignoresSafeArea()
                    .offset(y: max(0, dragOffset.height))
                    .scaleEffect(1 - min(max(dragOffset.height, 0) / 1600, 0.15))

                gestureLayer

                stateOverlay

                if showControls {
                    controls(safe: geo.safeAreaInsets)
                        .transition(.opacity)
                }

                if showChannelStrip, playback.item?.isLive == true {
                    VStack {
                        Spacer()
                        ChannelStrip { channel in
                            playback.play(channel)
                            withAnimation(.snappy) { showChannelStrip = false }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                if let toast {
                    VStack {
                        Text(toast)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 60)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(.hidden)
        .onAppear { scheduleHide() }
        .task(id: playback.item?.channel?.number) { await pollSignal() }
        .sheet(isPresented: $showKeypad) {
            KeypadSheet { number in
                if !playback.tune(number: number) { flash("Channel \(number) not found") }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showInfo) {
            if let ch = playback.item?.channel, let program = guide.nowPlaying(ch.number) {
                NavigationStack { ProgramDetailView(program: program) }
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showCastSheet) {
            CastSheet().presentationDetents([.medium])
        }
    }

    // MARK: Gestures

    private var gestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                playback.cycleAspect()
                flash(player.aspect.title)
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                if showControls { scheduleHide() }
            }
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { value in
                        if abs(value.translation.height) > abs(value.translation.width) {
                            dragOffset = CGSize(width: 0, height: value.translation.height)
                        }
                    }
                    .onEnded { value in
                        let dx = value.translation.width, dy = value.translation.height
                        if abs(dy) > abs(dx) {
                            if dy > 140 { playback.isFullScreen = false }
                            else if dy < -80, playback.item?.isLive == true { withAnimation(.snappy) { showChannelStrip = true } }
                        } else if playback.item?.isLive == true, abs(dx) > 90 {
                            if dx < 0 { playback.channelUp() } else { playback.channelDown() }
                            flashChannel()
                        } else if playback.item?.isLive == false, abs(dx) > 90 {
                            player.skip(by: dx < 0 ? settings.skipForwardSeconds : -settings.skipBackSeconds)
                        }
                        withAnimation(.spring) { dragOffset = .zero }
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onEnded { value in
                        playback.setAspect(value.magnification > 1 ? .fill : .fit)
                        flash(player.aspect.title)
                    }
            )
    }

    // MARK: State overlay

    @ViewBuilder
    private var stateOverlay: some View {
        switch player.state {
        case .opening, .buffering:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.white)
                if let ch = playback.item?.channel {
                    Text("Tuning \(ch.number) \(ch.name)…").font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                }
            }
            .allowsHitTesting(false)
        case let .failed(message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                Text(message).multilineTextAlignment(.center).font(.callout).foregroundStyle(.white)
                if let ch = playback.item?.channel, ch.isATSC3 {
                    Text("This is an ATSC 3.0 channel. Some broadcasts use DRM or AC-4 audio that third-party players can't decode.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                }
                HStack {
                    Button("Retry") { retry() }.buttonStyle(.borderedProminent)
                    Button("Close") { playback.stop() }.buttonStyle(.bordered)
                }
            }
            .padding(30)
            .frame(maxWidth: 420)
        case .ended:
            if playback.item?.isLive == false {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                    Text("Finished").font(.headline)
                    Button("Close") { playback.stop() }.buttonStyle(.borderedProminent)
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: Controls

    private func controls(safe: EdgeInsets) -> some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.75), .clear, .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerControls
                Spacer()
                bottomBar
            }
            .padding(.horizontal, max(16, safe.leading))
            .padding(.bottom, 8)
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            CircleButton(symbol: "chevron.down") { playback.isFullScreen = false }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if playback.item?.isLive == true { LiveBadge() }
                    if let ch = playback.item?.channel, recorder.isRecording(channel: ch.number) {
                        Pill(text: "REC", color: Theme.record, symbol: "record.circle")
                    }
                    if tuners.connection == .remote { Pill(text: "REMOTE", color: .cyan.opacity(0.6), symbol: "globe") }
                    if let end = playback.sleepTimerEnd {
                        Pill(text: "Sleep \(Fmt.time.string(from: end))", symbol: "moon.zzz.fill")
                    }
                }
                Text(titleLine).font(.headline).lineLimit(1)
                if let sub = subtitleLine { Text(sub).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
            }
            Spacer()

            if settings.showSignalOverlay, let ch = playback.item?.channel, let s = tuners.status(forChannel: ch.number) {
                HStack(spacing: 6) {
                    SignalBars(percent: s.signalStrength)
                    Text("\(s.signalQuality ?? 0)%").font(.caption2.monospacedDigit())
                }
                .padding(8)
                .background(.black.opacity(0.4), in: Capsule())
            }

            RoutePicker().frame(width: 36, height: 36)
            CircleButton(symbol: player.captionsOn ? "captions.bubble.fill" : "captions.bubble") {
                player.toggleCaptions()
                flash(player.captionsOn ? "Captions On" : "Captions Off")
            }
            moreMenu
        }
        .foregroundStyle(.white)
        .padding(.top, 8)
    }

    private var titleLine: String {
        switch playback.item {
        case let .live(ch)?: return guide.nowPlaying(ch.number)?.title ?? ch.name
        case let .recording(ep)?: return ep.title
        case let .local(rec)?: return rec.title
        case nil: return ""
        }
    }

    private var subtitleLine: String? {
        switch playback.item {
        case let .live(ch)?:
            let aff = guide.affiliate(ch.number).map { " · \($0)" } ?? ""
            return "\(ch.number) \(ch.name)\(aff)"
        case let .recording(ep)?: return ep.subtitleLine ?? ep.channelName
        case let .local(rec)?: return rec.subtitle ?? "\(rec.channelNumber) \(rec.channelName)"
        case nil: return nil
        }
    }

    private var moreMenu: some View {
        Menu {
            if !player.audioTracks.isEmpty {
                Menu {
                    ForEach(player.audioTracks) { t in
                        Button { player.selectAudio(t) } label: {
                            if t.id == player.selectedAudio { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                        }
                    }
                } label: { Label("Audio Track", systemImage: "waveform") }
            }
            Menu {
                Button { player.selectSubtitle(nil) } label: {
                    if !player.captionsOn { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                }
                ForEach(player.subtitleTracks) { t in
                    Button { player.selectSubtitle(t) } label: {
                        if t.id == player.selectedSubtitle { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                    }
                }
            } label: { Label("Captions", systemImage: "captions.bubble") }

            Picker(selection: Binding(get: { player.aspect }, set: { playback.setAspect($0) })) {
                ForEach(AspectMode.allCases) { m in Label(m.title, systemImage: m.symbol).tag(m) }
            } label: { Label("Aspect", systemImage: "aspectratio") }
            .pickerStyle(.menu)

            Button { player.isMuted.toggle() } label: {
                Label(player.isMuted ? "Unmute" : "Mute", systemImage: player.isMuted ? "speaker.wave.2" : "speaker.slash")
            }

            if playback.item?.isLive == false {
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                        Button { player.rate = Float(r) } label: {
                            if abs(Double(player.rate) - r) < 0.01 { Label("\(r, specifier: "%.2g")×", systemImage: "checkmark") } else { Text("\(r, specifier: "%.2g")×") }
                        }
                    }
                } label: { Label("Playback Speed", systemImage: "gauge.with.dots.needle.67percent") }
            }

            Menu {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { m in
                    Button("\(m) minutes") { playback.setSleepTimer(minutes: m); flash("Sleep in \(m) min") }
                }
                if let ch = playback.item?.channel, let now = guide.nowPlaying(ch.number) {
                    Button("End of “\(now.title)”") {
                        let mins = max(1, Int(now.end.timeIntervalSinceNow / 60) + 1)
                        playback.setSleepTimer(minutes: mins)
                        flash("Sleep at \(Fmt.time.string(from: now.end))")
                    }
                }
                if playback.sleepTimerEnd != nil { Button("Turn Off", role: .destructive) { playback.cancelSleepTimer() } }
            } label: { Label("Sleep Timer", systemImage: "moon.zzz") }

            Button { showCastSheet = true } label: { Label("Cast to Chromecast", systemImage: "tv.and.mediabox") }

            if playback.item?.isLive == true {
                Divider()
                Button { showKeypad = true } label: { Label("Enter Channel Number", systemImage: "number") }
                if playback.hasPreviousChannel {
                    Button { playback.lastChannel() } label: { Label("Previous Channel", systemImage: "arrow.uturn.backward") }
                }
                Button {
                    playback.openMultiview(with: [])
                } label: { Label("Multiview", systemImage: "rectangle.split.2x2") }
                recordMenuItems
                Button { showInfo = true } label: { Label("Program Info", systemImage: "info.circle") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .menuOrder(.fixed)
    }

    @ViewBuilder
    private var recordMenuItems: some View {
        if let ch = playback.item?.channel {
            let program = guide.nowPlaying(ch.number)
            Menu {
                if let program, program.seriesID != nil, !tuners.storageDevices.isEmpty {
                    Button { recordDVR(program, mode: .once) } label: { Label("Record This Episode (HDHomeRun)", systemImage: "record.circle") }
                    Button { recordDVR(program, mode: .series) } label: { Label("Record Series (HDHomeRun)", systemImage: "square.stack.3d.down.right") }
                }
                if recorder.isRecording(channel: ch.number) {
                    Button(role: .destructive) {
                        for a in recorder.active.values where a.recording.channelNumber == ch.number { recorder.stop(a.id) }
                        flash("Saved to iPhone")
                    } label: { Label("Stop iPhone Recording", systemImage: "stop.circle") }
                } else {
                    Button { recordLocal(ch, until: program?.end.addingTimeInterval(TimeInterval(settings.endPaddingSeconds))) } label: {
                        Label(program != nil ? "Record to iPhone Until End" : "Record to iPhone", systemImage: "iphone.and.arrow.forward")
                    }
                    Button { recordLocal(ch, until: nil) } label: { Label("Record to iPhone (Until Stopped)", systemImage: "iphone") }
                }
            } label: { Label("Record", systemImage: "record.circle") }
        }
    }

    private var centerControls: some View {
        HStack(spacing: 44) {
            if playback.item?.isLive == true {
                CircleButton(symbol: "chevron.up", size: 52) { playback.channelDown(); flashChannel() }
                    .accessibilityLabel("Previous channel")
            } else {
                CircleButton(symbol: "gobackward.\(settings.skipBackSeconds)", size: 52) { player.skip(by: -settings.skipBackSeconds) }
            }

            Button {
                player.togglePause()
                scheduleHide()
            } label: {
                Image(systemName: player.state == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 34, weight: .bold))
                    .frame(width: 78, height: 78)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            if playback.item?.isLive == true {
                CircleButton(symbol: "chevron.down", size: 52) { playback.channelUp(); flashChannel() }
                    .accessibilityLabel("Next channel")
            } else {
                CircleButton(symbol: "goforward.\(settings.skipForwardSeconds)", size: 52) { player.skip(by: settings.skipForwardSeconds) }
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if case let .live(ch)? = playback.item {
            NowTicker(interval: 15) { now in
                VStack(alignment: .leading, spacing: 8) {
                    if let p = guide.nowPlaying(ch.number, at: now) {
                        HStack {
                            Text(Fmt.range(p.start, p.end)).font(.caption.monospacedDigit())
                            Spacer()
                            Text(Fmt.remaining(until: p.end)).font(.caption)
                        }
                        .foregroundStyle(.white.opacity(0.8))
                        ProgressLine(value: p.progress(at: now), tint: Theme.live, height: 4)
                        if let next = guide.upNext(ch.number, at: now) {
                            Text("Up next \(Fmt.time.string(from: next.start)) · \(next.title)")
                                .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                    }
                    HStack {
                        Button {
                            withAnimation(.snappy) { showChannelStrip.toggle() }
                        } label: {
                            Label("Channels", systemImage: "square.grid.3x1.below.line.grid.1x2")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        Spacer()
                        Button { settings.toggleFavorite(ch.number); flash(settings.isFavorite(ch.number) ? "Added to Favorites" : "Removed from Favorites") } label: {
                            Image(systemName: settings.isFavorite(ch.number) ? "star.fill" : "star")
                                .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .foregroundStyle(.white)
                }
            }
        } else {
            VStack(spacing: 6) {
                Slider(value: Binding(
                    get: { scrubbing ?? player.currentTime },
                    set: { scrubbing = $0 }
                ), in: 0...max(player.duration, 1)) { editing in
                    if !editing, let s = scrubbing { player.seek(to: s); scrubbing = nil }
                    scheduleHide()
                }
                .tint(.white)
                HStack {
                    Text(Fmt.clock(scrubbing ?? player.currentTime))
                    Spacer()
                    Text("-" + Fmt.clock(max(0, player.duration - (scrubbing ?? player.currentTime))))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    // MARK: Actions

    private func retry() {
        switch playback.item {
        case let .live(ch)?: playback.play(ch)
        case let .recording(ep)?: playback.play(ep)
        case let .local(rec)?: playback.play(rec)
        case nil: break
        }
    }

    private func recordDVR(_ program: GuideProgram, mode: DVRStore.RecordMode) {
        Task {
            do {
                try await dvr.record(program, mode: mode, settings: settings, tuners: tuners)
                Haptics.success()
                flash(mode == .series ? "Series recording scheduled" : "Recording on HDHomeRun")
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

    private func flashChannel() {
        if let ch = playback.item?.channel { flash("\(ch.number)  \(ch.name)") }
    }

    private func flash(_ text: String) {
        withAnimation(.snappy) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeOut) { if toast == text { toast = nil } }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            if player.state == .playing && !showChannelStrip {
                withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
            }
        }
    }

    private func pollSignal() async {
        guard playback.item?.isLive == true else { return }
        while !Task.isCancelled {
            await tuners.refreshStatus()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}

struct CircleButton: View {
    var symbol: String
    var size: CGFloat = 40
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Horizontal strip of channels with live "now playing" info, shown over the video.
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
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    ChannelLogo(url: guide.logo(ch.number), number: ch.number, name: ch.name, size: 30)
                                    Text(ch.number).font(.caption.weight(.bold).monospacedDigit())
                                    Spacer()
                                }
                                Text(guide.nowPlaying(ch.number)?.title ?? ch.name)
                                    .font(.caption.weight(.semibold)).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if let p = guide.nowPlaying(ch.number) { ProgressLine(value: p.progress(), tint: Theme.live, height: 2) }
                            }
                            .padding(10)
                            .frame(width: 150, height: 104)
                            .background(playback.currentChannel == ch ? AnyShapeStyle(Color.accentColor.opacity(0.35)) : AnyShapeStyle(.ultraThinMaterial),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .id(ch.number)
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: 120)
            .padding(.bottom, 16)
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
            Text(entry.isEmpty ? "Channel" : entry)
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(entry.isEmpty ? .secondary : .primary)
                .frame(height: 50)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                ForEach(keys, id: \.self) { k in
                    Button {
                        Haptics.tap()
                        if k == "⌫" { if !entry.isEmpty { entry.removeLast() } } else if entry.count < 7 { entry.append(k) }
                    } label: {
                        Text(k).font(.title.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                onSubmit(entry)
                dismiss()
            } label: {
                Text("Tune").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
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
                        HStack { ProgressView(); Text("Searching for Chromecast devices…").foregroundStyle(.secondary) }
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
                    Text("Casting streams to Chromecast / Google TV devices on your network. Use the AirPlay button for AirPlay audio.")
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
