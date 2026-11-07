import SwiftUI

struct ProgramDetailView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(DVRStore.self) private var dvr
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(LocalRecorder.self) private var recorder
    @Environment(\.dismiss) private var dismiss

    var program: GuideProgram

    @State private var working = false
    @State private var message: String?
    @State private var reminderSet = false
    @State private var showTargetChoice = false

    private var channel: Channel? { tuners.channel(program.channelNumber) }
    private var hasStorage: Bool { !tuners.storageDevices.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                VStack(alignment: .leading, spacing: 14) {
                    metaRow
                    actionButtons
                    if let message {
                        Label(message, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let s = program.synopsis, !s.isEmpty {
                        Text(s).font(.body).foregroundStyle(.primary.opacity(0.9))
                    }
                    detailsGrid
                    if let channel {
                        NavigationLink {
                            ChannelDetailView(channel: channel)
                        } label: {
                            Label("Everything on \(channel.number) \(channel.name)", systemImage: "calendar")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .cardStyle(padding: 12)
                        }
                        .buttonStyle(.plain)
                    }
                    otherAirings
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.hierarchical).font(.title2) }
            }
        }
        .task {
            reminderSet = await Reminders.pendingIDs().contains(Reminders.identifier(for: program))
        }
        .confirmationDialog("Record to…", isPresented: $showTargetChoice) {
            Button("HDHomeRun Storage") { recordDVR(.once) }
            Button("This iPhone") { recordLocal() }
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(url: program.imageURL ?? program.posterURL, fallbackSymbol: program.primaryGenre?.symbol ?? "tv", cornerRadius: 0)
                .frame(height: 260)
                .clipped()
            LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if program.isAiring() { LiveBadge() }
                    if program.isNew { Pill(text: "NEW", color: .accentColor) }
                    if dvr.isScheduled(program) { Pill(text: "RECORDING", color: Theme.record, symbol: "record.circle") }
                    ForEach(program.genres.prefix(2)) { g in
                        Pill(text: g.name.uppercased(), color: g.color.opacity(0.8))
                    }
                }
                Text(program.title).font(.largeTitle.weight(.bold)).lineLimit(3).minimumScaleFactor(0.7)
                if let sub = program.subtitleLine { Text(sub).font(.headline).foregroundStyle(.secondary) }
            }
            .padding()
        }
    }

    private var metaRow: some View {
        HStack(spacing: 10) {
            ChannelLogo(url: guide.logo(program.channelNumber), number: program.channelNumber, name: channel?.name ?? "", size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(program.channelNumber) \(channel?.name ?? "")").font(.subheadline.weight(.semibold))
                Text("\(Fmt.smartDay(program.start)) – \(Fmt.time.string(from: program.end)) · \(Fmt.duration(program.duration))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) {
            if program.isAiring() { ProgressLine(value: program.progress(), tint: Theme.live, height: 3).offset(y: 10) }
        }
        .padding(.bottom, 6)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            if program.isAiring(), let channel {
                Button {
                    dismiss()
                    playback.play(channel)
                } label: {
                    Label("Watch Live", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            HStack(spacing: 10) {
                if dvr.isScheduled(program) {
                    Button(role: .destructive) { cancelRecording() } label: {
                        Label("Cancel Recording", systemImage: "xmark.circle").frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                } else if program.end > Date() {
                    Menu {
                        if hasStorage && program.seriesID != nil {
                            Section("Save to HDHomeRun storage") {
                                Button { recordDVR(.once) } label: { Label("Just This Airing", systemImage: "record.circle") }
                                Button { recordDVR(.newOnChannel) } label: { Label("New Episodes on \(channel?.name ?? "This Channel")", systemImage: "sparkles") }
                                Button { recordDVR(.seriesOnChannel) } label: { Label("All Episodes on \(channel?.name ?? "This Channel")", systemImage: "square.stack.3d.down.right") }
                                Button { recordDVR(.series) } label: { Label("All Episodes, Any Channel", systemImage: "antenna.radiowaves.left.and.right") }
                            }
                        }
                        if program.isAiring() {
                            Section("Save to this iPhone") {
                                Button { recordLocal() } label: { Label("Record Now Until It Ends", systemImage: "iphone.and.arrow.forward") }
                            }
                        }
                        if !hasStorage {
                            Text("Plug a USB drive into your HDHomeRun to schedule recordings.")
                        }
                    } label: {
                        Label("Record", systemImage: "record.circle").frame(maxWidth: .infinity, minHeight: 30)
                    } primaryAction: {
                        quickRecord()
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.record)
                    .disabled(working)
                }

                if program.start > Date() {
                    Button { toggleReminder() } label: {
                        Label(reminderSet ? "Reminder Set" : "Remind Me", systemImage: reminderSet ? "bell.fill" : "bell")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if dvr.hasSeriesRule(program.seriesID) {
                Label("Series recording is on", systemImage: "checkmark.seal.fill").font(.footnote).foregroundStyle(.green)
            }
        }
    }

    private var detailsGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let air = program.originalAirdate {
                detailRow("Original Air Date", Fmt.day.string(from: air))
            }
            if let ep = program.episodeNumber { detailRow("Episode", ep) }
            if !program.genres.isEmpty { detailRow("Genres", program.genres.map(\.name).joined(separator: ", ")) }
            if let ch = channel {
                detailRow("Format", [ch.isHD ? "HD" : "SD", ch.videoCodec, ch.audioCodec].compactMap { $0 }.joined(separator: " · "))
            }
        }
        .cardStyle()
    }

    private func detailRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.subheadline).multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private var otherAirings: some View {
        if let sid = program.seriesID {
            let airings = guide.airings(seriesID: sid).filter { $0.id != program.id }
            if !airings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "More Airings")
                    ForEach(airings.prefix(10)) { a in
                        NavigationLink {
                            ProgramDetailView(program: a)
                        } label: {
                            ProgramRow(program: a, logo: guide.logo(a.channelNumber), scheduled: dvr.isScheduled(a), now: Date())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func quickRecord() {
        switch settings.recordingTarget {
        case .device where hasStorage && program.seriesID != nil: recordDVR(.once)
        case .phone where program.isAiring(): recordLocal()
        default:
            if hasStorage && program.isAiring() { showTargetChoice = true }
            else if hasStorage { recordDVR(.once) }
            else if program.isAiring() { recordLocal() }
            else { message = "Scheduling future recordings needs HDHomeRun storage (USB drive on your FLEX 4K, or HDHomeRun DVR on a NAS)." }
        }
    }

    private func recordDVR(_ mode: DVRStore.RecordMode) {
        working = true
        Task {
            defer { working = false }
            do {
                try await dvr.record(program, mode: mode, settings: settings, tuners: tuners)
                Haptics.success()
                message = mode == .once ? "Scheduled on your HDHomeRun." : "Series recording created."
            } catch {
                Haptics.error()
                message = error.localizedDescription
            }
        }
    }

    private func recordLocal() {
        guard let channel, let url = tuners.streamURL(for: channel) else { return }
        recorder.start(url: url, channel: channel, program: program, until: program.end.addingTimeInterval(TimeInterval(settings.endPaddingSeconds)))
        Haptics.success()
        message = "Recording to this iPhone until \(Fmt.time.string(from: program.end)). Keep OverAir open or playing for best results."
    }

    private func cancelRecording() {
        working = true
        Task {
            defer { working = false }
            do {
                try await dvr.cancel(program, tuners: tuners)
                message = "Recording cancelled."
            } catch { message = error.localizedDescription }
        }
    }

    private func toggleReminder() {
        if reminderSet {
            Reminders.cancel(program)
            reminderSet = false
        } else {
            Task {
                reminderSet = await Reminders.schedule(program, channelName: channel?.name ?? "", minutesBefore: settings.reminderMinutes)
                if !reminderSet { message = "Allow notifications in Settings to use reminders." }
            }
        }
    }
}
