import SwiftUI
import UIKit

// MARK: - Theme

enum Theme {
    static let accent = Color.accentColor
    static let background = Color(red: 0.035, green: 0.04, blue: 0.06)
    static let card = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.08)
    static let live = Color(red: 1.0, green: 0.23, blue: 0.27)
    static let record = Color(red: 1.0, green: 0.2, blue: 0.2)

    static func color(for category: ProgramCategory) -> Color {
        switch category {
        case .movie: return Color(red: 0.62, green: 0.38, blue: 0.95)
        case .sports: return Color(red: 0.2, green: 0.78, blue: 0.45)
        case .news: return Color(red: 0.25, green: 0.55, blue: 1.0)
        case .kids: return Color(red: 1.0, green: 0.62, blue: 0.2)
        case .show, .all: return Color(red: 0.45, green: 0.5, blue: 0.6)
        }
    }

    static let heroGradient = LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
}

enum Haptics {
    static func tap(_ settings: AppSettings? = nil) {
        if let settings, !settings.haptics { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

// MARK: - Formatting

enum Fmt {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE MMM d jmm")
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE MMM d")
        return f
    }()

    static func range(_ start: Date, _ end: Date) -> String {
        "\(time.string(from: start)) – \(time.string(from: end))"
    }

    static func smartDay(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today \(time.string(from: date))" }
        if cal.isDateInTomorrow(date) { return "Tomorrow \(time.string(from: date))" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time.string(from: date))" }
        return dayTime.string(from: date)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(max(m, 1))m"
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func remaining(until end: Date) -> String {
        let s = end.timeIntervalSinceNow
        return s <= 0 ? "Ending" : "\(duration(s)) left"
    }
}

// MARK: - Views

struct ChannelLogo: View {
    var url: URL?
    var number: String
    var name: String
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                    switch phase {
                    case let .success(img): img.resizable().scaledToFit().padding(size * 0.14)
                    default: monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).stroke(Theme.cardStroke, lineWidth: 0.5))
    }

    private var monogram: some View {
        VStack(spacing: 0) {
            Text(String(name.prefix(4)).uppercased())
                .font(.system(size: size * 0.24, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(number)
                .font(.system(size: size * 0.2, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(4)
    }
}

struct Artwork: View {
    var url: URL?
    var fallbackSymbol: String = "tv"
    var cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.25))) { phase in
                    switch phase {
                    case let .success(img): img.resizable().scaledToFill()
                    case .failure: placeholder
                    default: ProgressView().tint(.white.opacity(0.4))
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        Image(systemName: fallbackSymbol)
            .font(.title)
            .foregroundStyle(.white.opacity(0.25))
    }
}

struct ProgressLine: View {
    var value: Double
    var tint: Color = .accentColor
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(tint).frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

struct Pill: View {
    var text: String
    var color: Color = .white.opacity(0.15)
    var foreground: Color = .white
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(color, in: Capsule())
        .foregroundStyle(foreground)
    }
}

struct LiveBadge: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Theme.live).frame(width: 6, height: 6)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(), value: pulse)
            Text("LIVE").font(.system(size: 10, weight: .heavy, design: .rounded))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
        .onAppear { pulse = true }
    }
}

struct RecordDot: View {
    var body: some View {
        Circle().fill(Theme.record).frame(width: 8, height: 8)
            .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
    }
}

struct SignalMeter: View {
    var label: String
    var value: Int?

    var color: Color {
        guard let value else { return .gray }
        switch value {
        case 80...: return .green
        case 60..<80: return .yellow
        case 40..<60: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value.map { "\($0)%" } ?? "—").font(.caption.monospacedDigit().weight(.semibold))
            }
            ProgressLine(value: Double(value ?? 0) / 100, tint: color, height: 6)
        }
    }
}

struct SignalBars: View {
    var percent: Int?
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Double(percent ?? 0) > Double(i) * 25 ? Color.white : Color.white.opacity(0.25))
                    .frame(width: 3, height: CGFloat(4 + i * 3))
            }
        }
    }
}

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.bold))
            if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CategoryChips: View {
    @Binding var selection: ProgramCategory

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ProgramCategory.allCases) { cat in
                    Button {
                        withAnimation(.snappy) { selection = cat }
                    } label: {
                        Label(cat.title, systemImage: cat.symbol)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(selection == cat ? AnyShapeStyle(cat == .all ? Color.accentColor : Theme.color(for: cat)) : AnyShapeStyle(Theme.card), in: Capsule())
                            .foregroundStyle(selection == cat ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}

struct ConnectionBadge: View {
    var state: ConnectionState
    var body: some View {
        Label(state.title, systemImage: state.symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.card, in: Capsule())
            .foregroundStyle(state == .offline ? .red : state == .remote ? .cyan : .secondary)
    }
}

extension View {
    func cardStyle(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.cardStroke, lineWidth: 0.5))
    }
}

/// Periodically ticks so "now" based views (progress bars, now lines) stay fresh.
struct NowTicker<Content: View>: View {
    var interval: TimeInterval = 30
    @ViewBuilder var content: (Date) -> Content
    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { ctx in content(ctx.date) }
    }
}
