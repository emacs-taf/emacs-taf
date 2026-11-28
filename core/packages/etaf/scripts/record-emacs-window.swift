// Record only the owned Emacs frame.  Build with swiftc -parse-as-library.
import Foundation
import CoreGraphics
import ScreenCaptureKit
import AVFoundation

struct CaptureFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// Delegate callbacks and signal handlers do not share an execution queue.
final class CaptureEvents: NSObject, SCStreamDelegate, SCRecordingOutputDelegate,
                           SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var stopping = false
    private var frames = 0
    private var failure: String?
    private var nativeSize: (width: Int, height: Int)?
    private var pixelMapping: Double?
    private var firstPTS: Double?
    private var lastPTS: Double?
    private let requireNative: Bool
    private let expectedPixelScale: Double

    init(pixelScale: Double, requireNative: Bool = true) {
        self.expectedPixelScale = pixelScale
        self.requireNative = requireNative
    }

    func state() -> (started: Bool, finished: Bool, stopping: Bool,
                     frames: Int, failure: String?, nativeSize: (width: Int, height: Int)?,
                     pixelMapping: Double?, firstPTS: Double?, lastPTS: Double?) {
        lock.withLock {
            (started, finished, stopping, frames, failure, nativeSize,
             pixelMapping, firstPTS, lastPTS)
        }
    }
    func stop() { lock.withLock { stopping = true } }
    func fail(_ message: String) { lock.withLock { failure = message } }
    func recordingOutputDidStartRecording(_ output: SCRecordingOutput) {
        lock.withLock { started = true }
    }
    func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) {
        lock.withLock { finished = true }
    }
    func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
        fail("Recording failed: \(error)")
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail("Capture stream stopped: \(error)")
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        inspectScreenSample(sampleBuffer)
    }
    func inspectScreenSample(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let status = info[.status] as? Int,
              status == SCFrameStatus.complete.rawValue else { return }
        guard let scale = info[.contentScale] as? Double, scale.isFinite, scale > 0,
              let backing = info[.scaleFactor] as? Double, backing.isFinite, backing > 0,
              let rectDictionary = info[.contentRect] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: rectDictionary as CFDictionary),
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else {
            fail("Captured frame has no usable native geometry")
            return
        }
        // SCK can render at a higher resolution than the window's display.
        // Its source-to-surface scale and source backing scale together define
        // output pixels per logical point; compare that with the real display.
        let mapping = scale * backing / expectedPixelScale
        if requireNative && abs(mapping - 1) >= 0.0001 {
            let image = CMSampleBufferGetImageBuffer(sampleBuffer)
            let dimensions = image.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" } ?? "missing"
            fail("Captured frame was scaled; native pixels are required. Buffer=\(dimensions), attachments=\(info)")
            return
        }
        let sourceWidth = rect.width / scale * expectedPixelScale
        let sourceHeight = rect.height / scale * expectedPixelScale
        if requireNative {
            guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                fail("Captured frame has no pixel buffer")
                return
            }
            let width = Double(CVPixelBufferGetWidth(image))
            let height = Double(CVPixelBufferGetHeight(image))
            guard sourceWidth <= width, sourceHeight <= height,
                  rect.minX >= 0, rect.minY >= 0,
                  rect.maxX * backing <= width, rect.maxY * backing <= height else {
                fail("Captured frame exceeds original native-pixel canvas or is clipped")
                return
            }
        }
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard timestamp.isFinite else { fail("Captured frame has no valid timestamp"); return }
        lock.withLock {
            nativeSize = (Int(ceil(sourceWidth)), Int(ceil(sourceHeight)))
            pixelMapping = mapping
            if abs(mapping - 1) < 0.0001 {
                frames += 1
                if firstPTS == nil { firstPTS = timestamp }
                lastPTS = timestamp
            }
        }
    }
}

