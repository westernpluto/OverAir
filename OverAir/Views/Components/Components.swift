import SwiftUI
import UIKit

// MARK: - Theme

enum Theme {
    static let background = Color(red: 0.03, green: 0.035, blue: 0.05)
    static let card = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.08)
    static let live = Color(red: 1.0, green: 0.27, blue: 0.3)
    static let record = Color(red: 1.0, green: 0.23, blue: 0.23)

    static func color(for category: ProgramCategory) -> Color { Genre.named(category.title).color }

    static let heroGradient = LinearGradient(colors: [.clear, .black.opacity(0.3), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
}

enum Haptics {
    static func tap(_ settings: AppSettings? = nil) {
        if let settings, !settings.haptics { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

// MARK: - Glass (Liquid Glass on iOS 26+, material before)

extension View {
    /// Floating-control background: Liquid Glass where available.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    func cardStyle(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Genres (built from the guide's own categories)

/// A guide genre, e.g. "News", "Sports", "Cooking". Created from SiliconDust filter tags, so the
/// list reflects what's actually on your channels.
struct Genre: Identifiable, Hashable {
    var id: String { name }
    var name: String

    static func named(_ raw: String) -> Genre {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let canonical = aliases[trimmed.lowercased()] ?? trimmed
        return Genre(name: canonical)
    }

    private static let aliases: [String: String] = [
        "movie": "Movies", "movies": "Movies", "sports": "Sports", "sport": "Sports", "news": "News",
        "kids": "Kids", "children": "Kids", "family": "Family", "shows": "Shows", "show": "Shows",
        "talk": "Talk", "talk show": "Talk", "reality": "Reality", "documentary": "Documentary",
        "drama": "Drama", "comedy": "Comedy", "sitcom": "Comedy", "game show": "Game Shows", "game shows": "Game Shows",
        "cooking": "Cooking", "food": "Cooking", "religious": "Religious", "religion": "Religious",
        "shopping": "Shopping", "music": "Music", "educational": "Educational", "nature": "Nature",
        "science": "Science", "history": "History", "crime": "Crime", "action": "Action", "horror": "Horror",
        "spanish": "Spanish", "travel": "Travel", "weather": "Weather", "health": "Health",
        "home & garden": "Home & Garden", "home improvement": "Home & Garden", "anime": "Animation", "animated": "Animation",
        "animation": "Animation", "western": "Westerns", "soap": "Soaps", "soaps": "Soaps", "series": "Shows",
    ]

    var symbol: String {
        switch name {
        case "Movies": return "film"
        case "Sports": return "sportscourt"
        case "News": return "newspaper"
        case "Kids", "Family": return "figure.and.child.holdinghands"
        case "Talk": return "mic"
        case "Reality": return "person.2"
        case "Documentary", "Educational": return "graduationcap"
        case "Drama": return "theatermasks"
        case "Comedy": return "face.smiling"
        case "Game Shows": return "gamecontroller"
        case "Cooking": return "fork.knife"
        case "Religious": return "book.closed"
        case "Shopping": return "bag"
        case "Music": return "music.note"
        case "Nature": return "leaf"
        case "Science": return "atom"
        case "History": return "building.columns"
        case "Crime": return "magnifyingglass"
        case "Action": return "bolt"
        case "Horror": return "moon.haze"
        case "Spanish": return "globe.americas"
        case "Travel": return "airplane"
        case "Weather": return "cloud.sun"
        case "Health": return "heart"
        case "Home & Garden": return "house"
        case "Animation": return "sparkles"
        case "Westerns": return "sun.horizon"
        case "Soaps": return "drop"
        default: return "tv"
        }
    }

    var color: Color {
        switch name {
        case "Movies": return Color(red: 0.62, green: 0.4, blue: 0.95)
        case "Sports": return Color(red: 0.2, green: 0.78, blue: 0.47)
        case "News": return Color(red: 0.27, green: 0.56, blue: 1.0)
        case "Kids", "Family", "Animation": return Color(red: 1.0, green: 0.62, blue: 0.22)
        case "Cooking": return Color(red: 0.98, green: 0.45, blue: 0.35)
        case "Documentary", "Nature", "Science", "History", "Educational": return Color(red: 0.25, green: 0.75, blue: 0.75)
        case "Comedy": return Color(red: 1.0, green: 0.8, blue: 0.25)
        case "Drama", "Crime", "Horror", "Action": return Color(red: 0.9, green: 0.32, blue: 0.5)
        default:
            let palette: [Color] = [.teal, .indigo, .mint, .pink, .cyan, .orange, .purple, .green]
            let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            return palette[h % palette.count].opacity(0.9)
        }
    }
}

extension GuideProgram {
    var genres: [Genre] {
        var seen = Set<String>()
        return filters.map(Genre.named).filter { seen.insert($0.name).inserted }
    }
    var primaryGenre: Genre? { genres.first }
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

    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

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
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color.white.opacity(0.08))
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                    if case let .success(img) = phase {
                        img.resizable().scaledToFit().padding(size * 0.14)
                    } else {
                        monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
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
                .lineLimit(1)
                .minimumScaleFactor(0.6)
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
            LinearGradient(colors: [Color(white: 0.15), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.25))) { phase in
                    switch phase {
                    case let .success(img): img.resizable().scaledToFill()
                    case .failure: placeholder
                    default: Color.clear
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: fallbackSymbol).font(.title2).foregroundStyle(.white.opacity(0.25))
    }
}

struct ProgressLine: View {
    var value: Double
    var tint: Color = .accentColor
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(tint).frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct Pill: View {
    var text: String
    var color: Color = .white.opacity(0.15)
    var foreground: Color = .white
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.bold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color, in: Capsule())
        .foregroundStyle(foreground)
    }
}

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Theme.live).frame(width: 6, height: 6)
            Text("LIVE")
        }
        .font(.caption2.weight(.heavy))
        .accessibilityLabel("Live")
    }
}

struct RecordDot: View {
    var body: some View {
        Circle().fill(Theme.record).frame(width: 8, height: 8)
            .accessibilityLabel("Recording scheduled")
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
        .accessibilityElement(children: .combine)
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
        .accessibilityHidden(true)
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
        .accessibilityAddTraits(.isHeader)
    }
}

struct ConnectionBadge: View {
    var state: ConnectionState
    var body: some View {
        Label(state.title, systemImage: state.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state == .offline ? .red : state == .remote ? .cyan : .secondary)
    }
}

/// A horizontally scrolling set of selectable chips.
struct ChipBar<Item: Hashable>: View {
    var items: [Item]
    @Binding var selection: Item
    var title: (Item) -> String
    var symbol: (Item) -> String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    let on = item == selection
                    Button {
                        withAnimation(.snappy) { selection = item }
                    } label: {
                        HStack(spacing: 5) {
                            if let s = symbol(item) { Image(systemName: s).imageScale(.small) }
                            Text(title(item))
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Theme.card), in: Capsule())
                        .foregroundStyle(on ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal)
        }
        .scrollClipDisabled()
    }
}

/// Periodically ticks so "now"-based views (progress bars, now lines) stay fresh.
struct NowTicker<Content: View>: View {
    var interval: TimeInterval = 30
    @ViewBuilder var content: (Date) -> Content
    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { ctx in content(ctx.date) }
    }
}

/// Route picker for AirPlay audio / Bluetooth output.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = RoutePickerHost()
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

import AVKit
private final class RoutePickerHost: UIView {
    private let picker = AVRoutePickerView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        picker.prioritizesVideoDevices = true
        addSubview(picker)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        picker.frame = bounds
    }
}
