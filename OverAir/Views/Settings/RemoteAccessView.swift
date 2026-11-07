import SwiftUI
import UIKit

/// A guided setup for watching away from home. The HDHomeRun has no cloud relay, so the phone
/// needs a private route home. OverAir does the rest automatically: it remembers your tuner's
/// home address and simply uses it whenever that route is up — nothing to type in the app.
struct RemoteAccessView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TunerStore.self) private var tuners

    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var newHost = ""
    @State private var detecting = false
    @State private var copied = false

    private var tuner: HDHRDevice? { tuners.selectedTuner }
    private var tunerIP: String { tuner?.baseURL.host ?? "your HDHomeRun's IP" }
    private var subnet: String { NetworkInfo.homeSubnet(of: tuner) ?? "192.168.1.0/24" }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section { statusCard }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

            Section {
                ForEach([RemoteMethod.tailscale, .routerVPN, .portForward]) { method in
                    Button {
                        withAnimation { settings.remoteMethod = method }
                    } label: { methodRow(method) }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("How will you connect?")
            } footer: {
                Text("Your HDHomeRun only talks to devices on your home network, so your iPhone needs a secure path home. Pick one — you only do this once.")
            }

            switch settings.remoteMethod {
            case .tailscale: tailscaleSteps
            case .routerVPN: routerVPNSteps
            case .portForward: portForwardSteps
            case .none: EmptyView()
            }

            if settings.remoteMethod != .none {
                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Label("Test Connection", systemImage: "checkmark.shield")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing)
                    if let testResult {
                        Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(testResult.ok ? .green : .orange)
                            .font(.subheadline)
                    }
                } footer: {
                    Text("To test properly, turn off Wi-Fi so your iPhone uses cellular, then tap Test Connection.")
                }
            }

            Section {
                Label("Live TV uses about 4–9 GB per hour (8–20 Mbps). Your home internet upload speed needs to keep up, and a cellular plan with plenty of data helps.",
                      systemImage: "antenna.radiowaves.left.and.right")
                    .font(.footnote)
            } header: {
                Text("Good to Know")
            }

            Section {
                Picker("Connect Using", selection: $settings.networkProfile) {
                    Text("Automatic").tag(NetworkProfile.automatic)
                    Text("Home Network Only").tag(NetworkProfile.local)
                    Text("Away Address Only").tag(NetworkProfile.remote)
                }
                ForEach(settings.remoteHosts, id: \.self) { h in Label(h, systemImage: "globe") }
                    .onDelete { settings.remoteHosts.remove(atOffsets: $0) }
                HStack {
                    TextField("Add an address (IP or hostname)", text: $newHost)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Add") {
                        let host = newHost
                        Task {
                            do {
                                _ = try await tuners.addManualDevice(host: host, remote: true)
                                newHost = ""
                                testResult = (true, "Connected through \(host).")
                            } catch {
                                testResult = (false, error.localizedDescription)
                            }
                        }
                    }
                    .disabled(newHost.isEmpty)
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Only needed if your tuner is reachable at a different address when you're away (for example a Tailscale MagicDNS name or a dynamic DNS name).")
            }
        }
        .navigationTitle("Away From Home")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Status

    private var statusCard: some View {
        let (symbol, color, title, detail) = status
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title).foregroundStyle(color).frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var status: (String, Color, String, String) {
        let atHome = NetworkInfo.isOnLAN(of: tuner)
        switch tuners.connection {
        case .local where atHome:
            return ("house.fill", .green, "You're home", "Streaming straight from your HDHomeRun at \(tunerIP).")
        case .remote:
            let via = NetworkInfo.isTailscaleActive ? "Tailscale" : (NetworkInfo.isVPNActive ? "your VPN" : "your away address")
            return ("globe.americas.fill", .cyan, "Connected from away", "Reaching your HDHomeRun through \(via).")
        case .connecting:
            return ("antenna.radiowaves.left.and.right", .secondary, "Connecting…", "Looking for your HDHomeRun.")
        default:
            if settings.remoteMethod == .none {
                return ("globe", .secondary, "Not set up yet", "Choose a method below to watch live TV and recordings anywhere.")
            }
            return ("wifi.exclamationmark", .orange, "Can't reach your tuner", NetworkInfo.isVPNActive
                    ? "Your VPN is on, but it isn't routing to your home network yet."
                    : "Turn on \(settings.remoteMethod == .tailscale ? "Tailscale" : "your VPN") on this iPhone, then try again.")
        }
    }

    private func methodRow(_ m: RemoteMethod) -> some View {
        let selected = settings.remoteMethod == m
        let (symbol, subtitle): (String, String) = {
            switch m {
            case .tailscale: return ("lock.shield.fill", "Recommended. Free, private and secure. No router changes.")
            case .routerVPN: return ("wifi.router.fill", "Use the VPN built into your router (UniFi, ASUS, eero, Firewalla…).")
            case .portForward: return ("exclamationmark.shield.fill", "No extra apps, but anyone who finds your address could watch.")
            case .none: return ("globe", "")
            }
        }()
        return HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(m == .portForward ? .orange : Color.accentColor).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(m.title).font(.body.weight(.semibold))
                    if m == .tailscale { Pill(text: "EASIEST", color: .green.opacity(0.6)) }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Steps

    private var tailscaleSteps: some View {
        Section {
            step(1, done: NetworkInfo.isTailscaleActive,
                 "Install Tailscale on this iPhone and sign in.",
                 detail: NetworkInfo.isTailscaleActive ? "Tailscale is connected on this iPhone." : nil) {
                Link(destination: URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!) {
                    Label("Get Tailscale", systemImage: "arrow.down.app")
                }
            }
            step(2, done: false,
                 "Install Tailscale on something that stays at home and is always on — an Apple TV, Mac, Windows PC, Raspberry Pi or NAS — using the same account.")
            step(3, done: false,
                 "On that device, turn on Tailscale's subnet router and share your home network:",
                 detail: "Mac, PC or Pi: tailscale set --advertise-routes=\(subnet)") {
                Button {
                    UIPasteboard.general.string = subnet
                    copied = true
                } label: {
                    Label(copied ? "Copied \(subnet)" : "Copy \(subnet)", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
            step(4, done: false, "Approve the shared network in the Tailscale admin console.") {
                Link(destination: URL(string: "https://login.tailscale.com/admin/machines")!) {
                    Label("Open Admin Console", systemImage: "safari")
                }
            }
            step(5, done: tuners.connection == .remote,
                 "Done. When you're away, keep Tailscale on and OverAir connects to \(tunerIP) automatically.")
        } header: {
            Text("Set Up Tailscale")
        }
    }

    private var routerVPNSteps: some View {
        Section {
            step(1, done: false, "In your router's app, turn on its VPN server. WireGuard is fastest.")
            step(2, done: false, "Add this iPhone as a VPN client. Most routers show a QR code you scan with the WireGuard app.") {
                Link(destination: URL(string: "https://apps.apple.com/app/wireguard/id1441195209")!) {
                    Label("Get WireGuard", systemImage: "arrow.down.app")
                }
            }
            step(3, done: false, "Set the VPN to connect on demand, or switch it on when you leave home.")
            step(4, done: tuners.connection == .remote,
                 "Done. OverAir connects to \(tunerIP) through the VPN automatically.",
                 detail: NetworkInfo.isVPNActive ? "A VPN is active on this iPhone right now." : nil)
        } header: {
            Text("Set Up Your Router's VPN")
        }
    }

    private var portForwardSteps: some View {
        Section {
            Label("Anyone who learns your address could watch live TV and see your recordings. Tailscale is safer.", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
            step(1, done: false, "In your router, forward these ports to \(tunerIP):",
                 detail: "TCP 80 → \(tunerIP):80\nTCP 5004 → \(tunerIP):5004\(tuners.storageDevices.contains(where: { $0.baseURL.port == 59090 }) ? "\nTCP 59090 → your DVR:59090" : "")")
            step(2, done: settings.homePublicIP != nil,
                 "OverAir remembers your home's internet address automatically whenever you use it at home.",
                 detail: settings.homePublicIP.map { "Your home address: \($0)" } ?? "Not detected yet — open OverAir once while at home.") {
                if NetworkInfo.isOnLAN(of: tuner) {
                    Button {
                        detecting = true
                        Task {
                            settings.homePublicIPUpdated = nil
                            await tuners.refreshHomePublicIP()
                            detecting = false
                        }
                    } label: {
                        HStack { Label("Detect Now", systemImage: "location.magnifyingglass"); if detecting { ProgressView() } }
                    }
                }
            }
            step(3, done: tuners.connection == .remote, "Done. When you're away, OverAir connects through your home address automatically.")
        } header: {
            Text("Set Up Port Forwarding")
        }
    }

    private func step(_ n: Int, done: Bool, _ text: String, detail: String? = nil) -> some View {
        step(n, done: done, text, detail: detail) { EmptyView() }
    }

    private func step<Accessory: View>(_ n: Int, done: Bool, _ text: String, detail: String? = nil,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor.opacity(0.25)).frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.caption.weight(.bold))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.subheadline)
                if let detail {
                    Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                accessory().font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
    }

    private func test() async {
        testing = true
        defer { testing = false }
        await tuners.connect()
        switch tuners.connection {
        case .remote:
            testResult = (true, "It works! You're connected from away.")
        case .local:
            testResult = NetworkInfo.isOnLAN(of: tuner)
                ? (true, "Connected at home. Turn off Wi-Fi and test again to check away-from-home access.")
                : (true, "Connected.")
        default:
            testResult = (false, tuners.lastError ?? "Couldn't reach your HDHomeRun.")
        }
    }
}
