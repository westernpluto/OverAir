import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A file-backed ring buffer of transport-stream bytes addressed by absolute stream offset.
/// Live TV is written here continuously, which is what makes pause / rewind / instant replay possible.
final class StreamStore: @unchecked Sendable {
    let capacity: Int64
    private let lock = NSCondition()
    private let handle: FileHandle
    private let url: URL
    private(set) var start: Int64 = 0      // oldest byte still available
    private(set) var end: Int64 = 0        // one past the newest byte
    private(set) var finished = false      // source ended (EOF / error)
    private(set) var failure: Error?

    /// (absolute offset, 90 kHz PTS) samples of video PES starts, for seeking by time.
    private var index: [(offset: Int64, pts: Int64)] = []
    private var lastIndexPTS: Int64 = .min

    init(capacity: Int64) throws {
        self.capacity = max(capacity, 8 << 20)
        url = FileManager.default.temporaryDirectory.appendingPathComponent("timeshift-\(UUID().uuidString).ts")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forUpdating: url)
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    func reset(at offset: Int64) {
        lock.lock()
        start = offset; end = offset
        finished = false; failure = nil
        index.removeAll(); lastIndexPTS = .min
        lock.unlock()
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        var written = 0
        data.withUnsafeBytes { raw in
            while written < raw.count {
                let pos = (end + Int64(written)) % capacity
                let n = min(raw.count - written, Int(capacity - pos))
                try? handle.seek(toOffset: UInt64(pos))
                handle.write(Data(raw[written..<(written + n)]))
                written += n
            }
        }
        end += Int64(data.count)
        if end - start > capacity {
            start = end - capacity
            if let firstValid = index.firstIndex(where: { $0.offset >= start }) {
                index.removeFirst(firstValid)
            } else {
                index.removeAll()
            }
        }
        lock.broadcast()
        lock.unlock()
    }

    func markFinished(_ error: Error?) {
        lock.lock()
        finished = true
        failure = error
        lock.broadcast()
        lock.unlock()
    }

    /// Reads up to `max` bytes at `offset`, waiting up to `timeout` for data to arrive.
    /// Returns nil when no data is available (yet); an empty array at end of stream.
    func read(at offset: Int64, max: Int, timeout: TimeInterval) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while offset >= end && !finished {
            if !lock.wait(until: deadline) { return nil }
        }
        if offset >= end { return finished ? [] : nil }
        let from = Swift.max(offset, start)
        let count = Int(Swift.min(Int64(max), end - from))
        var out = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let pos = (from + Int64(done)) % capacity
            let n = Swift.min(count - done, Int(capacity - pos))
            try? handle.seek(toOffset: UInt64(pos))
            if let chunk = try? handle.read(upToCount: n), !chunk.isEmpty {
                let start = done
                out.withUnsafeMutableBytes { raw in
                    _ = chunk.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: raw[start..<(start + chunk.count)]))
                }
                done += chunk.count
                if chunk.count < n { break }
            } else {
                break
            }
        }
        return Array(out[0..<done])
    }

    // MARK: Time index

    func addIndex(offset: Int64, pts: Int64) {
        lock.lock()
        if pts > lastIndexPTS + 45_000 || pts < lastIndexPTS - 900_000 { // every ~0.5 s (or after a jump)
            index.append((offset, pts))
            lastIndexPTS = pts
        }
        lock.unlock()
    }

    /// Byte offset of the last index point at or before `pts`.
    func offset(forPTS pts: Int64) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard !index.isEmpty else { return nil }
        var best = index[0]
        for e in index where e.pts <= pts { best = e }
        return best.offset
    }

    var ptsRange: (oldest: Int64, newest: Int64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let f = index.first, let l = index.last else { return nil }
        return (f.pts, l.pts)
    }

    var bufferedBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return end - start
    }
}

