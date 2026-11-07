import Foundation

/// Why a stream couldn't play, in words a viewer can act on.
///
/// The HDHomeRun answers a failed tune with HTTP 503 and an `X-HDHomeRun-Error` header that names
/// the real cause (SiliconDust HTTP API): 805 all tuners in use, 807 no video (reception), 811
/// copy protected, and so on. Those codes are mapped here instead of treating every 503 as "busy".
enum PlaybackProblem: Error, Equatable, LocalizedError {
    case tunersBusy
    case deviceBusy
    case noSignal
    case signalLost
    case tuneFailed
    case copyProtected
    case unknownChannel
    case dvrFailure
    case dvrFull
    case connectionLimit
    case unreachable
    case timedOut
    case noVideo
    case unsupportedVideo(String)
    case unavailable(Int)
    case other(String)

    var title: String {
        switch self {
        case .tunersBusy: return "All Tuners Are in Use"
        case .deviceBusy: return "HDHomeRun Is Busy"
        case .noSignal: return "No Signal"
        case .signalLost: return "Signal Lost"
        case .tuneFailed: return "Couldn't Tune"
        case .copyProtected: return "Protected Channel"
        case .unknownChannel: return "Channel Not Found"
        case .dvrFailure: return "Recording Storage Problem"
        case .dvrFull: return "Recording Storage Is Full"
        case .connectionLimit: return "Too Many Streams"
        case .unreachable: return "Can't Reach Your HDHomeRun"
        case .timedOut: return "HDHomeRun Not Responding"
        case .noVideo: return "No Picture"
        case .unsupportedVideo: return "Unsupported Video"
        case .unavailable: return "Channel Unavailable"
        case .other: return "Playback Stopped"
        }
    }

    var message: String {
        switch self {
        case .tunersBusy:
            return "Every tuner is being used — by a recording, another app, or another TV in the house. Stop one, or try again in a moment."
        case .deviceBusy:
            return "The HDHomeRun is busy, usually because a channel scan is running. Try again when it finishes."
        case .noSignal:
            return "The tuner found no video on this channel. Reception is likely too weak, or the station isn't broadcasting right now. Check Signal to see the signal strength."
        case .signalLost:
            return "The tuner stopped receiving this channel. Reception may have dropped; try again or check the signal."
        case .tuneFailed:
            return "The tuner couldn't lock on to this channel. Try again; if it keeps happening, restart the HDHomeRun."
        case .copyProtected:
            return "This channel is encrypted (DRM). Broadcasters only allow certified players to show it, so it can't play in OverAir. Use the HDHomeRun app or a certified TV."
        case .unknownChannel:
            return "The HDHomeRun no longer has this channel. Rescan channels in Settings."
        case .dvrFailure:
            return "The HDHomeRun can't read or write its recording storage. Check the drive connected to it."
        case .dvrFull:
            return "The recording drive is full. Delete some recordings to free space."
        case .connectionLimit:
            return "The HDHomeRun is already streaming as many recordings as it allows. Stop playback on another device."
        case .unreachable:
            return "OverAir can't connect to the tuner. Make sure this iPhone is on your home network, or that remote access is set up."
        case .timedOut:
            return "The HDHomeRun didn't answer in time. Check that it's powered on and connected."
        case .noVideo:
            return "The tuner is sending data but there's no picture in it. The signal may be breaking up, or the channel may be off the air."
        case let .unsupportedVideo(codec):
            return "This channel uses \(codec) video, which OverAir can't play yet."
        case let .unavailable(code):
            return "The HDHomeRun couldn't start this channel (error \(code)). The usual causes are weak reception, all tuners in use, or a protected channel."
        case let .other(message):
            return message
        }
    }

    /// A short label for small spaces such as multiview tiles.
    var shortTitle: String {
        switch self {
        case .tunersBusy: return "Tuners busy"
        case .noSignal, .noVideo, .signalLost: return "No signal"
        case .copyProtected: return "Protected"
        case .unreachable, .timedOut: return "Can't connect"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .tunersBusy, .deviceBusy, .connectionLimit: return "rectangle.stack.badge.person.crop"
        case .noSignal, .noVideo, .tuneFailed, .signalLost: return "antenna.radiowaves.left.and.right.slash"
        case .copyProtected: return "lock.fill"
        case .unreachable, .timedOut: return "wifi.exclamationmark"
        case .dvrFailure, .dvrFull: return "externaldrive.badge.exclamationmark"
        default: return "exclamationmark.triangle.fill"
        }
    }

    /// Whether checking signal strength is the useful next step.
    var suggestsSignalCheck: Bool {
        switch self {
        case .noSignal, .noVideo, .tuneFailed, .unavailable, .signalLost: return true
        default: return false
        }
    }

    /// Whether trying again could help.
    var isRetryable: Bool {
        switch self {
        case .copyProtected, .unknownChannel, .unsupportedVideo, .dvrFull: return false
        default: return true
        }
    }

    var errorDescription: String? { message }

    /// Interprets a failed HTTP response from an HDHomeRun.
    static func fromHTTP(status: Int, hdhomerunError header: String?) -> PlaybackProblem {
        let code = header.flatMap { Int($0.prefix(while: \.isNumber)) }
        switch code {
        case 801?: return .unknownChannel
        case 803?: return .deviceBusy
        case 804?, 805?: return .tunersBusy
        case 806?: return .tuneFailed
        case 807?: return .noSignal
        case 808?: return .dvrFailure
        case 809?: return .connectionLimit
        case 810?: return .dvrFull
        case 811?: return .copyProtected
        default: break
        }
        switch status {
        case 404: return .unknownChannel
        case 503: return .unavailable(code ?? 503)
        default: return .other("The tuner returned an error (HTTP \(status)\(code.map { ", code \($0)" } ?? "")).")
        }
    }

    /// Interprets a networking error.
    static func from(_ error: Error) -> PlaybackProblem {
        if let p = error as? PlaybackProblem { return p }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return .timedOut
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed:
                return .unreachable
            default: break
            }
        }
        return .other(error.localizedDescription)
    }
}
