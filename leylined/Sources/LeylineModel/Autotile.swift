// Tileability: only resizable standard windows enter an arrangement.
import Foundation

public enum Autotile {
    public static func tileable(_ w: JSONValue) -> Bool {
        let o = w.objectValue ?? [:]
        let resizable = o["resizable"]?.boolValue ?? false
        let standard = o["role"]?.stringValue == "AXWindow" && o["subrole"]?.stringValue == "AXStandardWindow"
        return resizable && standard
    }
}