/// Streams an HTTP URL into a `StreamStore`, optionally from a byte offset (HTTP Range).
final class NetworkFeeder: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let store: StreamStore
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private(set) var totalLength: Int64?
    private(set) var bytesPerSecond: Double = 0
    private var meterStart = Date()
    private var meterBytes: Int64 = 0
    var onIndexBytes: ((Data, Int64) -> Void)?
    private var writeOffset: Int64 = 0

    init(store: StreamStore) {
        self.store = store
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60 * 60 * 24
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func start(url: URL, from offset: Int64 = 0) {
        task?.cancel()
        store.reset(at: offset)
        writeOffset = offset
        var request = URLRequest(url: url)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let t = session.dataTask(with: request)
        task = t
        meterStart = Date(); meterBytes = 0
        t.resume()
    }

    func stop() {
        task?.cancel()
        task = nil
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === task else { completionHandler(.cancel); return }
        if let http = response as? HTTPURLResponse {
            if !(200..<300).contains(http.statusCode) {
                let reason = http.statusCode == 503 ? "All tuners are busy." : "The tuner returned HTTP \(http.statusCode)."
                store.markFinished(HTTPError.unreachable(reason))
                completionHandler(.cancel)
                return
            }
            if http.statusCode == 200 && writeOffset > 0 {
                // Server ignored the range request; start from zero.
                store.reset(at: 0)
                writeOffset = 0
            }
            let len = http.expectedContentLength
            if len > 0 { totalLength = writeOffset + len }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task else { return }
        onIndexBytes?(data, writeOffset)
        store.append(data)
        writeOffset += Int64(data.count)
        meterBytes += Int64(data.count)
        let elapsed = Date().timeIntervalSince(meterStart)
        if elapsed > 2 {
            bytesPerSecond = Double(meterBytes) / elapsed
            meterStart = Date(); meterBytes = 0
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        if let error = error as NSError?, error.code == NSURLErrorCancelled { return }
        store.markFinished(error)
    }
}

/// Watches bytes as they are written and records (offset, PTS) of video PES starts,
/// so any point in the timeshift buffer can be found by time.
final class StreamIndexer: @unchecked Sendable {
    private let store: StreamStore
    private var carry: [UInt8] = []
    private var carryOffset: Int64 = 0
    private var pmtPID: Int?
    private var videoPID: Int?

    init(store: StreamStore) { self.store = store }

    func consume(_ data: Data, at offset: Int64) {
        var bytes = carry
        let base = offset - Int64(carry.count)
        bytes.append(contentsOf: data)
        var i = 0
        // Align to packet boundary.
        while i < bytes.count && bytes[i] != 0x47 { i += 1 }
        while i + 188 <= bytes.count {
            if bytes[i] == 0x47 { scan(bytes, i, absolute: base + Int64(i)) ; i += 188 } else { i += 1 }
        }
        carry = Array(bytes[i...])
        carryOffset = base + Int64(i)
    }

    private func scan(_ b: [UInt8], _ i: Int, absolute: Int64) {
        let pusi = b[i + 1] & 0x40 != 0
        let pid = (Int(b[i + 1] & 0x1F) << 8) | Int(b[i + 2])
        guard pusi else { return }
        let afc = (b[i + 3] >> 4) & 0x3
        var p = i + 4
        if afc & 0x2 != 0 { p += 1 + Int(b[i + 4]) }
        guard afc & 0x1 != 0, p < i + 188 else { return }
        if pid == 0 {
            // PAT → PMT PID
            let ptr = Int(b[p]); let s = p + 1 + ptr
            guard s + 12 < i + 188, b[s] == 0x00 else { return }
            let entry = s + 8
            let mapPID = (Int(b[entry + 2] & 0x1F) << 8) | Int(b[entry + 3])
            pmtPID = mapPID
        } else if pid == pmtPID {
            let ptr = Int(b[p]); let s = p + 1 + ptr
            guard s + 12 < i + 188, b[s] == 0x02 else { return }
            let infoLen = ((Int(b[s + 10]) & 0x0F) << 8) | Int(b[s + 11])
            var e = s + 12 + infoLen
            while e + 5 <= i + 188 {
                let type = b[e]
                let epid = (Int(b[e + 1] & 0x1F) << 8) | Int(b[e + 2])
                if [0x01, 0x02, 0x1B, 0x24].contains(type) { videoPID = epid; break }
                e += 5 + (((Int(b[e + 3]) & 0x0F) << 8) | Int(b[e + 4]))
            }
        } else if pid == videoPID {
            guard p + 14 <= i + 188, b[p] == 0, b[p + 1] == 0, b[p + 2] == 1, b[p + 7] & 0x80 != 0 else { return }
            let pts = TSDemuxer.timestamp(Array(b[(p + 9)..<(p + 14)]), 0)
            store.addIndex(offset: absolute, pts: pts)
        }
    }
}
