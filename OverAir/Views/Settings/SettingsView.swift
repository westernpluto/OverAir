import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                if let tuner = tuners.selectedTuner {
                    NavigationLink { DeviceDetailView(device: tuner) } label: { TunerSummaryRow(device: tuner) }
                } else {
                    Button { Task { await tuners.discover() } } label: {
                        HStack {
                            Label("Find My HDHomeRun", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if tuners.isDiscovering { ProgressView() }
                        }
                    }
                }
                NavigationLink { RemoteAccessView() } label: {
                    LabeledContent {
                        Text(settings.remoteMethod == .none ? "Not set up" : settings.remoteMethod.title)
                    } label: {
                        Label("Watch Away From Home", systemImage: "globe")
                    }
                }
                NavigationLink { TunerStatusView() } label: {
                    LabeledContent { Text("\(tuners.tunersInUse) of \(tuners.totalTuners) in use") } label: {
                        Label("Signal & Tuners", systemImage: "chart.bar.fill")
                    }
                }
                NavigationLink { ChannelManagerView() } label: {
                    LabeledContent { Text("\(tuners.channels.count)") } label: { Label("Channels & Favorites", systemImage: "list.number") }
                }
                NavigationLink { DevicesListView() } label: { Label("All Devices", systemImage: "externaldrive.connected.to.line.below") }
            } header: {
                Text("Your HDHomeRun")
            } footer: {
                if tuners.isDiscovering { Text(tuners.discoveryPhase) }
            }

            Section {
                Toggle("Closed Captions On by Default", isOn: $settings.closedCaptionsByDefault)
                Toggle("Keep Playing in Background", isOn: $settings.backgroundAudio)
                Toggle("Open Last Channel at Launch", isOn: $settings.autoplayLastChannel)
                Toggle("Show Signal Strength in Player", isOn: $settings.showSignalOverlay)
                Picker("Picture Size", selection: $settings.aspectMode) {
                    ForEach(AspectMode.allCases) { Text($0.title).tag($0) }
                }
                NavigationLink("Advanced Playback") { AdvancedPlaybackView() }
            } header: {
                Text("Watching")
            }

            Section {
                Picker("Record Button Saves To", selection: $settings.recordingTarget) {
                    ForEach(RecordingTarget.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Start \(settings.startPaddingSeconds / 60) min early", value: $settings.startPaddingSeconds, in: 0...1800, step: 60)
                Stepper("End \(settings.endPaddingSeconds / 60) min late", value: $settings.endPaddingSeconds, in: 0...3600, step: 60)
                Stepper("Reminders \(settings.reminderMinutes) min before", value: $settings.reminderMinutes, in: 0...30)
            } header: {
                Text("Recording")
            } footer: {
                Text("Starting early and ending late helps when shows run over, like live sports.")
            }

            Section {
                Picker("Days of Listings", selection: $settings.guideHours) {
                    Text("1 day").tag(24)
                    Text("2 days").tag(48)
                    Text("4 days").tag(96)
                    Text("7 days").tag(168)
                }
                Picker("Row Size", selection: $settings.guideRowHeight) {
                    Text("Compact").tag(58.0)
                    Text("Regular").tag(72.0)
                    Text("Large").tag(88.0)
                }
                Toggle("Favorites at the Top", isOn: $settings.favoritesFirst)
                Toggle("Hide Protected (DRM) Channels", isOn: $settings.hideDRMChannels)
                Button("Refresh Listings Now") {
                    Task { await guide.load(deviceAuth: tuners.deviceAuth, hours: settings.guideHours, force: true) }
                }
            } header: {
                Text("Guide")
            } footer: {
                if let d = guide.lastUpdated {
                    Text("Updated \(Fmt.smartDay(d)). More than a day of listings requires an HDHomeRun DVR subscription.")
                }
            }

            Section {
                Toggle("Haptic Feedback", isOn: $settings.haptics)
                Button("Show Player Tips Again") { settings.playerTipsSeen = false; settings.guideTipsSeen = false }
            } header: {
                Text("General")
            }

            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                Link(destination: URL(string: "https://my.hdhomerun.com")!) { Label("HDHomeRun Account & DVR Service", systemImage: "arrow.up.right.square") }
            } header: {
                Text("About OverAir")
            } footer: {
                Text("OverAir is an independent app and isn't affiliated with SiliconDust. HDHomeRun is a trademark of SiliconDust USA Inc.")
            }
        }
        .navigationTitle("Settings")
    }
}

struct TunerSummaryRow: View {
    @Environment(TunerStore.self) private var tuners
    var device: HDHRDevice

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayModel).font(.headline)
                Text("\(device.tunerCount) tuners · \(tuners.channels.count) channels\(tuners.storageDevices.isEmpty ? "" : " · DVR storage")")
                    .font(.caption).foregroundStyle(.secondary)
                ConnectionBadge(state: tuners.connection)
            }
        }
        .padding(.vertical, 4)
    }
}

