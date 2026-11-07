import SwiftUI

/// High-performance EPG grid: a single 2-D scroll view that only renders the
/// cells intersecting the viewport, with a pinned time ruler and channel column.
struct GuideView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide
    @Environment(DVRStore.self) private var dvr
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.horizontalSizeClass) private var hSize

    @State private var category: ProgramCategory = .all
    @State private var favoritesOnly = false
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
    @State private var selected: GuideProgram?
    @State private var zoom: Double = 1
    @State private var didInitialScroll = false

    private var pointsPerMinute: CGFloat { (hSize == .regular ? 6.5 : 5) * zoom }
    private var rowHeight: CGFloat { settings.guideRowHeight }
    private var channelColumnWidth: CGFloat { hSize == .regular ? 120 : 84 }
    private let headerHeight: CGFloat = 34

    private var start: Date { GuideStore.windowStart().addingTimeInterval(-1800) }
    private var end: Date { max(guide.guideEnd, start.addingTimeInterval(4 * 3600)) }

    private var rows: [Channel] {
        favoritesOnly ? tuners.favoriteChannels : tuners.visibleChannels
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if !guide.hasData {
                if guide.isLoading {
                    ProgressView("Loading guide…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(symbol: "calendar.badge.exclamationmark", title: "No Guide Data",
                                   message: guide.lastError ?? "Guide data comes from SiliconDust using your tuner's DeviceAuth.",
                                   actionTitle: "Load Guide") {
                        Task { await guide.load(deviceAuth: tuners.deviceAuth, hours: settings.guideHours, force: true) }
                    }
                }
            } else {
                NowTicker(interval: 30) { now in grid(now: now) }
            }
        }
        .navigationTitle("Guide")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button { jump(to: Date()) } label: { Label("Now", systemImage: "clock") }
                    Button { jump(to: tonight(hour: 20)) } label: { Label("Tonight 8 PM", systemImage: "moon.stars") }
                    Button { jump(to: tomorrow(hour: 8)) } label: { Label("Tomorrow Morning", systemImage: "sunrise") }
                    Button { jump(to: tomorrow(hour: 20)) } label: { Label("Tomorrow Night", systemImage: "sparkles.tv") }
                } label: { Image(systemName: "clock.arrow.circlepath") }
                Menu {
                    Button { zoom = min(zoom * 1.25, 2.5) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                    Button { zoom = max(zoom / 1.25, 0.5) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                    Divider()
                    Button { Task { await guide.load(deviceAuth: tuners.deviceAuth, hours: settings.guideHours, force: true) } } label: {
                        Label("Refresh Guide", systemImage: "arrow.clockwise")
                    }
                } label: { Image(systemName: "slider.horizontal.3") }
            }
        }
        .sheet(item: $selected) { p in
            NavigationStack { ProgramDetailView(program: p) }
                .presentationDetents([.medium, .large])
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy) { favoritesOnly.toggle() }
            } label: {
                Image(systemName: favoritesOnly ? "star.fill" : "star")
                    .padding(8)
                    .background(favoritesOnly ? AnyShapeStyle(Color.yellow.opacity(0.3)) : AnyShapeStyle(Theme.card), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading)
            CategoryChips(selection: $category)
        }
        .padding(.vertical, 8)
    }

    // MARK: Grid

    private func x(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(start) / 60) * pointsPerMinute
    }

    private func grid(now: Date) -> some View {
        let totalWidth = channelColumnWidth + x(for: end)
        let totalHeight = headerHeight + CGFloat(rows.count) * rowHeight
        let visibleRows = visibleRowRange()

        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: totalWidth, height: totalHeight)
                programLayer(rows: visibleRows, now: now)
                nowLine(now: now, height: totalHeight - headerHeight)
                channelColumn(rows: visibleRows)
                ruler(now: now)
                corner
            }
        }
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGRect.self) { geo in
            CGRect(origin: geo.contentOffset, size: geo.containerSize)
        } action: { _, new in
            viewport = new
        }
        .onAppear {
            if !didInitialScroll {
                didInitialScroll = true
                DispatchQueue.main.async { jump(to: Date(), animated: false) }
            }
        }
        .overlay(alignment: .bottomTrailing) { nowButton }
    }

    private var visibleStart: Date {
        start.addingTimeInterval(Double(max(0, viewport.minX - channelColumnWidth)) / Double(pointsPerMinute) * 60 - 3600)
    }

    private var visibleEnd: Date {
        start.addingTimeInterval(Double(viewport.maxX) / Double(pointsPerMinute) * 60 + 1800)
    }

    private func visiblePrograms(for channel: Channel) -> [GuideProgram] {
        let vs = visibleStart, ve = visibleEnd, s = start
        return guide.programs(for: channel.number).filter { $0.end > vs && $0.start < ve && $0.end > s }
    }

    private func programLayer(rows visibleRows: [Int], now: Date) -> some View {
        ForEach(visibleRows, id: \.self) { (row: Int) in
            GuideRowCells(
                channel: rows[row],
                programs: visiblePrograms(for: rows[row]),
                rowY: headerHeight + CGFloat(row) * rowHeight,
                rowHeight: rowHeight,
                leadingX: channelColumnWidth,
                viewportMinX: viewport.minX,
                viewportWidth: viewport.width,
                now: now,
                category: category,
                xFor: { x(for: $0) },
                isScheduled: { dvr.isScheduled($0) },
                onSelect: { selected = $0 },
                menu: { p, ch in AnyView(cellMenu(p, channel: ch)) }
            )
        }
    }

    private func nowLine(now: Date, height: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.live)
            .frame(width: 2, height: max(height, 0))
            .offset(x: channelColumnWidth + x(for: now) - 1, y: headerHeight)
            .allowsHitTesting(false)
    }

    private func channelColumn(rows visibleRows: [Int]) -> some View {
        ForEach(visibleRows, id: \.self) { (row: Int) in
            channelCell(rows[row])
                .offset(x: viewport.minX, y: headerHeight + CGFloat(row) * rowHeight)
        }
    }

    private func channelCell(_ ch: Channel) -> some View {
        GuideChannelCell(channel: ch, logo: guide.logo(ch.number), isPlaying: playback.currentChannel == ch, width: channelColumnWidth)
            .frame(width: channelColumnWidth, height: rowHeight)
            .onTapGesture { playback.play(ch) }
            .contextMenu {
                Button { playback.play(ch) } label: { Label("Watch", systemImage: "play.fill") }
                Button { settings.toggleFavorite(ch.number) } label: {
                    Label(settings.isFavorite(ch.number) ? "Remove Favorite" : "Favorite", systemImage: "star")
                }
            }
    }

    private func ruler(now: Date) -> some View {
        TimeRuler(start: start, end: end, pointsPerMinute: pointsPerMinute, now: now)
            .frame(width: x(for: end), height: headerHeight)
            .offset(x: channelColumnWidth, y: viewport.minY)
    }

    private var corner: some View {
        Text(Fmt.day.string(from: dayAt(viewport)))
            .font(.caption2.weight(.bold))
            .multilineTextAlignment(.center)
            .frame(width: channelColumnWidth, height: headerHeight)
            .background(.bar)
            .offset(x: viewport.minX, y: viewport.minY)
    }

    @ViewBuilder
    private var nowButton: some View {
        if abs(viewport.minX - max(0, x(for: Date()) - 60)) > 400 {
            Button { jump(to: Date()) } label: {
                Label("Now", systemImage: "arrow.uturn.backward")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
            }
            .padding()
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func visibleRowRange() -> [Int] {
        guard !rows.isEmpty else { return [] }
        let first = max(0, Int((viewport.minY) / rowHeight) - 2)
        let last = min(rows.count - 1, Int((viewport.maxY) / rowHeight) + 2)
        guard first <= last else { return [] }
        return Array(first...last)
    }

    private func dayAt(_ rect: CGRect) -> Date {
        start.addingTimeInterval(Double(rect.minX) / Double(pointsPerMinute) * 60 + 1800)
    }

    @ViewBuilder
    private func cellMenu(_ p: GuideProgram, channel: Channel) -> some View {
        if p.isAiring() {
            Button { playback.play(channel) } label: { Label("Watch Now", systemImage: "play.fill") }
        }
        if !tuners.storageDevices.isEmpty, p.seriesID != nil, p.end > Date() {
            Button {
                Task { try? await dvr.record(p, mode: .once, settings: settings, tuners: tuners); Haptics.success() }
            } label: { Label("Record Episode", systemImage: "record.circle") }
            Button {
                Task { try? await dvr.record(p, mode: .series, settings: settings, tuners: tuners); Haptics.success() }
            } label: { Label("Record Series", systemImage: "square.stack.3d.down.right") }
        }
        Button { selected = p } label: { Label("Details", systemImage: "info.circle") }
    }

    // MARK: Navigation

    private func jump(to date: Date, animated: Bool = true) {
        let target = max(0, x(for: date) - 60)
        if animated {
            withAnimation(.snappy) { position.scrollTo(x: target) }
        } else {
            position.scrollTo(x: target)
        }
    }

    private func tonight(hour: Int) -> Date {
        let cal = Calendar.current
        let d = cal.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return d < Date() ? Date() : d
    }

    private func tomorrow(hour: Int) -> Date {
        let cal = Calendar.current
        let t = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: t) ?? t
    }
}

