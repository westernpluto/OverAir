import SwiftUI
import UIKit

/// Shows a TVPlayer's video layer in SwiftUI. The layer view is owned by the player, so it is
/// never recreated when SwiftUI re-renders.
struct TVVideoView: UIViewRepresentable {
    let player: TVPlayer

    func makeUIView(context: Context) -> HostView {
        let host = HostView()
        host.attach(player.videoView)
        return host
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        uiView.attach(player.videoView)
    }

    final class HostView: UIView {
        private weak var content: UIView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        func attach(_ view: UIView) {
            guard view.superview !== self else { return }
            view.removeFromSuperview()
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
            content = view
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            content?.frame = bounds
        }
    }
}
