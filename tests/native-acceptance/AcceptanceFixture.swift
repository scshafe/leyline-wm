// @canonical native_acceptance_fixture -- actual fixture windows plus independent compositor evidence.
// Never sends keyboard events, requests permissions, or mutates another application.
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage
import CryptoKit
import Darwin

func uptime() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func jsonData(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
func envelope(_ data: Any?, code: String? = nil) -> [String: Any] {
    ["data": data ?? NSNull(), "error": code.map { ["code": $0, "message": $0] } as Any? ?? NSNull(),
     "meta": ["schema": "leyline/native-acceptance-fixture/v1", "request_id": UUID().uuidString]]
}
func printJSON(_ value: Any) { if let data = try? jsonData(value) { print(String(decoding: data, as: UTF8.self)) } }

struct FixtureClock {
    let numer: UInt32
    let denom: UInt32
    init() { var info = mach_timebase_info_data_t(); mach_timebase_info(&info); numer = info.numer; denom = info.denom }
    func nanos(_ ticks: UInt64) -> UInt64 {
        let quotient = ticks / UInt64(denom), remainder = ticks % UInt64(denom)
        return quotient * UInt64(numer) + remainder * UInt64(numer) / UInt64(denom)
    }
    func calibration() -> [String: Any] {
        let before = uptime(), ticks = mach_absolute_time(), after = uptime()
        return ["clock": "mach_absolute_time", "unit": "ticks", "numer": numer, "denom": denom,
                "mach_ticks": ticks, "mach_ns": nanos(ticks), "uptime_before_ns": before,
                "uptime_after_ns": after, "uncertainty_ns": after - before]
    }
}

final class FixtureRecorder {
    let root: URL
    private let lock = NSLock()
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    func replace(_ name: String, _ object: Any) {
        lock.lock(); defer { lock.unlock() }
        do { try jsonData(object).write(to: root.appendingPathComponent(name), options: [.atomic]) }
        catch { printJSON(envelope(nil, code: "FIXTURE.ARTIFACT_WRITE_FAILED")) }
    }
    func append(_ name: String, _ object: Any) throws {
        lock.lock(); defer { lock.unlock() }
        let path = root.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: path.path) {
            guard FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw NSError(domain: "FIXTURE.ARTIFACT_CREATE_FAILED", code: 1)
            }
        }
        let file = try FileHandle(forWritingTo: path); defer { try? file.close() }
        try file.seekToEnd(); var data = try jsonData(object); data.append(10); try file.write(contentsOf: data)
    }
}

final class FixturePattern: NSView {
    let identity: Int
    init(identity: Int) { self.identity = identity; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not supported") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); bounds.fill()
        NSColor.black.setStroke(); let edge = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3)); edge.lineWidth = 4; edge.stroke()
        for bit in 0..<12 where identity & (1 << bit) != 0 {
            NSColor.systemBlue.setFill(); NSRect(x: 12 + bit * 8, y: 10, width: 6, height: 18).fill()
        }
        let title = "Fixture \(identity)"
        title.draw(at: NSPoint(x: 12, y: 36), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .bold),
                                                            .foregroundColor: NSColor.black])
    }
}