/// One channel's worth of program cells, absolutely positioned inside the grid.
struct GuideRowCells: View {
    var channel: Channel
    var programs: [GuideProgram]
    var rowY: CGFloat
    var rowHeight: CGFloat
    var leadingX: CGFloat
    var viewportMinX: CGFloat
    var viewportWidth: CGFloat
    var now: Date
    var category: ProgramCategory
    var xFor: (Date) -> CGFloat
    var isScheduled: (GuideProgram) -> Bool
    var onSelect: (GuideProgram) -> Void
    var menu: (GuideProgram, Channel) -> AnyView

    var body: some View {
        if programs.isEmpty {
            Text("No guide data")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 12)
                .frame(width: max(viewportWidth - leadingX, 100), height: rowHeight - 2, alignment: .leading)
                .offset(x: viewportMinX + leadingX, y: rowY)
        } else {
            ForEach(programs) { (p: GuideProgram) in
                cell(p)
            }
        }
    }

    private func cell(_ p: GuideProgram) -> some View {
        let x0 = max(xFor(p.start), 0)
        let width = max(xFor(p.end) - x0, 8)
        let pinned = max(0, viewportMinX - (leadingX + x0))
        return ProgramCell(program: p, now: now, highlighted: category == .all || p.category == category,
                           scheduled: isScheduled(p), pinnedLeading: min(pinned, max(width - 60, 0)))
            .frame(width: width - 2, height: rowHeight - 2)
            .offset(x: leadingX + x0 + 1, y: rowY + 1)
            .onTapGesture { onSelect(p) }
            .contextMenu { menu(p, channel) }
    }
}

