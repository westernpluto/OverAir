import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Records a live stream straight onto the iPhone (MPEG-TS), independent of
/// HDHomeRun storage. Great for taking shows offline on a flight.
@MainActor
@Observable
final class LocalRecorder: NSObject {
    struct Active: Identifiable {
        let id: UUID
        var recording: LocalRecording
        var bytes: Int64
        var stopAt: Date?
    }

    private(set) var recordings: [LocalRecording] = []
    private(set) var active: [UUID: Active] = [:]
    var lastError: String?

    @ObservationIgnored private var tasks: [Int: UUID] = [:]
    @ObservationIgnored private var handles: [UUID: FileHandle] = [:]
    @ObservationIgnored private var stopTimers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastPublish: [UUID: Date] = [:]
    @ObservationIgnored private var pendingBytes: [UUID: Int64] = [:]
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60 * 12
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    @ObservationIgnored private var sessionTasks: [UUID: URLSessionDataTask] = [:]
    #if canImport(UIKit)
    @ObservationIgnored private var bgTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    override init() {
        super.init()
        recordings = Persistence.load([LocalRecording].self, from: "localRecordings") ?? []
        recordings.removeAll { !FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    var isRecordingAnything: Bool { !active.isEmpty }

    func isRecording(channel: String) -> Bool { active.values.contains { $0.recording.channelNumber == channel } }

    func start(url: URL, channel: Channel, program: GuideProgram?, until: Date?) {
        let id = UUID()
        let safeTitle = (program?.title ?? channel.name).replacingOccurrences(of: "/", with: "-")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HHmm"
        let fileName = "\(safeTitle) \(df.string(from: Date())) \(id.uuidString.prefix(4)).ts"
        let rec = LocalRecording(id: id, title: program?.title ?? channel.name, subtitle: program?.subtitleLine,
                                 channelNumber: channel.number, channelName: channel.name,
                                 imageURL: program?.imageURL, started: Date(), ended: nil,
                                 fileName: fileName, bytes: 0, resumeSeconds: nil)
        FileManager.default.createFile(atPath: rec.fileURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: rec.fileURL) else {
            lastError = "Couldn't create a file for the recording."
            return
        }
        handles[id] = handle
        active[id] = Active(id: id, recording: rec, bytes: 0, stopAt: until)
        let task = session.dataTask(with: url)
        tasks[task.taskIdentifier] = id
        sessionTasks[id] = task
        task.resume()
        beginBackgroundTask()

        if let until {
            stopTimers[id] = Task { [weak self] in
                let delay = until.timeIntervalSinceNow
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard !Task.isCancelled else { return }
                self?.stop(id)
            }
        }
    }

    func stop(_ id: UUID) {
        sessionTasks[id]?.cancel()
        finish(id)
    }

    func stopAll() { for id in active.keys { stop(id) } }

    func delete(_ rec: LocalRecording) {
        try? FileManager.default.removeItem(at: rec.fileURL)
        recordings.removeAll { $0.id == rec.id }
        save()
    }

    func saveResume(_ rec: LocalRecording, seconds: Double) {
        guard let i = recordings.firstIndex(where: { $0.id == rec.id }) else { return }
        recordings[i].resumeSeconds = seconds
        save()
    }

    private func finish(_ id: UUID) {
        guard var a = active.removeValue(forKey: id) else { return }
        stopTimers.removeValue(forKey: id)?.cancel()
        try? handles.removeValue(forKey: id)?.close()
        sessionTasks.removeValue(forKey: id)
        let size = (try? FileManager.default.attributesOfItem(atPath: a.recording.fileURL.path)[.size] as? NSNumber)?.int64Value ?? a.bytes
        a.recording.ended = Date()
        a.recording.bytes = size
        if size > 0 {
            recordings.insert(a.recording, at: 0)
            save()
        } else {
            try? FileManager.default.removeItem(at: a.recording.fileURL)
            lastError = "The recording didn't receive any data. All tuners may be busy."
        }
        if active.isEmpty { endBackgroundTask() }
    }

    private func save() { Persistence.save(recordings, as: "localRecordings") }

    fileprivate func received(_ data: Data, taskID: Int) {
        guard let id = tasks[taskID], let handle = handles[id] else { return }
        handle.write(data)
        pendingBytes[id, default: 0] += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(lastPublish[id] ?? .distantPast) > 1 {
            lastPublish[id] = now
            active[id]?.bytes += pendingBytes[id] ?? 0
            pendingBytes[id] = 0
        }
    }

    fileprivate func completed(taskID: Int, error: Error?) {
        guard let id = tasks.removeValue(forKey: taskID) else { return }
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            lastError = "Recording stopped: \(error.localizedDescription)"
        }
        finish(id)
    }

    private func beginBackgroundTask() {
        #if canImport(UIKit)
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "LocalRecording") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        #endif
    }

    private func endBackgroundTask() {
        #if canImport(UIKit)
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        #endif
    }
}

extension LocalRecorder: URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let taskID = dataTask.taskIdentifier
        Task { @MainActor in self.received(data, taskID: taskID) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskID = task.taskIdentifier
        let err = error
        Task { @MainActor in self.completed(taskID: taskID, error: err) }
    }
}