final class FixtureCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let recorder: FixtureRecorder
    private let clock = FixtureClock()
    private let queue = DispatchQueue(label: "fixture.capture", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var stream: SCStream?
    private var state: [String: Any] = ["state": "stopped", "physical_scanout_proven": false]
    private var count = 0, bytes = 0
    private var lastDisplayNs: UInt64 = 0
    private var displayID: CGDirectDisplayID = 0
    private var refreshHz: Double = 0
    private var lastHash: String?
    private var captureROI: [Int]?
    private var generation: UInt64 = 0
    private var starting = false
    init(recorder: FixtureRecorder) { self.recorder = recorder }
    func status() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return state }
    private func setState(_ next: [String: Any]) { lock.lock(); state = next; lock.unlock(); recorder.replace("capture-status.json", envelope(next)) }
    func start() {
        guard CGPreflightScreenCaptureAccess() else {
            setState(["state": "permission_required", "code": "CAPTURE.SCREEN_RECORDING_REQUIRED",
                      "prompt_attempted": false, "physical_scanout_proven": false]); return
        }
        lock.lock()
        guard stream == nil, !starting else { lock.unlock(); return }
        generation &+= 1; let epoch = generation; starting = true
        lock.unlock()
        let roiURL = recorder.root.appendingPathComponent("capture-roi.json")
        if let data = try? Data(contentsOf: roiURL), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard let roi = object["roi_px"] as? [Int], roi.count == 4,
                  roi[0] >= 0, roi[1] >= 0, roi[2] > 0, roi[3] > 0 else {
                setState(["state": "failed", "code": "CAPTURE.ROI_INVALID"]); return
            }
            captureROI = roi
        }
        setState(["state": "starting", "physical_scanout_proven": false])
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            self.lock.lock(); let active = epoch == self.generation; self.lock.unlock()
            guard active else { return }
            guard let display = content?.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                self.setState(["state": "failed", "code": "CAPTURE.DISPLAY_UNAVAILABLE", "detail": error?.localizedDescription ?? "no display"]); return
            }
            self.displayID = display.displayID
            self.refreshHz = CGDisplayCopyDisplayMode(display.displayID)?.refreshRate ?? 0
            if let roi = self.captureROI,
               (roi[0] + roi[2] > CGDisplayPixelsWide(display.displayID) || roi[1] + roi[3] > CGDisplayPixelsHigh(display.displayID)) {
                self.setState(["state": "failed", "code": "CAPTURE.ROI_OUTSIDE_DISPLAY"]); return
            }
            let config = SCStreamConfiguration()
            config.width = CGDisplayPixelsWide(display.displayID); config.height = CGDisplayPixelsHigh(display.displayID)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 3; config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            // An empty exclusion includes Leyline panels and actual composited fixture edges.
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue) }
            catch { self.setState(["state": "failed", "code": "CAPTURE.OUTPUT_ATTACH_FAILED", "detail": error.localizedDescription]); return }
            self.lock.lock()
            guard epoch == self.generation else { self.lock.unlock(); return }
            self.stream = stream; self.starting = false
            self.lock.unlock()
            self.recorder.replace("clock-calibration.json", self.clock.calibration())
            stream.startCapture { error in
                self.lock.lock(); let active = epoch == self.generation; self.lock.unlock()
                guard active else { stream.stopCapture(completionHandler: nil); return }
                self.setState(["state": error == nil ? "running" : "failed", "detail": error?.localizedDescription ?? "",
                               "display_id": self.displayID, "refresh_hz": self.refreshHz,
                               "physical_scanout_proven": false, "permission_prompt_attempted": false])
            }
        }
    }
    func stop() {
        lock.lock(); generation &+= 1; let epoch = generation; starting = false; let current = stream; stream = nil; lock.unlock()
        current?.stopCapture { [weak self] error in
            guard let self else { return }
            self.lock.lock(); let active = epoch == self.generation; self.lock.unlock()
            guard active else { return }
            self.setState(["state": error == nil ? "stopped" : "failed", "detail": error?.localizedDescription ?? "",
                            "physical_scanout_proven": false])
        }
        if current == nil { setState(["state": "stopped", "physical_scanout_proven": false]) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); let active = self.stream === stream; lock.unlock()
        guard active else { return }
        setState(["state": "failed", "code": "CAPTURE.STREAM_STOPPED", "detail": error.localizedDescription])
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        lock.lock(); let active = self.stream === stream; lock.unlock()
        guard active else { return }
        if count >= 20_000 {
            try? recorder.append("capture-frames.jsonl", ["schema": "leyline/native-capture-frame/v1", "frame_id": count,
                "gap_flags": ["capture_record_budget_exceeded"], "physical_scanout_proven": false])
            count += 1; stop(); return
        }
        guard type == .screen, sampleBuffer.isValid else { return }
        let arrival = uptime()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let info = attachments?.first ?? [:]
        let status = (info[.status] as? NSNumber)?.intValue ?? -1
        let ticks = (info[.displayTime] as? NSNumber)?.uint64Value ?? 0
        let displayNs = clock.nanos(ticks)
        var gaps: [String] = []
        if ticks == 0 { gaps.append("display_time_missing") }
        if refreshHz <= 0 { gaps.append("display_refresh_rate_unknown") }
        if lastDisplayNs > 0 && displayNs <= lastDisplayNs { gaps.append("nonincreasing_display_time") }
        if status != SCFrameStatus.complete.rawValue { gaps.append("frame_not_complete") }
        var row: [String: Any] = ["schema": "leyline/native-capture-frame/v1", "frame_id": count,
            "display_id": displayID, "display_time_ticks": ticks, "display_time_ns": displayNs,
            "arrival_uptime_ns": arrival, "clock_calibration": clock.calibration(), "status": status,
            "refresh_hz": refreshHz, "physical_scanout_proven": false, "gap_flags": gaps,
            "provenance": "screencapturekit_windowserver_composition"]
        if status == SCFrameStatus.complete.rawValue, let buffer = sampleBuffer.imageBuffer {
            let sourceImage = CIImage(cvPixelBuffer: buffer)
            let roi = captureROI ?? [0, 0, Int(sourceImage.extent.width), Int(sourceImage.extent.height)]
            let image = sourceImage.cropped(to: CGRect(x: roi[0], y: Int(sourceImage.extent.height) - roi[1] - roi[3], width: roi[2], height: roi[3]))
            row["roi_px"] = roi
            if let data = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) {
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                row["pixels_sha256"] = hash
                // Persist distinct pixels only; repeated metadata still has its own frame record.
                if hash != lastHash {
                    if count >= 20_000 || bytes + data.count > 512 * 1024 * 1024 {
                        row["gap_flags"] = gaps + ["capture_storage_budget_exceeded"]
                        try? recorder.append("capture-frames.jsonl", row); stop(); return
                    }
                    let name = "frame-\(count).png"
                    do { try data.write(to: recorder.root.appendingPathComponent(name), options: [.atomic]) }
                    catch { row["gap_flags"] = gaps + ["pixel_artifact_write_failed"] }
                    bytes += data.count; lastHash = hash; row["frame_path"] = name
                } else { row["unchanged_pixels"] = true }
            } else { row["gap_flags"] = gaps + ["pixel_encoding_failed"] }
        }
        do { try recorder.append("capture-frames.jsonl", row) }
        catch { setState(["state": "failed", "code": "CAPTURE.METADATA_WRITE_FAILED"]); stop() }
        if ticks > 0 { lastDisplayNs = displayNs }; count += 1
    }
}

