import AppKit

enum ResidentStatusIconState: String, Sendable { case off, on, error }

/// @canonical resident_status_icon -- a native vector layout, with filled tiles
/// for ON/error and a template outline for OFF. No bitmap asset or status poll.
@MainActor
enum ResidentStatusIcon {
    static let size = NSSize(width: 20, height: 16)

    static func make(_ state: ResidentStatusIconState) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            let outline: NSColor = .labelColor
            let fill: NSColor? = state == .on ? .systemGreen : state == .error ? .systemRed : nil
            let outer = NSBezierPath(roundedRect: NSRect(x: 0.75, y: 0.75, width: 18.5, height: 14.5), xRadius: 2, yRadius: 2)
            outline.setStroke(); outer.lineWidth = 0.8; outer.stroke()
            let tiles = [NSRect(x: 2.5, y: 2.5, width: 6.5, height: 11),
                         NSRect(x: 10.75, y: 8.75, width: 6.75, height: 4.75),
                         NSRect(x: 10.75, y: 2.5, width: 6.75, height: 4.75)]
            for tile in tiles {
                let path = NSBezierPath(roundedRect: tile, xRadius: 0.7, yRadius: 0.7)
                if let fill { fill.setFill(); path.fill() }
                outline.setStroke(); path.lineWidth = 0.8; path.stroke()
            }
            return true
        }
        image.isTemplate = state == .off
        image.accessibilityDescription = "Leyline " + state.rawValue
        return image
    }
}
