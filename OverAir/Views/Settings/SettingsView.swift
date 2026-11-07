import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TunerStore.self) private var tuners
    @Environment(GuideStore.self) private var guide

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                ForEach(tuners.devices) { d in
                    NavigationLink { DeviceDetailView(device: d) } label: { DeviceRow(device: d, selected: d.id == tuners.selectedTuner?.id) }
                }
                Button {
                    Task { await tuners.discover() }
                } label: {
                    HStack {
                        Label("Search for Devices", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        if tuners.isDiscovering { ProgressView() }
                    }
                }
                NavigationLink { AddDeviceView() } label: { Label("Add Device Manually", systemImage: "plus.circle") }
            } header: {
                Text("Devices")
            } footer: {
                if tuners.isDiscovering { Text(tuners.discoveryPhase) }
            }

            Section("Live") {
                NavigationLink { TunerStatusView() } label: {
                    LabeledContent { Text("\(tuners.tunersInUse)/\(tuners.totalTuners) in use") } label: { Label("Tuner Status & Signal", systemImage: "chart.bar.fill") }
                }
                NavigationLink { ChannelManagerView() } label: {
                    LabeledContent { Text("\(tuners.channels.count)") } label: { Label("Channels", systemImage: "list.number") }
                }
                NavigationLink { RemoteAccessView() } label: {
                    LabeledContent { Text(tuners.connection.title) } label: { Label("Remote Access", systemImage: "globe") }
                }
            }

            Section("Playback") {
                Picker("Default Aspect", selection: $settings.aspectMode) {
                    ForEach(AspectMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Closed Captions by Default", isOn: $settings.closedCaptionsByDefault)
                Toggle("Deinterlace (smoother 1080i)", isOn: $settings.deinterlace)
                Toggle("Hardware Decoding", isOn: $settings.hardwareDecoding)
                Toggle("Show Signal in Player", isOn: $settings.showSignalOverlay)
                Toggle("Resume Last Channel on Launch", isOn: $settings.autoplayLastChannel)
                Toggle("Background Audio", isOn: $settings.backgroundAudio)
                Picker("Skip Back", selection: $settings.skipBackSeconds) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) s").tag($0) }
                }
                Picker("Skip Forward", selection: $settings.skipForwardSeconds) {
                    ForEach([10, 15, 30, 45, 60, 75, 90], id: \.self) { Text("\($0) s").tag($0) }
                }
                VStack(alignment: .leading) {
                    Text("Home Buffer: \(settings.liveCachingMs) ms")
                    Slider(value: Binding(get: { Double(settings.liveCachingMs) }, set: { settings.liveCachingMs = Int($0) }), in: 300...5000, step: 100)
                }
                VStack(alignment: .leading) {
                    Text("Remote Buffer: \(settings.remoteCachingMs) ms")
                    Slider(value: Binding(get: { Double(settings.remoteCachingMs) }, set: { settings.remoteCachingMs = Int($0) }), in: 1000...10000, step: 250)
                }
            }

            Section("Recording") {
                Picker("Record Button Saves To", selection: $settings.recordingTarget) {
                    ForEach(RecordingTarget.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Start Early: \(settings.startPaddingSeconds / 60) min", value: $settings.startPaddingSeconds, in: 0...1800, step: 30)
                Stepper("End Late: \(settings.endPaddingSeconds / 60) min", value: $settings.endPaddingSeconds, in: 0...3600, step: 60)
                Stepper("Remind Me: \(settings.reminderMinutes) min before", value: $settings.reminderMinutes, in: 0...30)
            }

            Section {
                Picker("Guide Range", selection: $settings.guideHours) {
                    ForEach([8, 12, 24, 48], id: \.self) { Text("\($0) hours").tag($0) }
                }
                Picker("Row Height", selection: $settings.guideRowHeight) {
                    Text("Compact").tag(58.0)
                    Text("Regular").tag(72.0)
                    Text("Large").tag(88.0)
                }
                Toggle("Favorites First", isOn: $settings.favoritesFirst)
                Toggle("Hide DRM Channels", isOn: $settings.hideDRMChannels)
                Button("Refresh Guide Now") {
                    Task { await guide.load(deviceAuth: tuners.deviceAuth, hours: settings.guideHours, force: true) }
                }
            } header: {
                Text("Guide")
            } footer: {
                if let d = guide.lastUpdated { Text("Updated \(Fmt.smartDay(d)). Extended guide data requires an HDHomeRun DVR subscription.") }
            }

            Section("General") {
                Toggle("Haptic Feedback", isOn: $settings.haptics)
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
