import AppKit

/// A single click-through feedback panel in the existing controls process. It
/// cannot become key/main or intercept the keyboard released by the watchdog.
@MainActor
final class ResidentInputFaultPanel: NSPanel, ResidentInputFaultNoticeSurface {
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 76),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 440, height: 76))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        messageLabel.frame = NSRect(x: 18, y: 15, width: 404, height: 46)
        messageLabel.font = .systemFont(ofSize: 14, weight: .medium)
        messageLabel.textColor = .labelColor
        messageLabel.alignment = .center
        messageLabel.setAccessibilityLabel("Leyline keyboard feedback")
        background.addSubview(messageLabel)
        contentView = background
    }

    func show(message: String) {
        messageLabel.stringValue = message
        if let visibleFrame = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: visibleFrame.midX - frame.width / 2,
                y: visibleFrame.maxY - frame.height - 24))
        }
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}
