import SwiftUI
import UIKit
import AVKit

/// Hosts the shared libVLC drawable inside SwiftUI.
struct VideoSurface: UIViewRepresentable {
    let player: PlayerController

    func makeUIView(context: Context) -> ContainerView {
        let v = ContainerView()
        v.player = player
        v.backgroundColor = .black
        v.attach()
        return v
    }

    func updateUIView(_ uiView: ContainerView, context: Context) {
        uiView.player = player
        uiView.attach()
    }

    final class ContainerView: UIView {
        weak var player: PlayerController?

        func attach() {
            guard let player else { return }
            let video = player.videoView
            if video.superview !== self {
                video.removeFromSuperview()
                video.frame = bounds
                video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                addSubview(video)
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { attach() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            player?.videoView.frame = bounds
            player?.containerSize = bounds.size
        }
    }
}

/// Route picker for AirPlay audio / Bluetooth output.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = AVRoutePickerViewWrapper()
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

final class AVRoutePickerViewWrapper: UIView {
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