struct DevicesListView: View {
    @Environment(TunerStore.self) private var tuners

    var body: some View {
        List {
            Section {
                ForEach(tuners.devices) { d in
                    NavigationLink { DeviceDetailView(device: d) } label: { DeviceRow(device: d, selected: d.id == tuners.selectedTuner?.id) }
                }
            } footer: {
                if tuners.isDiscovering { Text(tuners.discoveryPhase) }
            }
            Section {
                Button {
                    Task { await tuners.discover() }
                } label: {
                    HStack {
                        Label("Search This Network", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        if tuners.isDiscovering { ProgressView() }
                    }
                }
                NavigationLink { AddDeviceView() } label: { Label("Add by IP Address", systemImage: "plus.circle") }
            }
        }
        .navigationTitle("Devices")
    }
}

struct AdvancedPlaybackView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Rewind Live TV Up To", selection: $settings.rewindMinutes) {
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                }
            } footer: {
                Text("Live TV is buffered on this iPhone so you can pause and rewind. Uses up to \(Fmt.bytes(settings.rewindBufferBytes)) of temporary storage while watching.")
            }
            Section {
                Toggle("Smooth Interlaced Video", isOn: $settings.deinterlace)
            } footer: {
                Text("Most HD channels broadcast 1080i. OverAir converts it to smooth 60 fps on the GPU.")
            }
            Section {
                Toggle("Reduce Loud Sounds", isOn: $settings.reduceLoudSounds)
            } footer: {
                Text("Uses the loudness information broadcasters send with Dolby Digital audio, so loud scenes and commercials stay closer to the level of dialogue. Applies the next time you start a channel.")
            }
            Section {
                Picker("Skip Back", selection: $settings.skipBackSeconds) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Picker("Skip Forward", selection: $settings.skipForwardSeconds) {
                    ForEach([10, 15, 30, 45, 60, 75, 90], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            } header: {
                Text("Recordings")
            }
        }
        .navigationTitle("Advanced Playback")
    }
}

struct DeviceRow: View {
    var device: HDHRDevice
    var selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.isTuner ? "antenna.radiowaves.left.and.right" : "externaldrive.fill")
                .font(.title3)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(device.displayModel).font(.subheadline.weight(.semibold))
                    if selected { Pill(text: "ACTIVE", color: .green.opacity(0.6)) }
                    if device.isRemote { Pill(text: "REMOTE", color: .cyan.opacity(0.6)) }
                }
                Text([device.deviceID, device.effectiveBaseURL.host, device.isTuner ? "\(device.tunerCount) tuners" : nil, device.hasStorage ? "Storage" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DeviceDetailView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(\.dismiss) private var dismiss
    var device: HDHRDevice

    var body: some View {
        Form {
            Section {
                LabeledContent("Model", value: device.displayModel)
                if let m = device.modelNumber { LabeledContent("Model Number", value: m) }
                if let id = device.deviceID { LabeledContent("Device ID", value: id) }
                if let id = device.storageID { LabeledContent("Storage ID", value: id) }
                LabeledContent("Address", value: device.effectiveBaseURL.absoluteString)
                if let fw = device.firmwareVersion { LabeledContent("Firmware", value: fw) }
                if let up = device.upgradeAvailable { LabeledContent("Update Available", value: up).foregroundStyle(.orange) }
                if device.isTuner { LabeledContent("Tuners", value: "\(device.tunerCount)") }
                if device.supportsATSC3 { LabeledContent("ATSC 3.0 (NextGen TV)", value: "Supported") }
                if let total = device.totalSpace, total > 0 {
                    LabeledContent("Storage", value: "\(Fmt.bytes(device.freeSpace ?? 0)) free of \(Fmt.bytes(total))")
                }
            }
            Section {
                if device.isTuner && tuners.selectedTuner?.id != device.id {
                    Button("Use This Tuner") { Task { await tuners.select(device) } }
                }
                Link(destination: device.effectiveBaseURL) { Label("Open Device Web Page", systemImage: "safari") }
                Button("Forget Device", role: .destructive) {
                    tuners.forget(device)
                    dismiss()
                }
            }
        }
        .navigationTitle(device.friendlyName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AddDeviceView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var remote = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("192.168.1.50 or hdhomerun.local", text: $host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("This is a remote address (VPN / Tailscale / port forward)", isOn: $remote)
            } footer: {
                Text("Enter the IP address or hostname of your HDHomeRun. Remote addresses are used automatically when you're away from home.")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button {
                    working = true
                    Task {
                        defer { working = false }
                        do {
                            _ = try await tuners.addManualDevice(host: host, remote: remote)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                } label: {
                    HStack { Text("Connect"); Spacer(); if working { ProgressView() } }
                }
                .disabled(host.isEmpty || working)
            }
        }
        .navigationTitle("Add Device")
    }
}
