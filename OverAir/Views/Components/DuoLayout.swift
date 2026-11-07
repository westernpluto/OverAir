import SwiftUI

// Layout helpers that follow Apple's "Preparing your app for iPhone Duo" guidance:
// - prefer system containers (TabView .sidebarAdaptable, NavigationStack toolbars)
// - use ArrangementView for two related views around the fold
// - read reserved regions (the fold / camera) only in custom-positioned views
// - grids use an even number of columns so content divides cleanly at the fold

/// Places `primary` (controls) over `secondary` (video) on a flat display. When iPhone Duo is
/// partially folded the system moves them to opposite sides of the fold — video on one half,
/// controls on the other. On iOS versions before 27.1 it is a plain ZStack.
struct FoldAwareOverlay<Primary: View, Secondary: View>: View {
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary

    var body: some View {
        if #available(iOS 27.1, *) {
            ArrangementView {
                primary
            } secondary: {
                secondary
            }
            .arrangementViewStyle(.overlay)
        } else {
            ZStack {
                secondary
                primary
            }
        }
    }
}

/// Places two views side by side (landscape) or stacked (portrait), keeping each clear of the
/// fold. Only shows `primary` when there isn't room for both.
struct FoldAwareSplit<Primary: View, Secondary: View>: View {
    var primaryRatio: CGFloat = 0.6
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary

    var body: some View {
        if #available(iOS 27.1, *) {
            ArrangementView {
                primary.splitArrangementLayoutRatio(primaryRatio)
            } secondary: {
                secondary
            }
            .arrangementViewStyle(.split)
        } else {
            GeometryReader { proxy in
                if proxy.size.width > proxy.size.height {
                    HStack(spacing: 0) {
                        primary.frame(width: proxy.size.width * primaryRatio)
                        secondary
                    }
                } else {
                    VStack(spacing: 0) {
                        primary.frame(height: proxy.size.height * primaryRatio)
                        secondary
                    }
                }
            }
        }
    }
}

enum Fold {
    /// The active fold (division) inside the proxy's view, in its local coordinates.
    static func division(in proxy: GeometryProxy) -> CGRect? {
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division).first?.frame
        }
        return nil
    }

    /// How far content at the top of the view must move down to clear the camera / Dynamic Island.
    static func topOcclusion(in proxy: GeometryProxy, barHeight: CGFloat) -> CGFloat {
        if #available(iOS 27.1, *) {
            let bar = CGRect(x: 0, y: 0, width: proxy.size.width, height: barHeight)
            return proxy.reservedRegions(kind: .occlusion)
                .filter { $0.frame.intersects(bar) }
                .map(\.frame.maxY)
                .max() ?? 0
        }
        return 0
    }

    /// An even column count for grids, so items divide cleanly at the fold.
    static func evenColumns(for width: CGFloat, minimumItemWidth: CGFloat) -> Int {
        let raw = max(1, Int(width / minimumItemWidth))
        if raw == 1 { return 1 }
        return raw % 2 == 0 ? raw : raw - 1
    }
}

extension EnvironmentValues {
    /// True while iPhone Duo is partially folded and the player's controls sit beside the video.
    @Entry var playerControlsSeparated: Bool = false
}

extension View {
    /// On wide displays (iPhone Duo open, iPad) present detail sheets at the trailing edge so the
    /// content they came from — the guide grid, the channel list — stays visible beside them.
    @ViewBuilder
    func detailSheetPlacement() -> some View {
        if #available(iOS 27.0, *) {
            self.presentationPlacement(.trailing)
        } else {
            self
        }
    }
}