// Filesystem IPC publishes atomic manifests and append-only evidence. Consumers have no mutation endpoint.
final class FixtureControlPanel: NSPanel {
    // A0-window fixture still needs an AX key/main window for CUA app binding.
    // Utility/floating presentation keeps this outside the ordinary cohort.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class FixtureApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let recorder: FixtureRecorder
    let capture: FixtureCapture
    var windows: [NSWindow] = []
    var panel: NSPanel?
    var statusLabel: NSTextField?
    var nextIdentity = 1
    var lifecycleTimer: Timer?
    var lifecycleStep = 0
    let sessionID = UUID().uuidString
    init(recorder: FixtureRecorder) { self.recorder = recorder; capture = FixtureCapture(recorder: recorder) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        recorder.replace("capture-status.json", envelope(capture.status()))
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let application = NSMenu(); application.addItem(withTitle: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = application; NSApp.mainMenu = menu
        let fixtureItem = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")
        let fixtureMenu = NSMenu(title: "Fixture")
        fixtureMenu.autoenablesItems = false
        let show = NSMenuItem(title: "Fixture controls", action: #selector(showControls), keyEquivalent: "")
        show.target = self; fixtureMenu.addItem(show)
        let add = NSMenuItem(title: "New fixture window", action: #selector(addWindow), keyEquivalent: "")
        add.target = self; fixtureMenu.addItem(add)
        for (index, title) in ["1 window", "6 windows", "12 windows", "20 windows", "Lifecycle 100", "Capture", "Stop"].enumerated() {
            let action = NSMenuItem(title: title, action: #selector(menuControl(_:)), keyEquivalent: "")
            action.target = self; action.tag = index; fixtureMenu.addItem(action)
        }
        fixtureItem.submenu = fixtureMenu; menu.addItem(fixtureItem)
        let panel = FixtureControlPanel(contentRect: NSRect(x: 40, y: 80, width: 620, height: 150),
                            styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Acceptance fixture controls (test only)"; panel.level = .floating
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = false
        panel.setAccessibilityTitle("Acceptance fixture controls")
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 150)); panel.contentView = root
        let labels = ["1 window", "6 windows", "12 windows", "20 windows", "Lifecycle 100", "Capture", "Stop"]
        for (index, title) in labels.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(control(_:)))
            button.setAccessibilityLabel(title)
            button.tag = index; button.frame = NSRect(x: 10 + (index % 4) * 150, y: 100 - (index / 4) * 40, width: 145, height: 32)
            root.addSubview(button)
        }
        let label = NSTextField(labelWithString: recorder.root.path); label.frame = NSRect(x: 10, y: 10, width: 600, height: 30)
        root.addSubview(label); statusLabel = label; self.panel = panel
        publish(); NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
    }
    @objc func showControls() { NSApp.activate(ignoringOtherApps: true); panel?.makeKeyAndOrderFront(nil) }
    @objc func addWindow() { createWindow() }
    @objc func menuControl(_ sender: NSMenuItem) { runControl(sender.tag) }
    @objc func control(_ sender: NSButton) {
        runControl(sender.tag)
    }
    func runControl(_ tag: Int) {
        switch tag {
        case 0...3:
            lifecycleTimer?.invalidate(); lifecycleTimer = nil
            for window in windows { window.close() }; windows.removeAll()
            for _ in 0..<([1, 6, 12, 20][tag]) { createWindow() }; publish()
        case 4:
            guard !windows.isEmpty, lifecycleTimer == nil else { return }
            lifecycleStep = 0
            lifecycleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.lifecycle() }
        case 5: capture.start(); statusLabel?.stringValue = "Capture status: read capture-status.json"
        default: lifecycleTimer?.invalidate(); lifecycleTimer = nil; capture.stop(); publish()
        }
    }
    func createWindow() {
        let identity = nextIdentity; nextIdentity += 1
        let window = NSWindow(contentRect: NSRect(x: 80 + (identity % 5) * 30, y: 180, width: 360, height: 220),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Leyline fixture \(sessionID.prefix(8)) / \(identity)"
        window.identifier = NSUserInterfaceItemIdentifier("fixture-\(identity)")
        window.minSize = NSSize(width: 120, height: 90); window.isReleasedWhenClosed = false
        window.contentView = FixturePattern(identity: identity); window.delegate = self
        windows.append(window); window.makeKeyAndOrderFront(nil); event("created", window); publish()
    }
    func lifecycle() {
        if lifecycleStep % 4 == 3 {
            createWindow()
            lifecycleStep += 1; publish()
            statusLabel?.stringValue = "Lifecycle \(lifecycleStep)/400 (100 per path)"
            if lifecycleStep >= 400 { lifecycleTimer?.invalidate(); lifecycleTimer = nil; publish() }
            return
        }
        guard let window = windows.first else { lifecycleTimer?.invalidate(); lifecycleTimer = nil; return }
        switch lifecycleStep % 4 {
        case 0: window.miniaturize(nil)
        case 1: window.deminiaturize(nil)
        case 2: window.close(); windows.removeAll { $0 === window }
        default: createWindow()
        }
        lifecycleStep += 1; publish()
        statusLabel?.stringValue = "Lifecycle \(lifecycleStep)/400 (100 per path)"
        if lifecycleStep >= 400 { lifecycleTimer?.invalidate(); lifecycleTimer = nil; publish() }
    }
    func event(_ kind: String, _ window: NSWindow) {
        do { try recorder.append("fixture-events.jsonl", ["schema": "leyline/native-fixture-event/v1", "session_id": sessionID,
            "event": kind, "receipt_uptime_ns": uptime(), "pid": getpid(), "window_id": window.windowNumber,
            "fixture_identity": window.identifier?.rawValue ?? "", "origin": "fixture_lifecycle"]) }
        catch {
            lifecycleTimer?.invalidate(); lifecycleTimer = nil
            recorder.replace("fixture-error.json", envelope(nil, code: "FIXTURE.EVENT_WRITE_FAILED"))
        }
    }
    func publish() {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let rows: [[String: Any]] = windows.filter { $0.isVisible || $0.isMiniaturized }.map { window in
            ["window_id": window.windowNumber, "pid": getpid(), "fixture_identity": window.identifier?.rawValue ?? "",
             "frame_cg_points": [window.frame.minX, primaryHeight - window.frame.maxY, window.frame.width, window.frame.height],
             "minimum_frame_points": [window.minSize.width, window.minSize.height], "minimized": window.isMiniaturized,
             "title": window.title]
        }
        recorder.replace("window-manifest.json", envelope(["session_id": sessionID, "pid": getpid(), "receipt_uptime_ns": uptime(),
            "window_count": rows.count, "windows": rows, "lifecycle_steps_completed": lifecycleStep,
            "lifecycle_running": lifecycleTimer != nil, "control_panel_is_fixture_window": false]))
    }
    func windowDidResize(_ notification: Notification) { publish() }
    func windowDidMove(_ notification: Notification) { publish() }
    func windowDidMiniaturize(_ notification: Notification) { if let w = notification.object as? NSWindow { event("minimized", w) }; publish() }
    func windowDidDeminiaturize(_ notification: Notification) { if let w = notification.object as? NSWindow { event("restored", w) }; publish() }
    func windowWillClose(_ notification: Notification) { if let w = notification.object as? NSWindow { event("closed", w) }; publish() }
    func applicationWillTerminate(_ notification: Notification) { lifecycleTimer?.invalidate(); capture.stop() }
}

let arguments = CommandLine.arguments.dropFirst()
if arguments == ["--preflight"] {
    let allowed = CGPreflightScreenCaptureAccess()
    printJSON(envelope(["screen_recording_authorized": allowed, "permission_prompt_attempted": false,
                        "physical_scanout_proven": false], code: allowed ? nil : "CAPTURE.SCREEN_RECORDING_REQUIRED"))
    exit(allowed ? 0 : 77)
}
if arguments == ["--self-test-clock"] {
    let clock = FixtureClock(), calibration = clock.calibration()
    let before = calibration["uptime_before_ns"] as! UInt64, after = calibration["uptime_after_ns"] as! UInt64
    let measured = calibration["mach_ns"] as! UInt64
    let valid = before <= measured && measured <= after
    printJSON(envelope(calibration, code: valid ? nil : "CLOCK.UPTIME_CALIBRATION_FAILED")); exit(valid ? 0 : 1)
}
let path = arguments.isEmpty ? "/tmp/leyline-native-acceptance-session-" + UUID().uuidString : (arguments.last ?? "")
guard (arguments.isEmpty || (arguments.count == 2 && arguments.first == "--output")),
      path.hasPrefix("/tmp/"), !FileManager.default.fileExists(atPath: path) else {
    printJSON(envelope(nil, code: "FIXTURE.REQUIRES_FRESH_TMP_OUTPUT")); exit(64)
}
do {
    let recorder = try FixtureRecorder(root: URL(fileURLWithPath: path, isDirectory: true))
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    let delegate = FixtureApp(recorder: recorder); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
} catch { printJSON(envelope(nil, code: "FIXTURE.OUTPUT_CREATE_FAILED")); exit(74) }