struct ProgramCell: View {
    var program: GuideProgram
    var now: Date
    var highlighted: Bool
    var scheduled: Bool
    /// How far the cell's leading edge is scrolled under the channel column, so the title stays visible.
    var pinnedLeading: CGFloat

    var body: some View {
        let airing = program.isAiring(at: now)
        let past = program.end <= now
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(airing ? Color.white.opacity(0.13) : Color.white.opacity(0.06))
            if airing {
                GeometryReader { g in
                    Rectangle().fill(Color.white.opacity(0.06))
                        .frame(width: g.size.width * program.progress(at: now))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Rectangle()
                .fill(Theme.color(for: program.category))
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(.vertical, 6)
                .opacity(program.category == .show ? 0 : 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if scheduled { RecordDot() }
                    Text(program.title).font(.footnote.weight(.semibold)).lineLimit(1)
                    if program.isNew { Pill(text: "NEW", color: .accentColor) }
                }
                if let sub = program.subtitleLine {
                    Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(Fmt.range(program.start, program.end)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .offset(x: pinnedLeading)
        }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(airing ? Theme.live.opacity(0.5) : Theme.cardStroke, lineWidth: airing ? 1 : 0.5))
        .opacity(highlighted ? (past ? 0.45 : 1) : 0.25)
        .clipped()
        .contentShape(Rectangle())
    }
}

struct GuideChannelCell: View {
    var channel: Channel
    var logo: URL?
    var isPlaying: Bool
    var width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            if width > 100 {
                ChannelLogo(url: logo, number: channel.number, name: channel.name, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.number).font(.caption.weight(.bold).monospacedDigit())
                    Text(channel.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                VStack(spacing: 2) {
                    ChannelLogo(url: logo, number: channel.number, name: channel.name, size: 34)
                    Text(channel.number).font(.system(size: 10, weight: .bold).monospacedDigit())
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .leading) {
            if isPlaying { Rectangle().fill(Color.accentColor).frame(width: 3) }
        }
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct TimeRuler: View {
    var start: Date
    var end: Date
    var pointsPerMinute: CGFloat
    var now: Date

    var body: some View {
        let slots = Int(end.timeIntervalSince(start) / 1800)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.bar)
            ForEach(0..<max(slots, 0), id: \.self) { i in
                let t = start.addingTimeInterval(Double(i) * 1800)
                VStack(alignment: .leading, spacing: 0) {
                    Text(label(t))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Calendar.current.component(.minute, from: t) == 0 ? .primary : .secondary)
                }
                .padding(.leading, 6)
                .frame(width: 30 * pointsPerMinute, height: 34, alignment: .leading)
                .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 12) }
                .offset(x: CGFloat(i) * 30 * pointsPerMinute)
            }
            Capsule().fill(Theme.live)
                .frame(width: 10, height: 10)
                .offset(x: CGFloat(now.timeIntervalSince(start) / 60) * pointsPerMinute - 5, y: 24)
        }
    }

    private func label(_ t: Date) -> String {
        let cal = Calendar.current
        if cal.component(.hour, from: t) == 0 && cal.component(.minute, from: t) == 0 {
            return Fmt.day.string(from: t)
        }
        return Fmt.time.string(from: t)
    }
}
