import AppKit

/// Render the shipping vector factory offscreen. Interior pixels independently
/// verify empty/green/red tiles; no status item, NSPanel or real desktop changes.
func runResidentStatusIconSelfTest(sampleDirectory: String?) -> Bool {
    MainActor.assumeIsolated {
        do {
            if let sampleDirectory { try FileManager.default.createDirectory(atPath: sampleDirectory, withIntermediateDirectories: true) }
            for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                guard let appearance = NSAppearance(named: appearanceName) else { return false }
                for state in [ResidentStatusIconState.off, .on, .error] {
                    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 32,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
                    appearance.performAsCurrentDrawingAppearance {
                        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                        defer { NSGraphicsContext.restoreGraphicsState() }
                        ResidentStatusIcon.make(state).draw(in: NSRect(x: 0, y: 0, width: 40, height: 32))
                    }
                    guard let interior = bitmap.colorAt(x: 12, y: 16)?.usingColorSpace(.deviceRGB) else { return false }
                    if state == .off { guard interior.alphaComponent < 0.01 else { return false } }
                    else if state == .on { guard interior.greenComponent > interior.redComponent && interior.greenComponent > interior.blueComponent else { return false } }
                    else { guard interior.redComponent > interior.greenComponent && interior.redComponent > interior.blueComponent else { return false } }
                    guard ResidentStatusIcon.make(state).isTemplate == (state == .off) else { return false }
                    if let sampleDirectory, let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: URL(fileURLWithPath: sampleDirectory).appendingPathComponent("status-\(name)-\(state.rawValue).png"))
                    }
                }
            }
            return true
        } catch { return false }
    }
}