@main
struct RecordEmacsWindow {
    static func windowID(pid: pid_t) throws -> CGWindowID {
        guard kill(pid, 0) == 0,
              let inventory = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
                as? [[String: Any]] else {
            throw CaptureFailure("Owned Emacs process is unavailable: \(pid)")
        }
        let candidates = inventory.compactMap { item -> (CGWindowID, Double)? in
            guard item[kCGWindowOwnerPID as String] as? Int == Int(pid),
                  item[kCGWindowOwnerName as String] as? String == "Emacs",
                  item[kCGWindowLayer as String] as? Int == 0,
                  let alpha = item[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let title = item[kCGWindowName as String] as? String, !title.isEmpty,
                  let bounds = item[kCGWindowBounds as String] as? [String: Double],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 0, height > 0,
                  let number = item[kCGWindowNumber as String] as? UInt32 else { return nil }
            return (number, width * height)
        }.sorted { $0.1 > $1.1 }
        guard let first = candidates.first else {
            throw CaptureFailure("No named Emacs frame owned by PID \(pid)")
        }
        guard candidates.count == 1 || first.1 != candidates[1].1 else {
            throw CaptureFailure("Ambiguous largest Emacs frame for PID \(pid)")
        }
        return first.0
    }

    static func filter(pid: pid_t, id: CGWindowID) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: {
            $0.windowID == id && $0.owningApplication?.processID == pid
                && $0.windowLayer == 0
        }) else { throw CaptureFailure("Owned frame is not shareable: \(id)") }
        return SCContentFilter(desktopIndependentWindow: window)
    }

    static func emit(_ values: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }

    static func configureNativeCanvas(filter: SCContentFilter,
                                      configuration: SCStreamConfiguration) async throws {
        // Fullscreen WindowServer bounds can exclude native window decoration.
        // Discover the full source extent from one unrecorded sample; never
        // guess offsets or grow the canvas iteratively after recording starts.
        let probe = CaptureEvents(pixelScale: Double(filter.pointPixelScale), requireNative: false)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: probe)
        try stream.addStreamOutput(probe, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "capture-probe"))
        try await stream.startCapture()
        let deadline = Date().addingTimeInterval(10)
        do {
            while probe.state().nativeSize == nil {
                if let failure = probe.state().failure { throw CaptureFailure(failure) }
                guard Date() < deadline else { throw CaptureFailure("No native geometry sample") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let size = probe.state().nativeSize!
            configuration.width = size.width + size.width % 2
            configuration.height = size.height + size.height % 2
            try await stream.updateConfiguration(configuration)
            while probe.state().pixelMapping.map({ abs($0 - 1) >= 0.0001 }) ?? true {
                if let failure = probe.state().failure { throw CaptureFailure(failure) }
                guard Date() < deadline else {
                    throw CaptureFailure("Measured canvas did not preserve native pixels")
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try await stream.stopCapture()
        } catch {
            try? await stream.stopCapture()
            throw error
        }
    }

    static func record(pid: pid_t, output: URL, ready: URL) async throws {
        guard !FileManager.default.fileExists(atPath: output.path),
              !FileManager.default.fileExists(atPath: ready.path) else {
            throw CaptureFailure("Recording output or readiness file already exists")
        }
        var id = try windowID(pid: pid)
        var currentFilter = try await filter(pid: pid, id: id)
        let scale = Double(currentFilter.pointPixelScale)
        let width = Int(ceil(currentFilter.contentRect.width * scale))
        let height = Int(ceil(currentFilter.contentRect.height * scale))
        guard width > 0, height > 0 else { throw CaptureFailure("Empty frame") }
        let configuration = SCStreamConfiguration()
        // Fixed canvas; smaller windows are padded, never enlarged.  The frame
        // callback rejects any change to the display's native pixel mapping.
        configuration.width = width + width % 2
        configuration.height = height + height % 2
        configuration.scalesToFit = false
        configuration.captureResolution = .automatic
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        let background = CGColor(gray: 0, alpha: 1)
        defer { withExtendedLifetime(background) {} }
        configuration.backgroundColor = background
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.capturesAudio = false
        try await configureNativeCanvas(filter: currentFilter, configuration: configuration)
        let events = CaptureEvents(pixelScale: scale)
        try emit(["event": "configuration", "window_id": id, "pid": pid,
                  "width": configuration.width, "height": configuration.height,
                  "pixel_scale": scale, "content_rect": NSStringFromRect(currentFilter.contentRect)])
        let stream = SCStream(filter: currentFilter, configuration: configuration,
                              delegate: events)
        try stream.addStreamOutput(events, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "capture-frames"))
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = output
        recordingConfiguration.outputFileType = .mov
        let recording = SCRecordingOutput(configuration: recordingConfiguration, delegate: events)
        try stream.addRecordingOutput(recording)
        let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { events.stop() }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        try await stream.startCapture()
        let startedAt = Date()
        var announced = false
        do {
            while true {
                let nextID = try windowID(pid: pid)
                // SCContentFilter is a snapshot: refresh even for the same ID,
                // whose source can resize independently of window replacement.
                currentFilter = try await filter(pid: pid, id: nextID)
                let nextScale = Double(currentFilter.pointPixelScale)
                guard nextScale.isFinite, nextScale > 0,
                      currentFilter.contentRect.width > 0,
                      currentFilter.contentRect.height > 0,
                      currentFilter.contentRect.width * nextScale <= Double(configuration.width),
                      currentFilter.contentRect.height * nextScale <= Double(configuration.height) else {
                    throw CaptureFailure("Owned frame exceeds original native-pixel canvas or has invalid geometry")
                }
                if nextID != id {
                    try await stream.updateContentFilter(currentFilter)
                    id = nextID
                    try emit(["event": "window-replaced", "window_id": id, "pid": pid])
                }
                // Check the current source before readiness and requested stop;
                // also re-read callback failures after the asynchronous refresh.
                let state = events.state()
                if let failure = state.failure { throw CaptureFailure(failure) }
                if state.stopping { break }
                if state.finished { throw CaptureFailure("Recording ended before requested stop") }
                let elapsed = Date().timeIntervalSince(startedAt)
                if elapsed > 600 { throw CaptureFailure("Recording exceeded 600 seconds") }
                if !announced && elapsed > 10 { throw CaptureFailure("No verified recording frames") }
                if !announced && state.started && state.frames > 0 {
                    let metadata: [String: Any] = ["pid": pid, "window_id": id,
                        "width": configuration.width, "height": configuration.height,
                        "pixel_scale": scale, "capture": "desktop-independent-window",
                        "ready_wall_time": Date().timeIntervalSince1970,
                        "source_first_pts": state.firstPTS!]
                    try JSONSerialization.data(withJSONObject: metadata).write(to: ready, options: .atomic)
                    try emit(metadata)
                    announced = true
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try await stream.stopCapture()
            let stopDeadline = Date().addingTimeInterval(4)
            while !events.state().finished {
                if let failure = events.state().failure { throw CaptureFailure(failure) }
                guard Date() < stopDeadline else { throw CaptureFailure("Recording did not finalize") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if let failure = events.state().failure { throw CaptureFailure(failure) }
            guard announced, events.state().frames > 0 else {
                throw CaptureFailure("Recording stopped without verified frames")
            }
            let final = events.state()
            try emit(["event": "finished", "frames": final.frames,
                      "source_first_pts": final.firstPTS!, "source_last_pts": final.lastPTS!,
                      "source_span_seconds": final.lastPTS! - final.firstPTS!,
                      "recorded_duration_seconds": CMTimeGetSeconds(recording.recordedDuration),
                      "wall_duration_seconds": Date().timeIntervalSince(startedAt)])
        } catch {
            try? await stream.stopCapture()
            throw error
        }
    }

    static func main() async {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 4, let pid = Int32(arguments[1]), pid > 1 else {
                throw CaptureFailure("usage: record-emacs-window PID OUTPUT.mov READY_FILE")
            }
            try await record(pid: pid, output: URL(fileURLWithPath: arguments[2]),
                             ready: URL(fileURLWithPath: arguments[3]))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
