// Headless, rc-based self-checks (the house --self-check pattern; CLT ships no
// test libraries). `ley test native` runs these; a suite that ran zero checks
// fails — never a vacuous green.
import Foundation
import LeylineModel

struct SelfTest {
    private(set) var ran = 0
    private(set) var failed: [String] = []

    mutating func check(_ condition: Bool, _ label: String) {
        ran += 1
        if condition {
            print("ok \(label)")
        } else {
            print("not ok \(label)")
            failed.append(label)
        }
    }

    func finish(_ suite: String) -> Int32 {
        print("self-test \(suite): \(ran - failed.count)/\(ran) ok")
        if ran == 0 {
            print("not ok \(suite): VACUOUS (zero checks ran)")
            return 1
        }
        return failed.isEmpty ? 0 : 1
    }
}

func runModelSelfTest() -> Int32 {
    var t = SelfTest()

    let r0 = Revision(0)
    let r1 = r0.next()
    t.check(r0 < r1 && r1 == Revision(1), "revision/next-strictly-greater")
    t.check(Revision(900).next() == Revision(901), "revision/high-water-continuation")

    if let encoded = try? JSONEncoder().encode(Revision(900)),
       let decoded = try? JSONDecoder().decode(Revision.self, from: encoded) {
        t.check(String(decoding: encoded, as: UTF8.self) == "900" && decoded == Revision(900),
                "revision/wire-shape-bare-integer")
    } else {
        t.check(false, "revision/wire-shape-bare-integer")
    }

    func parsed(_ text: String) -> JSONValue? { try? JSONValue.parse(Data(text.utf8)) }
    t.check(parsed("3.0")?.intValue == 3 && parsed("-0.0")?.intValue == 0 && parsed("7")?.intValue == 7
        && parsed("2.5")?.intValue == nil, "json/integral-doubles-read-as-integers-and-fractions-do-not")
    t.check(parsed("1e19") != nil && parsed("1e19")?.intValue == nil && parsed("-1e300")?.intValue == nil
        && JSONValue.double(.infinity).intValue == nil && JSONValue.double(.nan).intValue == nil
        && JSONValue.double(9_223_372_036_854_775_808).intValue == nil,
        "json/out-of-range-or-non-finite-double-is-not-an-integer-and-cannot-trap")
    t.check(parsed("1e999") == nil && parsed("-1e999") == nil && parsed("{\"border_radius\":1e999}") == nil,
        "json/non-finite-number-is-refused-at-parse")
    let deep = 100_000
    t.check(parsed(String(repeating: "[", count: 256) + String(repeating: "]", count: 256)) != nil
        && parsed(String(repeating: "[", count: 257) + String(repeating: "]", count: 257)) == nil
        && parsed(String(repeating: "[", count: deep)) == nil
        && parsed(String(repeating: "{\"a\":", count: deep)) == nil,
        "json/nesting-is-bounded-so-hostile-depth-refuses-instead-of-exhausting-the-stack")

    return t.finish("model")
}
