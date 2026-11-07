import SwiftUI

struct TunerStatusView: View {
    @Environment(TunerStore.self) private var tuners

    var body: some View {
        List {
            if tuners.tunerStatus.isEmpty {
                Text("Fetching tuner status…").foregroundStyle(.secondary)
            }
            ForEach(tuners.tunerStatus) { s in
                Section {
                    if s.inUse {
                        LabeledContent("Channel", value: [s.channelNumber, s.channelName].compactMap { $0 }.joined(separator: " "))
                        if let f = s.frequency { LabeledContent("Frequency", value: String(format: "%.1f MHz", Double(f) / 1_000_000)) }
                        SignalMeter(label: "Signal Strength", value: s.signalStrength)
                        SignalMeter(label: "Signal Quality", value: s.signalQuality)
                        SignalMeter(label: "Symbol Quality", value: s.symbolQuality)
                        if let r = s.networkRate { LabeledContent("Bitrate", value: String(format: "%.1f Mbps", Double(r) / 1_000_000)) }
                        if let ip = s.targetIP { LabeledContent("Streaming To", value: ip) }
                    } else {
                        Text("Idle").foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text(s.displayName)
                        Spacer()
                        Circle().fill(s.inUse ? Color.green : Color.gray).frame(width: 8, height: 8)
                    }
                }
            }
            Section {
                Text("Tip: tune a channel and watch Signal Quality while adjusting your antenna. Aim for 80%+ quality for glitch-free ATSC 3.0.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Tuners")
        .task {
            while !Task.isCancelled {
                await tuners.refreshStatus()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
}

struct ChannelManagerView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(AppSettings.self) private var settings
    @Environment(GuideStore.self) private var guide
    @State private var scanSource = "Antenna"
    @State private var query = ""

    var body: some View {
        List {
            Section {
                if let s = tuners.lineupStatus, s.scanInProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scanning… \(s.progress)% · \(s.found) found").font(.subheadline)
                        ProgressView(value: Double(s.progress), total: 100)
                    }
                    Button("Stop Scan", role: .destructive) { Task { await tuners.abortChannelScan() } }
                } else {
                    if let list = tuners.lineupStatus?.sourceList, list.count > 1 {
                        Picker("Source", selection: $scanSource) { ForEach(list, id: \.self) { Text($0).tag($0) } }
                    }
                    Button { Task { await tuners.startChannelScan(source: scanSource) } } label: {
                        Label("Scan for Channels", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
            } footer: {
                Text("Scanning uses all tuners for a few minutes. Live TV will be interrupted.")
            }

            Section("Channels — tap star to favorite, swipe to hide") {
                ForEach(filtered) { ch in
                    HStack(spacing: 12) {
                        ChannelLogo(url: guide.logo(ch.number), number: ch.number, name: ch.name, size: 34)
                        VStack(alignment: .leading) {
                            Text("\(ch.number) \(ch.name)").font(.subheadline.weight(.medium))
                                .foregroundStyle(settings.isHidden(ch.number) ? .secondary : .primary)
                            Text([ch.isHD ? "HD" : "SD", ch.videoCodec, ch.audioCodec, ch.isDRM ? "DRM" : nil].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if settings.isHidden(ch.number) { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
                        Button { settings.toggleFavorite(ch.number) } label: {
                            Image(systemName: settings.isFavorite(ch.number) ? "star.fill" : "star").foregroundStyle(.yellow)
                        }
                        .buttonStyle(.borderless)
                    }
                    .swipeActions {
                        Button { settings.toggleHidden(ch.number) } label: {
                            Label(settings.isHidden(ch.number) ? "Show" : "Hide", systemImage: settings.isHidden(ch.number) ? "eye" : "eye.slash")
                        }
                        .tint(.gray)
                    }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Channels")
        .task {
            while !Task.isCancelled {
                await tuners.refreshScanStatus()
                if tuners.lineupStatus?.scanInProgress == true {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } else {
                    if tuners.lineupStatus != nil { await tuners.loadLineup() }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    private var filtered: [Channel] {
        guard !query.isEmpty else { return tuners.channels }
        return tuners.channels.filter { $0.number.hasPrefix(query) || $0.name.localizedCaseInsensitiveContains(query) }
    }
}

struct RemoteAccessView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TunerStore.self) private var tuners
    @State private var newHost = ""
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                LabeledContent("Status") { ConnectionBadge(state: tuners.connection) }
                Picker("Connection", selection: $settings.networkProfile) {
                    ForEach(NetworkProfile.allCases) { Text($0.title).tag($0) }
                }
                Button("Reconnect Now") { Task { await tuners.connect() } }
            } footer: {
                Text("Automatic tries your home network first, then your remote addresses.")
            }

            Section {
                ForEach(settings.remoteHosts, id: \.self) { h in
                    Label(h, systemImage: "globe")
                }
                .onDelete { settings.remoteHosts.remove(atOffsets: $0) }
                HStack {
                    TextField("100.x.y.z, myhome.ddns.net", text: $newHost)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Test & Add") {
                        testing = true
                        Task {
                            defer { testing = false }
                            do {
                                let d = try await tuners.addManualDevice(host: newHost, remote: true)
                                testResult = "Connected to \(d.displayModel) ✓"
                                newHost = ""
                            } catch {
                                testResult = error.localizedDescription
                            }
                        }
                    }
                    .disabled(newHost.isEmpty || testing)
                }
                if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Remote Addresses")
            }

            Section("How to Watch Away from Home") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("**Tailscale (recommended):** install Tailscale on a computer, Raspberry Pi or Apple TV at home with subnet routing to your HDHomeRun, and on your iPhone. Add the HDHomeRun's LAN IP here.", systemImage: "1.circle")
                    Label("**WireGuard / router VPN:** connect to your home VPN, then use the HDHomeRun's LAN IP.", systemImage: "2.circle")
                    Label("**Port forwarding (least secure):** forward TCP 80 and 5004 (and 59090 for a NAS DVR) to the HDHomeRun and add your public address or DDNS name.", systemImage: "3.circle")
                    Text("Over-the-air streams are 8–20 Mbps, so make sure your home upload speed can keep up. Increase the Remote Buffer in Settings if playback stutters.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
        .navigationTitle("Remote Access")
    }
}
