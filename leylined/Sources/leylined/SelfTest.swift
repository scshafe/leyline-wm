// Headless, rc-based self-checks (the house --self-check pattern; CLT ships no
// test libraries). `ley test leylined` runs these; a suite that ran zero checks
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

    return t.finish("model")
}
