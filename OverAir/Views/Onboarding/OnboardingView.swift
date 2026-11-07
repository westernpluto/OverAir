import SwiftUI

struct OnboardingView: View {
    @Environment(TunerStore.self) private var tuners
    @Environment(AppSettings.self) private var settings
    @Environment(GuideStore.self) private var guide
    @State private var showManual = false
    @State private var started = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                ZStack {
                    ForEach(0..<3) { i in
                        Circle()
                            .stroke(Color.accentColor.opacity(0.35 - Double(i) * 0.1), lineWidth: 2)
                            .frame(width: CGFloat(110 + i * 60), height: CGFloat(110 + i * 60))
                            .scaleEffect(tuners.isDiscovering ? 1.08 : 0.95)
                            .animation(.easeInOut(duration: 1.2).repeatForever().delay(Double(i) * 0.2), value: tuners.isDiscovering)
                    }
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(height: 240)

                VStack(spacing: 10) {
                    Text("Welcome to OverAir").font(.largeTitle.weight(.bold))
                    Text("Free over-the-air TV from your HDHomeRun, everywhere you go.")
                        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                if tuners.isDiscovering {
                    VStack(spacing: 8) {
                        ProgressView(value: tuners.discoveryProgress).frame(maxWidth: 260)
                        Text(tuners.discoveryPhase).font(.footnote).foregroundStyle(.secondary)
                    }
                } else if !tuners.devices.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(tuners.devices) { d in DeviceRow(device: d, selected: d.id == tuners.selectedTuner?.id).cardStyle(padding: 12) }
                        Button {
                            settings.onboardingComplete = true
                            Task { await guide.load(deviceAuth: tuners.deviceAuth, hours: settings.guideHours, force: true) }
                        } label: {
                            Text("Start Watching").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 30)
                } else if started, let e = tuners.lastError {
                    Text(e).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center).padding(.horizontal, 30)
                }

                Spacer()

                VStack(spacing: 12) {
                    if !tuners.isDiscovering && tuners.devices.isEmpty {
                        Button {
                            started = true
                            Task { await tuners.discover() }
                        } label: {
                            Text(started ? "Search Again" : "Find My HDHomeRun").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Enter Address Manually") { showManual = true }
                        .font(.subheadline)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 20)
            }
            .navigationDestination(isPresented: $showManual) { AddDeviceView() }
            .task {
                if !started {
                    started = true
                    await tuners.discover()
                }
            }
        }
    }
}
